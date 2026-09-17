#Requires -Version 7.0

<#
.SYNOPSIS
Applies a staged dormancy policy to Agent Builder agents: warn, then block.

.DESCRIPTION
Classifies every agent in an existing export by days since last use and stages the response:

    0 - 29 days    Active            no action
    30 / 60 days   Idle              report for owner notification
    90+ days       Dormant           BLOCK (reversible)

It reuses the export produced by Export-AgentBuilderAgents.ps1. That export already carries every
field this decision needs - lastUsedDateTime, createdDateTime, isBlocked, ownerId - so no second
retrieval is required for the classification pass.

IMPORTANT API CONSTRAINTS, verified against Microsoft Learn:

  * Block/unblock exist only on the /beta endpoint. Microsoft states beta APIs are subject to
    change and are not supported for production use.
  * Block requires the delegated scope CopilotPackages.ReadWrite.All. The export only requests
    CopilotPackages.Read.All, so a live run needs broader consent and a fresh sign-in.
  * There is NO application permission for block, only delegated. This cannot run unattended as a
    service principal; a human admin must sign in.
  * There is NO delete operation in the Package Management API. Block, unblock, reassign and
    update are the only write operations. The "delete after a further 30 days" half of a lifecycle
    policy cannot be automated here today - this script reports those agents so an admin can remove
    them through the admin center.

SAFETY BEHAVIOUR:

  * Dry run is the default. -LiveMode is required to call block, and it prompts for confirmation.
  * Blocking is refused on a stale export, because dormancy computed from old data can block an
    agent that has been used since. Override deliberately with -AllowStaleExport.
  * An agent with no usage telemetry at all is never blocked. Absence of evidence is not evidence
    of dormancy, and telemetry can lag or reset after a republish.
  * Newly created agents are protected by a grace period; they have no usage because nobody has
    had the chance to adopt them yet.
  * Every run writes a decision CSV, and -Rollback reverses a previous live run from it.

.EXAMPLE
# Classify only - no Graph connection, no changes
Invoke-AgentLifecyclePolicy.ps1 -DetailsPath .\agent-builder-details.json

.EXAMPLE
# Block agents dormant for 90+ days, after a fresh export
Invoke-AgentLifecyclePolicy.ps1 -DetailsPath .\agent-builder-details.json `
  -TenantId contoso.onmicrosoft.com -LiveMode

.EXAMPLE
# Undo a previous live run
Invoke-AgentLifecyclePolicy.ps1 -Rollback .\agent-lifecycle-decisions.csv -TenantId contoso.onmicrosoft.com -LiveMode
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    [Parameter(Mandatory, ParameterSetName = 'Rollback')]
    [ValidateNotNullOrEmpty()]
    [string]$Rollback,

    [Parameter()]
    [string]$TenantId,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(1, 3650)]
    [int]$BlockAfterDays = 90,

    [Parameter(ParameterSetName = 'Apply')]
    [ValidateNotNull()]
    [int[]]$WarnAfterDays = @(30, 60),

    # A brand-new agent has no usage because nobody has had the chance to adopt it yet.
    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(0, 3650)]
    [int]$GraceDaysForNewAgents = 30,

    # Dormancy computed from an old export can block an agent that has been used since.
    [Parameter(ParameterSetName = 'Apply')]
    [ValidateRange(1, 8760)]
    [int]$MaxExportAgeHours = 24,

    [Parameter(ParameterSetName = 'Apply')]
    [switch]$AllowStaleExport,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$UseDeviceAuthentication,

    [Parameter()]
    [switch]$LiveMode,

    [Parameter(ParameterSetName = 'Apply')]
    [datetime]$ReferenceDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'

# Block/unblock are beta-only; there is no v1.0 equivalent.
$graphRoot   = 'https://graph.microsoft.com/beta'
$writeScope  = 'CopilotPackages.ReadWrite.All'

Write-Host "Mode: $(if ($LiveMode) { 'LIVE RUN - agents will be blocked' } else { 'DRY RUN - classification only' })"

function Connect-ForWrite {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is required. Install it with: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    if (-not (Get-Module -Name Microsoft.Graph.Authentication)) {
        Import-Module Microsoft.Graph.Authentication
    }

    $connect = @{ Scopes = $writeScope; NoWelcome = $true }
    if ($TenantId) { $connect.TenantId = $TenantId }
    if ($UseDeviceAuthentication) { $connect.UseDeviceAuthentication = $true }

    Connect-MgGraph @connect
    $context = Get-MgContext
    if ($null -eq $context) { throw 'Microsoft Graph authentication did not return a session context.' }
    if ($writeScope -notin $context.Scopes) {
        throw "The signed-in session lacks '$writeScope'. Blocking needs write consent, which the read-only export scope does not grant."
    }
    Write-Host "Signed in as $($context.Account)"
    return $context
}

function Invoke-PackageAction {
    param([string]$Id, [ValidateSet('block', 'unblock')][string]$Action)

    $encoded = [uri]::EscapeDataString($Id)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/copilot/admin/catalog/packages/$encoded/$Action" | Out-Null
            return @{ Ok = $true; Error = $null }
        }
        catch {
            $message = $_.Exception.Message
            $throttled = $message -match '\b429\b|\b503\b|\b504\b|Too Many Requests|Service Unavailable'
            if (-not $throttled -or $attempt -eq 5) { return @{ Ok = $false; Error = $message } }
            $delay = [math]::Min([math]::Pow(2, $attempt), 60)
            if ($message -match 'Retry-After[:\s]+(\d+)') { $delay = [int]$Matches[1] }
            Write-Warning "Graph throttled on $Action (attempt $attempt/5). Waiting $delay second(s)."
            Start-Sleep -Seconds $delay
        }
    }
}

# ---------------------------------------------------------------- ROLLBACK
if ($PSCmdlet.ParameterSetName -eq 'Rollback') {
    if (-not (Test-Path -LiteralPath $Rollback)) { throw "Decision file not found: $Rollback" }
    $blocked = @(Import-Csv -LiteralPath $Rollback | Where-Object { $_.Action -eq 'Block' -and $_.Applied -eq 'True' })

    Write-Host "Agents blocked by that run: $($blocked.Count)"
    if ($blocked.Count -eq 0) { Write-Host 'Nothing to roll back.'; return }

    if (-not $LiveMode) {
        Write-Host 'DRY RUN: would unblock the following agents. Re-run with -LiveMode to apply.'
        $blocked | Select-Object -First 20 | Format-Table DisplayName, Id -AutoSize | Out-String | Write-Host
        return
    }

    Connect-ForWrite | Out-Null
    try {
        $undone = 0
        foreach ($row in $blocked) {
            if ($PSCmdlet.ShouldProcess($row.DisplayName, 'Unblock agent')) {
                $result = Invoke-PackageAction -Id $row.Id -Action 'unblock'
                if ($result.Ok) { $undone++ } else { Write-Warning "Unblock failed for $($row.DisplayName): $($result.Error)" }
            }
        }
        Write-Host "Unblocked: $undone of $($blocked.Count)"
    }
    finally { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } }
    return
}

# ---------------------------------------------------------------- CLASSIFY
if (-not (Test-Path -LiteralPath $DetailsPath)) { throw "Agent details file not found: $DetailsPath" }
$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -eq 0) { throw "No agents were found in '$DetailsPath'." }

# Freshness: the export writes export-metadata.json beside the details file.
$exportAgeHours = $null
$metadataPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $DetailsPath)) 'export-metadata.json'
if (Test-Path -LiteralPath $metadataPath) {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($metadata.exportedAtUtc) {
        $exportAgeHours = [math]::Round(((Get-Date).ToUniversalTime() - ([datetime]$metadata.exportedAtUtc).ToUniversalTime()).TotalHours, 1)
        Write-Host "Export age: $exportAgeHours hour(s)"
    }
}
else {
    Write-Warning "No export-metadata.json beside the details file, so export age cannot be verified."
}

$sortedWarn = @($WarnAfterDays | Sort-Object -Unique)
Write-Host "Policy: warn at $($sortedWarn -join '/') days, block at $BlockAfterDays days"
Write-Host "Agents in export: $($agents.Count)"

function Get-AgeInDays {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [int][math]::Floor(($ReferenceDate.ToUniversalTime() - ([datetime]$Value).ToUniversalTime()).TotalDays)
}

$decisions = foreach ($agent in $agents) {
    $idle = Get-AgeInDays $agent.lastUsedDateTime
    $age = Get-AgeInDays $agent.createdDateTime
    $isBlocked = [bool]$agent.isBlocked

    $stage = 'Active'
    $action = 'None'
    $reason = ''

    if ($isBlocked) {
        $stage = 'AlreadyBlocked'; $reason = 'Agent is already blocked'
    }
    elseif ($null -eq $idle) {
        # Never used, or telemetry missing. These are not the same thing and the API does not
        # distinguish them, so never block on this signal alone.
        if ($null -ne $age -and $age -le $GraceDaysForNewAgents) {
            $stage = 'NewAgent'; $reason = "Created $age day(s) ago; inside the adoption grace period"
        }
        else {
            $stage = 'NoTelemetry'; $reason = 'No lastUsedDateTime recorded; needs manual review, never auto-blocked'
        }
    }
    elseif ($null -ne $age -and $age -le $GraceDaysForNewAgents) {
        $stage = 'NewAgent'; $reason = "Created $age day(s) ago; inside the adoption grace period"
    }
    elseif ($idle -ge $BlockAfterDays) {
        $stage = 'Dormant'; $action = 'Block'; $reason = "Unused for $idle day(s)"
    }
    else {
        $hit = @($sortedWarn | Where-Object { $idle -ge $_ } | Select-Object -Last 1)
        if ($hit.Count -gt 0) {
            $stage = "Idle$($hit[0])"; $action = 'Warn'; $reason = "Unused for $idle day(s); notify owner"
        }
        else {
            $reason = "Used $idle day(s) ago"
        }
    }

    [pscustomobject]@{
        Id               = $agent.id
        DisplayName      = $agent.displayName
        OwnerId          = $agent.ownerId
        DaysSinceLastUse = $idle
        DaysSinceCreated = $age
        TotalSessions    = $agent.totalSessions
        ActiveUsers      = $agent.activeUsers
        Stage            = $stage
        Action           = $action
        Reason           = $reason
        Applied          = $false
        # The Graph schema has no blocked-on date, so the moment we block is the only chance to
        # record one. Invoke-AgentDeletionReview.ps1 reads this to time the deletion stage.
        BlockedDateTimeUtc = ''
        Error            = ''
    }
}

Write-Host ''
Write-Host 'Classification:'
$decisions | Group-Object Stage | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("  {0,-16} {1,5}" -f $_.Name, $_.Count) }

$toBlock = @($decisions | Where-Object Action -eq 'Block')
$toWarn = @($decisions | Where-Object Action -eq 'Warn')
$noTelemetry = @($decisions | Where-Object Stage -eq 'NoTelemetry')

Write-Host ''
Write-Host ("  To block : {0}" -f $toBlock.Count)
Write-Host ("  To warn  : {0}" -f $toWarn.Count)

if ($noTelemetry.Count -gt 0) {
    Write-Warning ("$($noTelemetry.Count) agent(s) report no usage telemetry at all. They are NOT blocked, because " +
                   'missing telemetry is not proof of dormancy. Review them manually.')
}

# ---------------------------------------------------------------- APPLY
if ($LiveMode -and $toBlock.Count -gt 0) {
    if ($null -ne $exportAgeHours -and $exportAgeHours -gt $MaxExportAgeHours -and -not $AllowStaleExport) {
        throw ("The export is $exportAgeHours hour(s) old, beyond the $MaxExportAgeHours-hour limit. Blocking on stale " +
               'dormancy data can block an agent that has been used since. Re-run the export, or pass -AllowStaleExport.')
    }

    Connect-ForWrite | Out-Null
    try {
        $applied = 0
        foreach ($row in $toBlock) {
            if ($PSCmdlet.ShouldProcess("$($row.DisplayName) (idle $($row.DaysSinceLastUse) days)", 'Block agent')) {
                $result = Invoke-PackageAction -Id $row.Id -Action 'block'
                if ($result.Ok) {
                    $row.Applied = $true
                    $row.BlockedDateTimeUtc = (Get-Date).ToUniversalTime().ToString('o')
                    $applied++
                }
                else {
                    $row.Error = $result.Error
                    Write-Warning "Block failed for $($row.DisplayName): $($result.Error)"
                }
            }
        }
        Write-Host ''
        Write-Host "Blocked: $applied of $($toBlock.Count)"
        Write-Host 'Reverse this run with:  -Rollback <decision csv> -LiveMode'
    }
    finally { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } }
}
elseif ($toBlock.Count -gt 0) {
    Write-Host ''
    Write-Host 'DRY RUN: the following agents would be blocked. Re-run with -LiveMode to apply.'
    $toBlock | Sort-Object DaysSinceLastUse -Descending | Select-Object -First 15 |
        Format-Table DisplayName, DaysSinceLastUse, TotalSessions, ActiveUsers -AutoSize | Out-String | Write-Host
    if ($toBlock.Count -gt 15) { Write-Host ("  ... and {0} more" -f ($toBlock.Count - 15)) }
}

if (-not $CsvPath) {
    $CsvPath = Join-Path (Split-Path -Parent (Resolve-Path -LiteralPath $DetailsPath)) 'agent-lifecycle-decisions.csv'
}
$decisions | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
Write-Host "Decisions written: $CsvPath"

Write-Warning ('The Package Management API has no delete operation - block, unblock, reassign and update only. ' +
               'A "delete after N more days" stage cannot be automated here; use this report to remove agents ' +
               'through the admin center.')

Write-Host ''
Write-Host ('Next stage: track how long these blocks persist with' +
            "`n  Invoke-AgentDeletionReview.ps1 -DetailsPath <fresh export> -DecisionsPath $CsvPath")

return $decisions
