#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = (Join-Path (Get-Location) "Compare-Agents-Export-$(Get-Date -Format 'yyyy-MM-dd-HHmmss')"),

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Platform = 'Microsoft 365 Copilot Agent Builder',

    [Parameter()]
    [switch]$UseBeta,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [switch]$Resume,

    # isBlocked is returned by the LIST call, so blocked agents can be skipped before the
    # expensive per-package detail request. This is the one usage-driven saving available at
    # download time, and it is what makes a dormancy/blocking lifecycle process pay off here.
    [Parameter()]
    [switch]$ExcludeBlocked,

    # Post-retrieval usage selection. These CANNOT reduce Graph calls: usage telemetry is returned
    # only by the per-package detail request, so every agent must still be fetched before it can be
    # judged. They produce an additional scoped file alongside the full export.
    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinSessions = 0,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinActiveUsers = 0,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$UsedWithinDays = 30,

    # Server-side filter on the list call. Useful for incremental runs, but note that
    # lastModifiedDateTime tracks configuration changes, NOT usage: a stable, heavily used agent
    # may not have been modified in months. Never use it as an activity filter.
    [Parameter()]
    [datetime]$ModifiedSince,

    [Parameter()]
    [ValidateRange(10, 5000)]
    [int]$CheckpointEvery = 50,

    [Parameter()]
    [switch]$LiveMode = $false
)

$ErrorActionPreference = 'Stop'
$apiVersion = if ($UseBeta) { 'beta' } else { 'v1.0' }
$graphRoot = "https://graph.microsoft.com/$apiVersion"
$requiredScope = 'CopilotPackages.Read.All'
$checkpointName = if ($Platform -eq 'All') { 'all-agents-details.checkpoint.json' }
                  else { 'agent-builder-details.checkpoint.json' }

Write-Host "Mode: $(if ($LiveMode) { 'LIVE RUN' } else { 'DRY RUN' })"
Write-Host "Tenant: $TenantId"
Write-Host "API version: $apiVersion"
Write-Host "Authentication: $(if ($UseDeviceAuthentication) { 'Delegated device code' } else { 'Delegated interactive browser' })"
Write-Host "Output directory: $OutputDirectory"

if ($MinSessions -gt 0 -or $MinActiveUsers -gt 0) {
    Write-Host "Usage selection: sessions >= $MinSessions, users >= $MinActiveUsers, used within $UsedWithinDays day(s)"
    Write-Warning ('Usage telemetry is returned only by the per-package detail call, so this selection ' +
                   'cannot reduce the number of Graph requests. Every agent is still retrieved; the ' +
                   'filter produces an additional scoped file beside the full export.')
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw "Microsoft.Graph.Authentication is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser"
}

if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
    Import-Module Microsoft.Graph.Authentication
}

$script:PaceMs = 0          # adaptive inter-request pacing, raised when the service pushes back

function Test-GraphThrottled {
    param($ErrorRecord)
    # The status line alone is not enough. This service wraps downstream rate limiting in a
    # 424 Failed Dependency whose *body* carries {"StatusCode":424,"Message":"Too Many Requests"},
    # so the outer exception message reads only "FailedDependency" and a naive check misses it.
    $text = @(
        $ErrorRecord.Exception.Message
        $ErrorRecord.ErrorDetails.Message
    ) -join ' '
    return $text -match '\b429\b|\b424\b|\b503\b|\b504\b|Too Many Requests|Service Unavailable|Failed ?Dependency'
}

function Invoke-GraphGetWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxAttempts = 8
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($script:PaceMs -gt 0) { Start-Sleep -Milliseconds $script:PaceMs }
            return Invoke-MgGraphRequest -Method GET -Uri $Uri
        }
        catch {
            if (-not (Test-GraphThrottled $_) -or $attempt -eq $MaxAttempts) { throw }

            # Honor Retry-After when Graph supplies it, otherwise back off exponentially.
            $text = @($_.Exception.Message, $_.ErrorDetails.Message) -join ' '
            $delay = [math]::Pow(2, $attempt)
            if ($text -match 'Retry-After[:\s]+(\d+)') { $delay = [int]$Matches[1] }
            $delay = [math]::Min($delay, 120)

            # Slow every subsequent request too. Backing off only the failed call just walks
            # straight back into the limit on the next one.
            $script:PaceMs = [math]::Min($script:PaceMs + 150, 2000)

            Write-Warning ("Graph throttled (attempt $attempt/$MaxAttempts). Waiting $delay second(s); " +
                           "pacing subsequent requests by $($script:PaceMs)ms.")
            Start-Sleep -Seconds $delay
        }
    }
}

function Invoke-PagedGraphGet {
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    while ($nextLink) {
        $response = Invoke-GraphGetWithRetry -Uri $nextLink
        if ($null -eq $response.value) {
            throw "Graph response from '$nextLink' did not contain a value collection."
        }

        foreach ($item in $response.value) {
            $items.Add($item)
        }

        $nextLink = $response.'@odata.nextLink'
        if ($items.Count -gt 0 -and $items.Count % 500 -eq 0) {
            Write-Host "  listed $($items.Count) packages..."
        }
    }

    return $items.ToArray()
}

try {
    # Reuse an existing Graph session when one is already established for this tenant with the
    # required scope. Connect-MgGraph's device-code prompt times out after 120 seconds, which is
    # not long enough when the operator has to pick up a browser on another device; this lets a
    # caller authenticate separately and hand the session in.
    $context = Get-MgContext -ErrorAction SilentlyContinue
    $reusable = $false
    if ($null -ne $context -and $requiredScope -in $context.Scopes) {
        $sameTenant = $TenantId -and (
            $context.TenantId -eq $TenantId -or
            $context.Account -like "*@$TenantId" -or
            ($context.TenantDomain -and $context.TenantDomain -eq $TenantId)
        )
        if ($sameTenant -or -not $TenantId) { $reusable = $true }
    }

    if ($reusable) {
        Write-Host "Reusing existing Graph session for $($context.Account)"
    }
    else {
        $connectParameters = @{
            TenantId = $TenantId
            Scopes = $requiredScope
            NoWelcome = $true
        }
        if ($UseDeviceAuthentication) {
            $connectParameters.UseDeviceAuthentication = $true
        }

        Connect-MgGraph @connectParameters
        $context = Get-MgContext
    }

    if ($null -eq $context) {
        throw 'Microsoft Graph authentication did not return a session context.'
    }

    if ($requiredScope -notin $context.Scopes) {
        throw "The authenticated session does not include the required '$requiredScope' scope."
    }

    # 'All' exports every platform in the registry: Agent Builder, Copilot Studio, and anything
    # else the tenant holds. The default stays Agent Builder because the consolidation analysis
    # is scoped to it, but the inventory itself need not be.
    $allPlatforms = $Platform -eq 'All'
    $filterParts = @()
    if (-not $allPlatforms) {
        $filterParts += "platform eq '$($Platform -replace "'", "''")'"
    }
    if ($PSBoundParameters.ContainsKey('ModifiedSince')) {
        $stamp = $ModifiedSince.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        $filterParts += "lastModifiedDateTime gt $stamp"
        Write-Warning ('lastModifiedDateTime filters configuration changes, not usage. A stable, ' +
                       'heavily used agent may be excluded. Do not treat this as an activity filter.')
    }
    $listUri = "$graphRoot/copilot/admin/catalog/packages"
    if ($filterParts.Count -gt 0) {
        $encodedFilter = [uri]::EscapeDataString(($filterParts -join ' and '))
        $listUri = "$listUri`?`$filter=$encodedFilter"
    }
    $inventory = @(Invoke-PagedGraphGet -Uri $listUri)

    if ($allPlatforms) {
        Write-Host "Packages found (all platforms): $($inventory.Count)"
        $inventory | Group-Object platform | Sort-Object Count -Descending |
            ForEach-Object { Write-Host ("  {0,-44} {1,5}" -f $_.Name, $_.Count) }
    }
    else {
        Write-Host "$Platform packages found: $($inventory.Count)"
    }

    if ($ExcludeBlocked) {
        $before = $inventory.Count
        $inventory = @($inventory | Where-Object { -not $_.isBlocked })
        $skipped = $before - $inventory.Count
        Write-Host "Blocked packages skipped before detail retrieval: $skipped"
        if ($skipped -gt 0) {
            Write-Host "  saved $skipped detail request(s)"
        }
    }

    if (-not $LiveMode) {
        Write-Host "DRY RUN: Would retrieve details for $($inventory.Count) package(s) and write 3 JSON files."
        if ($inventory.Count -ge 1000) {
            Write-Warning ("Large registry detected. The live run issues one detail request per package, " +
                           "so expect a long run. Progress is checkpointed to '$checkpointName' and can be " +
                           "resumed with -Resume if the run is interrupted.")
        }
        return
    }

    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    $checkpointPath = Join-Path $OutputDirectory $checkpointName

    # Detail retrieval is one request per package, so a 10,000-agent tenant means 10,000 calls.
    # Checkpointing every batch means an interrupted or throttled run resumes instead of restarting.
    $details = [System.Collections.Generic.List[object]]::new()
    $completedIds = [System.Collections.Generic.HashSet[string]]::new()

    if ($Resume -and (Test-Path -LiteralPath $checkpointPath)) {
        foreach ($item in @(Get-Content -LiteralPath $checkpointPath -Raw -Encoding utf8 | ConvertFrom-Json)) {
            $details.Add($item)
            [void]$completedIds.Add([string]$item.id)
        }
        Write-Host "Resuming from checkpoint: $($details.Count) package(s) already retrieved."
    }

    $processed = 0
    $started = Get-Date
    foreach ($package in $inventory) {
        $packageId = [string]$package.id
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            throw 'A package returned by Graph did not contain an ID.'
        }

        $processed++
        if ($completedIds.Contains($packageId)) { continue }

        $encodedId = [uri]::EscapeDataString($packageId)
        $detail = Invoke-GraphGetWithRetry -Uri "$graphRoot/copilot/admin/catalog/packages/$encodedId"
        $details.Add($detail)
        [void]$completedIds.Add($packageId)

        if ($details.Count % $CheckpointEvery -eq 0) {
            $details.ToArray() | ConvertTo-Json -Depth 100 |
                Set-Content -LiteralPath $checkpointPath -Encoding utf8
            $elapsed = (Get-Date) - $started
            $rate = if ($elapsed.TotalSeconds -gt 0) { $details.Count / $elapsed.TotalSeconds } else { 0 }
            $remaining = if ($rate -gt 0) { [timespan]::FromSeconds(($inventory.Count - $processed) / $rate) } else { [timespan]::Zero }
            Write-Host ("  {0}/{1} details retrieved ({2:N1}/s, ~{3:hh\:mm\:ss} remaining)" -f
                        $processed, $inventory.Count, $rate, $remaining)
        }
    }

    $metadata = [ordered]@{
        exportedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        tenantId = $context.TenantId
        account = $context.Account
        authType = $context.AuthType
        apiVersion = $apiVersion
        requiredScope = $requiredScope
        platformFilter = if ($allPlatforms) { 'All platforms (unfiltered)' } else { $Platform }
        platformCounts = ($inventory | Group-Object platform |
                          Sort-Object Count -Descending |
                          ForEach-Object { [ordered]@{ platform = $_.Name; count = $_.Count } })
        excludeBlocked = [bool]$ExcludeBlocked
        modifiedSince = if ($PSBoundParameters.ContainsKey('ModifiedSince')) { $ModifiedSince.ToUniversalTime().ToString('o') } else { $null }
        inventoryCount = $inventory.Count
        detailCount = $details.Count
    }

    # Name the output for what it actually contains: calling an all-platform export
    # "agent-builder-*" would misrepresent it to every downstream consumer.
    $prefix = if ($allPlatforms) { 'all-agents' } else { 'agent-builder' }
    $inventoryFile = Join-Path $OutputDirectory "$prefix-inventory.json"
    $detailsFileOut = Join-Path $OutputDirectory "$prefix-details.json"

    $inventory | ConvertTo-Json -Depth 100 | Set-Content -Path $inventoryFile -Encoding utf8
    $details.ToArray() | ConvertTo-Json -Depth 100 | Set-Content -Path $detailsFileOut -Encoding utf8
    $metadata | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutputDirectory 'export-metadata.json') -Encoding utf8

    if (Test-Path -LiteralPath $checkpointPath) { Remove-Item -LiteralPath $checkpointPath -Force }

    Write-Host "Export complete: $OutputDirectory ($($details.Count) detailed agents)"

    if ($MinSessions -gt 0 -or $MinActiveUsers -gt 0) {
        Write-Host ''
        Write-Host 'Applying usage selection to the exported data...'
        # Delegate to the selector so the usage rules live in exactly one place. The full export is
        # always kept, because re-fetching details is the expensive part and must not be discarded.
        $detailsFile = $detailsFileOut
        $selectedFile = Join-Path $OutputDirectory "$prefix-details.selected.json"
        & (Join-Path $PSScriptRoot 'Select-ActiveAgents.ps1') `
            -DetailsPath $detailsFile -OutputPath $selectedFile `
            -MinSessions $MinSessions -MinActiveUsers $MinActiveUsers `
            -ActiveWithinDays $UsedWithinDays | Out-Null
        Write-Host "Usage-selected export: $selectedFile"
    }
}
finally {
    if (Get-MgContext) {
        Disconnect-MgGraph | Out-Null
    }
}
