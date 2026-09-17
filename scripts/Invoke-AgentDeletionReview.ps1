#Requires -Version 7.0

<#
.SYNOPSIS
Tracks how long agents have been blocked and reports which ones have passed the deletion threshold.

.DESCRIPTION
This is the final stage of the lifecycle policy: warn -> block -> delete. It answers the question
"which agents have been blocked for 30 days or more?" and produces a removal worklist.

THE CORE PROBLEM THIS SOLVES

The Graph package schema has no blocked-on date. It exposes isBlocked as a bare boolean, so the
tenant itself cannot tell you how long an agent has been blocked. There is no audit field, no
blockedDateTime, nothing. That means the elapsed time has to be measured, not queried.

This script therefore keeps its own ledger (agent-block-ledger.csv). Each run compares a fresh
export against the ledger and records:

    * an agent seen blocked for the first time    -> start its clock
    * an agent still blocked                      -> extend its observation window
    * an agent no longer blocked                  -> clear it, so the clock RESETS

The reset matters. Without it, an agent that was blocked, unblocked, used, and blocked again would
inherit its original date and be deleted on a clock it never actually ran.

CONSEQUENCE OF THIS DESIGN, STATED PLAINLY

On the first run the ledger is empty, so every currently blocked agent has its clock started today
and NOTHING is eligible for deletion. That is correct rather than a limitation - history that was
never recorded cannot be invented afterwards. Blocks applied by Invoke-AgentLifecyclePolicy.ps1 in
-LiveMode are the exception: pass -DecisionsPath to import their exact block timestamps.

DELETION IS NOT AUTOMATED, AND CANNOT BE

The Package Management API has six operations - list, get, update, block, unblock, reassign. There
is no delete. This script never attempts one. It produces a reviewed worklist for an admin to action
manually, and records the evidence behind each recommendation.

.EXAMPLE
# Run after every export to accumulate block history
Invoke-AgentDeletionReview.ps1 -DetailsPath .\agent-builder-details.json

.EXAMPLE
# Seed exact block dates from live policy runs, then report
Invoke-AgentDeletionReview.ps1 -DetailsPath .\agent-builder-details.json `
  -DecisionsPath .\agent-lifecycle-decisions.csv

.EXAMPLE
# Stricter: delete review after 60 days blocked
Invoke-AgentDeletionReview.ps1 -DetailsPath .\agent-builder-details.json -DeleteAfterBlockedDays 60
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    # The durable block history. Defaults to sitting beside the export.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LedgerPath,

    # Decision CSVs from Invoke-AgentLifecyclePolicy.ps1 live runs. These carry exact block
    # timestamps and are more precise than first-observation dates.
    [Parameter()]
    [string[]]$DecisionsPath,

    # Audit history from Get-AgentBlockHistory.ps1 (BlockedAgent / UnblockedAgent operations in the
    # unified audit log). This is the ONLY source that can recover a block date retroactively, so it
    # outranks every other signal. Columns: Id, Operation, DateUtc.
    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$BlockHistoryPath,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$DeleteAfterBlockedDays = 30,

    # Eligibility is decided from this export; stale data would age the clock incorrectly.
    [Parameter()]
    [ValidateRange(1, 8760)]
    [int]$MaxExportAgeHours = 24,

    [Parameter()]
    [switch]$AllowStaleExport,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    # Record observations without producing a worklist.
    [Parameter()]
    [switch]$UpdateLedgerOnly,

    [Parameter()]
    [datetime]$ReferenceDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) { throw "Agent details file not found: $DetailsPath" }
$exportDir = Split-Path -Parent (Resolve-Path -LiteralPath $DetailsPath)

if (-not $LedgerPath) { $LedgerPath = Join-Path $exportDir 'agent-block-ledger.csv' }
if (-not $CsvPath) { $CsvPath = Join-Path $exportDir 'agent-deletion-worklist.csv' }

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -eq 0) { throw "No agents were found in '$DetailsPath'." }

# ------------------------------------------------------------- OBSERVATION TIME
# The ledger must advance by the age of the DATA, not the age of the script run. Using "now" for an
# export taken a week ago would credit the agent with a week of blocking that was never observed.
$observedUtc = $ReferenceDate.ToUniversalTime()
$exportAgeHours = $null
$metadataPath = Join-Path $exportDir 'export-metadata.json'
if (Test-Path -LiteralPath $metadataPath) {
    $metadata = Get-Content -LiteralPath $metadataPath -Raw -Encoding utf8 | ConvertFrom-Json
    if ($metadata.exportedAtUtc) {
        $observedUtc = ([datetime]$metadata.exportedAtUtc).ToUniversalTime()
        $exportAgeHours = [math]::Round(($ReferenceDate.ToUniversalTime() - $observedUtc).TotalHours, 1)
        Write-Host "Export age: $exportAgeHours hour(s)"
    }
}
else {
    Write-Warning 'No export-metadata.json beside the details file, so export age cannot be verified.'
}

if ($null -ne $exportAgeHours -and $exportAgeHours -gt $MaxExportAgeHours -and -not $AllowStaleExport -and -not $UpdateLedgerOnly) {
    throw ("The export is $exportAgeHours hour(s) old, beyond the $MaxExportAgeHours-hour limit. An agent may have " +
           'been unblocked since it was taken, which would reset its clock. Re-run the export, or pass ' +
           '-AllowStaleExport to report on the stale data anyway.')
}

function ConvertTo-Utc {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    try { return ([datetime]$Value).ToUniversalTime() } catch { return $null }
}

function Get-DaysBetween {
    param([datetime]$From, [datetime]$To)
    return [int][math]::Floor(($To - $From).TotalDays)
}

# ------------------------------------------------------------- LOAD LEDGER
$ledger = @{}
if (Test-Path -LiteralPath $LedgerPath) {
    foreach ($row in @(Import-Csv -LiteralPath $LedgerPath)) {
        if ([string]::IsNullOrWhiteSpace($row.Id)) { continue }
        $ledger[$row.Id] = [pscustomobject]@{
            Id                       = $row.Id
            DisplayName              = $row.DisplayName
            OwnerId                  = $row.OwnerId
            BlockStartUtc            = ConvertTo-Utc $row.BlockStartUtc
            LastObservedBlockedUtc   = ConvertTo-Utc $row.LastObservedBlockedUtc
            ClearedUtc               = ConvertTo-Utc $row.ClearedUtc
            ObservationCount         = [int]($row.ObservationCount ?? 0)
            Precision                = $row.Precision
        }
    }
    Write-Host "Ledger loaded: $($ledger.Count) tracked agent(s) from $LedgerPath"
}
else {
    Write-Host "No ledger yet. Creating one at $LedgerPath"
    Write-Host 'First run: every blocked agent starts its clock now, so none will be eligible yet.'
}

# ------------------------------------------------------------- SEED EXACT DATES
# A block we applied ourselves has a known timestamp. That is strictly better than "first seen
# blocked on", which is only a lower bound.
$seeded = 0
foreach ($decisionFile in @($DecisionsPath)) {
    if ([string]::IsNullOrWhiteSpace($decisionFile)) { continue }
    foreach ($resolved in @(Resolve-Path -Path $decisionFile -ErrorAction SilentlyContinue)) {
        foreach ($row in @(Import-Csv -LiteralPath $resolved.Path)) {
            if ($row.Action -ne 'Block' -or $row.Applied -ne 'True') { continue }
            $exact = ConvertTo-Utc $row.BlockedDateTimeUtc
            if (-not $exact) { continue }

            $existing = $ledger[$row.Id]
            # Only tighten: never move a clock later than what the ledger already believes, and
            # never overwrite an exact date with a different exact date from an older run.
            if ($null -eq $existing -or $existing.Precision -ne 'Exact' -or $exact -lt $existing.BlockStartUtc) {
                $ledger[$row.Id] = [pscustomobject]@{
                    Id                     = $row.Id
                    DisplayName            = $row.DisplayName
                    OwnerId                = $row.OwnerId
                    BlockStartUtc          = $exact
                    LastObservedBlockedUtc = if ($existing) { $existing.LastObservedBlockedUtc } else { $exact }
                    ClearedUtc             = $null
                    ObservationCount       = if ($existing) { $existing.ObservationCount } else { 0 }
                    Precision              = 'Exact'
                }
                $seeded++
            }
        }
    }
}
if ($seeded -gt 0) { Write-Host "Seeded $seeded exact block date(s) from policy decision files." }

# ------------------------------------------------------------- SEED FROM AUDIT LOG
# The unified audit log records BlockedAgent and UnblockedAgent operations. Replaying them gives the
# true current block start even for blocks applied by another admin, months before this ledger
# existed. It outranks both first-observation and policy timestamps because it is the only source
# that sees the whole event history, including unblocks.
$auditSeeded = 0
if ($BlockHistoryPath) {
    if (-not (Test-Path -LiteralPath $BlockHistoryPath)) { throw "Block history file not found: $BlockHistoryPath" }

    $history = @(Import-Csv -LiteralPath $BlockHistoryPath) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_.Id) -and -not [string]::IsNullOrWhiteSpace($_.DateUtc) }

    foreach ($group in ($history | Group-Object Id)) {
        $events = @($group.Group |
            ForEach-Object { [pscustomobject]@{ Operation = $_.Operation; When = ConvertTo-Utc $_.DateUtc } } |
            Where-Object { $null -ne $_.When } |
            Sort-Object When)
        if ($events.Count -eq 0) { continue }

        # Walk forward; the surviving start is the last block with no later unblock.
        $currentStart = $null
        foreach ($event in $events) {
            if ($event.Operation -eq 'BlockedAgent') { if ($null -eq $currentStart) { $currentStart = $event.When } }
            elseif ($event.Operation -eq 'UnblockedAgent') { $currentStart = $null }
        }
        # Last event was an unblock, so any later block happened outside the audit window. Leave it
        # to first-observation rather than inventing a date.
        if ($null -eq $currentStart) { continue }

        $existing = $ledger[$group.Name]
        $ledger[$group.Name] = [pscustomobject]@{
            Id                     = $group.Name
            DisplayName            = if ($existing) { $existing.DisplayName } else { '' }
            OwnerId                = if ($existing) { $existing.OwnerId } else { '' }
            BlockStartUtc          = $currentStart
            LastObservedBlockedUtc = if ($existing) { $existing.LastObservedBlockedUtc } else { $currentStart }
            ClearedUtc             = $null
            ObservationCount       = if ($existing) { $existing.ObservationCount } else { 0 }
            Precision              = 'Audit'
        }
        $auditSeeded++
    }
    Write-Host "Recovered $auditSeeded block date(s) from audit history."
}

# ------------------------------------------------------------- OBSERVE
$startedClocks = 0
$restarted = 0
$cleared = 0

foreach ($agent in $agents) {
    $id = [string]$agent.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    $isBlocked = [bool]$agent.isBlocked
    $entry = $ledger[$id]

    if ($isBlocked) {
        if ($null -eq $entry) {
            $ledger[$id] = [pscustomobject]@{
                Id                     = $id
                DisplayName            = $agent.displayName
                OwnerId                = $agent.ownerId
                BlockStartUtc          = $observedUtc
                LastObservedBlockedUtc = $observedUtc
                ClearedUtc             = $null
                ObservationCount       = 1
                Precision              = 'FirstObserved'
            }
            $startedClocks++
        }
        elseif ($null -ne $entry.ClearedUtc) {
            # It was unblocked at some point, so this is a NEW block. Reset the clock.
            $entry.BlockStartUtc = $observedUtc
            $entry.ClearedUtc = $null
            $entry.ObservationCount = 1
            $entry.Precision = 'FirstObserved'
            $entry.DisplayName = $agent.displayName
            $entry.OwnerId = $agent.ownerId
            $restarted++
        }
        else {
            if ($null -eq $entry.BlockStartUtc) { $entry.BlockStartUtc = $observedUtc }
            if ($null -eq $entry.LastObservedBlockedUtc -or $observedUtc -gt $entry.LastObservedBlockedUtc) {
                $entry.LastObservedBlockedUtc = $observedUtc
                $entry.ObservationCount++
            }
            $entry.DisplayName = $agent.displayName
            $entry.OwnerId = $agent.ownerId
        }
    }
    elseif ($null -ne $entry -and $null -eq $entry.ClearedUtc) {
        $entry.ClearedUtc = $observedUtc
        $entry.DisplayName = $agent.displayName
        $cleared++
    }
}

Write-Host ''
Write-Host 'Ledger update:'
Write-Host ("  Clocks started  : {0}" -f $startedClocks)
Write-Host ("  Clocks restarted: {0}" -f $restarted)
Write-Host ("  Blocks released : {0}" -f $cleared)

$ledgerRows = $ledger.Values | Sort-Object DisplayName | ForEach-Object {
    [pscustomobject]@{
        Id                     = $_.Id
        DisplayName            = $_.DisplayName
        OwnerId                = $_.OwnerId
        BlockStartUtc          = if ($_.BlockStartUtc) { $_.BlockStartUtc.ToString('o') } else { '' }
        LastObservedBlockedUtc = if ($_.LastObservedBlockedUtc) { $_.LastObservedBlockedUtc.ToString('o') } else { '' }
        ClearedUtc             = if ($_.ClearedUtc) { $_.ClearedUtc.ToString('o') } else { '' }
        ObservationCount       = $_.ObservationCount
        Precision              = $_.Precision
    }
}
$ledgerRows | Export-Csv -Path $LedgerPath -NoTypeInformation -Encoding utf8
Write-Host "Ledger written: $LedgerPath"

if ($UpdateLedgerOnly) { return $ledgerRows }

# ------------------------------------------------------------- EVALUATE
$results = foreach ($agent in $agents) {
    $id = [string]$agent.id
    if ([string]::IsNullOrWhiteSpace($id)) { continue }
    if (-not [bool]$agent.isBlocked) { continue }

    $entry = $ledger[$id]
    $blockStart = $entry.BlockStartUtc
    $daysBlocked = if ($blockStart) { Get-DaysBetween -From $blockStart -To $observedUtc } else { 0 }
    $lastUsed = ConvertTo-Utc $agent.lastUsedDateTime

    $status = 'BlockedRecently'
    $reason = "Blocked for $daysBlocked of $DeleteAfterBlockedDays day(s)"

    if ($null -ne $lastUsed -and $null -ne $blockStart -and $lastUsed -gt $blockStart) {
        # Someone used it after it was blocked. Either the block did not take effect or it was
        # lifted and re-applied without being observed. Either way, do not propose deletion.
        $status = 'UsedSinceBlock'
        $reason = "Used on $($lastUsed.ToString('yyyy-MM-dd')), after the block began. Investigate before removing."
    }
    elseif ($daysBlocked -ge $DeleteAfterBlockedDays) {
        $status = 'EligibleForDeletion'
        $reason = "Blocked and unused for $daysBlocked day(s); no one has requested it back"
    }
    elseif ($entry.Precision -eq 'FirstObserved' -and $entry.ObservationCount -le 1) {
        $status = 'ClockStartedNow'
        $reason = 'First time observed blocked. The true block date is unknown and may be earlier.'
    }

    [pscustomobject]@{
        Id             = $id
        DisplayName    = $agent.displayName
        OwnerId        = $agent.ownerId
        AppId          = $agent.appId
        Status         = $status
        DaysBlocked    = $daysBlocked
        BlockStartUtc  = if ($blockStart) { $blockStart.ToString('yyyy-MM-dd') } else { '' }
        Precision      = $entry.Precision
        Observations   = $entry.ObservationCount
        LastUsedUtc    = if ($lastUsed) { $lastUsed.ToString('yyyy-MM-dd') } else { '' }
        TotalSessions  = $agent.totalSessions
        ActiveUsers    = $agent.activeUsers
        Reason         = $reason
    }
}

$results = @($results)
$eligible = @($results | Where-Object Status -eq 'EligibleForDeletion')
$anomalies = @($results | Where-Object Status -eq 'UsedSinceBlock')
$startingNow = @($results | Where-Object Status -eq 'ClockStartedNow')

Write-Host ''
Write-Host ("Blocked agents in export: {0}" -f $results.Count)
if ($results.Count -gt 0) {
    $results | Group-Object Status | Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("  {0,-20} {1,5}" -f $_.Name, $_.Count) }
}

if ($startingNow.Count -gt 0) {
    Write-Warning ("$($startingNow.Count) agent(s) were seen blocked for the first time. Their real block date is " +
                   'unknown, so the clock starts today and they cannot be eligible for another ' +
                   "$DeleteAfterBlockedDays day(s). Run this script on a schedule to build history.")
}

if ($anomalies.Count -gt 0) {
    Write-Warning ("$($anomalies.Count) blocked agent(s) show usage AFTER the block began. Excluded from deletion " +
                   'pending investigation.')
}

if ($eligible.Count -gt 0) {
    Write-Host ''
    Write-Host ("DELETION WORKLIST - {0} agent(s) blocked {1}+ days:" -f $eligible.Count, $DeleteAfterBlockedDays)
    $eligible | Sort-Object DaysBlocked -Descending | Select-Object -First 20 |
        Format-Table DisplayName, DaysBlocked, BlockStartUtc, Precision, OwnerId -AutoSize | Out-String | Write-Host
    if ($eligible.Count -gt 20) { Write-Host ("  ... and {0} more in the CSV" -f ($eligible.Count - 20)) }

    $owners = @($eligible | Where-Object { $_.OwnerId } | Group-Object OwnerId | Sort-Object Count -Descending)
    if ($owners.Count -gt 0) {
        Write-Host 'Final notice should go to these owners:'
        $owners | Select-Object -First 10 |
            ForEach-Object { Write-Host ("  {0,-45} {1} agent(s)" -f $_.Name, $_.Count) }
    }
}
else {
    Write-Host ''
    Write-Host "No agent has been continuously blocked for $DeleteAfterBlockedDays day(s) yet."
}

$results | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
Write-Host ''
Write-Host "Worklist written: $CsvPath"

if ($eligible.Count -gt 0) {
    Write-Host ''
    Write-Host 'HOW TO REMOVE THESE (verified against Microsoft Learn):'
    Write-Host '  Microsoft 365 admin center > Agents > All agents'
    Write-Host '  Filter Platform = "Agent Builder in Microsoft Copilot"'
    Write-Host '  Select the vertical ellipses next to the agent, then Delete.'
    Write-Host ''
    Write-Host '  Deleting also removes all associated files AND the underlying SharePoint Embedded'
    Write-Host '  container. It is irreversible, and can take up to 24 hours to reach every user.'
}

Write-Warning ('Deletion is NOT automated, by design and by constraint. The Package Management API exposes list, ' +
               'get, update, block, unblock and reassign only - there is no delete operation, and no PowerShell ' +
               'cmdlet deletes an Agent Builder agent. Admin-center deletion is the supported path.')

return $results
