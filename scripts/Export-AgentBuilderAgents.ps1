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
    [int]$CheckpointEvery = 250,

    [Parameter()]
    [switch]$LiveMode = $false
)

$ErrorActionPreference = 'Stop'
$apiVersion = if ($UseBeta) { 'beta' } else { 'v1.0' }
$graphRoot = "https://graph.microsoft.com/$apiVersion"
$requiredScope = 'CopilotPackages.Read.All'
$checkpointName = 'agent-builder-details.checkpoint.json'

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

function Invoke-GraphGetWithRetry {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-MgGraphRequest -Method GET -Uri $Uri
        }
        catch {
            $message = $_.Exception.Message
            $isThrottled = $message -match '\b429\b|\b503\b|\b504\b|Too Many Requests|Service Unavailable'
            if (-not $isThrottled -or $attempt -eq $MaxAttempts) { throw }

            # Honor Retry-After when Graph supplies it, otherwise back off exponentially.
            $delay = [math]::Pow(2, $attempt)
            if ($message -match 'Retry-After[:\s]+(\d+)') { $delay = [int]$Matches[1] }
            $delay = [math]::Min($delay, 120)
            Write-Warning "Graph throttled (attempt $attempt/$MaxAttempts). Waiting $delay second(s)."
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

    if ($null -eq $context) {
        throw 'Microsoft Graph authentication did not return a session context.'
    }

    if ($requiredScope -notin $context.Scopes) {
        throw "The authenticated session does not include the required '$requiredScope' scope."
    }

    $filterParts = @("platform eq 'Microsoft 365 Copilot Agent Builder'")
    if ($PSBoundParameters.ContainsKey('ModifiedSince')) {
        $stamp = $ModifiedSince.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ')
        $filterParts += "lastModifiedDateTime gt $stamp"
        Write-Warning ('lastModifiedDateTime filters configuration changes, not usage. A stable, ' +
                       'heavily used agent may be excluded. Do not treat this as an activity filter.')
    }
    $encodedFilter = [uri]::EscapeDataString(($filterParts -join ' and '))
    $listUri = "$graphRoot/copilot/admin/catalog/packages?`$filter=$encodedFilter"
    $inventory = @(Invoke-PagedGraphGet -Uri $listUri)

    Write-Host "Agent Builder packages found: $($inventory.Count)"

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
        platformFilter = 'Microsoft 365 Copilot Agent Builder'
        excludeBlocked = [bool]$ExcludeBlocked
        modifiedSince = if ($PSBoundParameters.ContainsKey('ModifiedSince')) { $ModifiedSince.ToUniversalTime().ToString('o') } else { $null }
        inventoryCount = $inventory.Count
        detailCount = $details.Count
    }

    $inventory | ConvertTo-Json -Depth 100 | Set-Content -Path (Join-Path $OutputDirectory 'agent-builder-inventory.json') -Encoding utf8
    $details.ToArray() | ConvertTo-Json -Depth 100 | Set-Content -Path (Join-Path $OutputDirectory 'agent-builder-details.json') -Encoding utf8
    $metadata | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutputDirectory 'export-metadata.json') -Encoding utf8

    if (Test-Path -LiteralPath $checkpointPath) { Remove-Item -LiteralPath $checkpointPath -Force }

    Write-Host "Export complete: $OutputDirectory ($($details.Count) detailed agents)"

    if ($MinSessions -gt 0 -or $MinActiveUsers -gt 0) {
        Write-Host ''
        Write-Host 'Applying usage selection to the exported data...'
        # Delegate to the selector so the usage rules live in exactly one place. The full export is
        # always kept, because re-fetching details is the expensive part and must not be discarded.
        $detailsFile = Join-Path $OutputDirectory 'agent-builder-details.json'
        $selectedFile = Join-Path $OutputDirectory 'agent-builder-details.selected.json'
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
