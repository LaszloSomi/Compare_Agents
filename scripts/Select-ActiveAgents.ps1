#Requires -Version 7.0

<#
.SYNOPSIS
Narrows an Agent Builder export to the agents worth comparing for overlap.

.DESCRIPTION
Overlap analysis is O(n^2), so restricting it to agents that are actually in use is the single
largest cost reduction available once the export exists. This pairs with a separate lifecycle
process that blocks and eventually removes dormant agents: lifecycle handles the unused tail,
Compare-Agents handles overlap among the agents people actually rely on.

Two facts about the Package Management API shape this design:

  * Usage telemetry (activeUsers, totalSessions, lastUsedDateTime) is returned ONLY by the
    per-package detail call, never by the list call. Usage therefore cannot reduce the number of
    Graph requests; it reduces analysis cost after the export exists.

  * lastModifiedDateTime IS available on the list call, but it is a poor proxy for activity.
    On the reference tenant a 30-day lastModifiedDateTime filter dropped 2 of the 4 genuinely
    active agents, because a stable well-adopted agent is configured once and then simply used.
    Do not substitute it for real usage.

Safety rules built into the filter:

  * New agents are protected by a creation grace period. An agent created days ago has no usage
    because nobody has had the chance to adopt it yet, not because it is dormant.
  * Agents whose telemetry is missing are kept by default, because absence of evidence is not
    evidence of absence and telemetry can lag or reset after a republish.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    # Matches the lifecycle policy: an agent used within this window counts as active.
    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$ActiveWithinDays = 30,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinSessions = 0,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinActiveUsers = 0,

    # A brand-new agent has not had a chance to be adopted, so never treat it as dormant.
    [Parameter()]
    [ValidateRange(0, 3650)]
    [int]$GraceDaysForNewAgents = 30,

    # Telemetry can lag or reset; dropping unknown usage silently removes real agents from scope.
    [Parameter()]
    [switch]$ExcludeUnknownUsage,

    [Parameter()]
    [datetime]$ReferenceDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) {
    throw "Agent details file not found: $DetailsPath"
}

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -eq 0) { throw "No agents were found in '$DetailsPath'." }

function Get-AgeInDays {
    param($Value)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    return [int][math]::Floor(($ReferenceDate.ToUniversalTime() - ([datetime]$Value).ToUniversalTime()).TotalDays)
}

function Get-Numeric {
    param($Value)
    $parsed = 0.0
    if ($null -ne $Value -and [double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0
}

$kept = [System.Collections.Generic.List[object]]::new()
$decisions = [System.Collections.Generic.List[object]]::new()

# Setting an explicit usage threshold changes the question from "which agents look dormant?" to
# "which agents provably clear this bar?", and those need different handling of missing evidence.
$thresholdMode = ($MinSessions -gt 0) -or ($MinActiveUsers -gt 0)

if ($thresholdMode) {
    Write-Host "Mode: usage threshold (sessions >= $MinSessions, users >= $MinActiveUsers, used within $ActiveWithinDays day(s))"
}
else {
    Write-Host "Mode: dormancy scoping (used within $ActiveWithinDays day(s), with safety defaults)"
}

foreach ($agent in $agents) {
    $usedAge = Get-AgeInDays $agent.lastUsedDateTime
    $createdAge = Get-AgeInDays $agent.createdDateTime
    $sessions = Get-Numeric $agent.totalSessions
    $users = Get-Numeric $agent.activeUsers
    $hasTelemetry = ($null -ne $usedAge) -or ($sessions -gt 0) -or ($users -gt 0)

    $include = $false
    $reason = 'dormant'

    if ($thresholdMode) {
        # Explicit selection. The caller asked for agents that DEMONSTRABLY clear a usage bar, so
        # every condition must hold. Neither safety escape hatch applies here: an agent with no
        # telemetry cannot demonstrate the threshold, and a brand-new agent with zero sessions does
        # not meet "at least N sessions" no matter how recently it was created.
        $meetsSessions = $sessions -ge $MinSessions
        $meetsUsers = $users -ge $MinActiveUsers
        $meetsRecency = ($null -ne $usedAge) -and ($usedAge -le $ActiveWithinDays)

        if (-not $hasTelemetry) { $reason = 'no-usage-telemetry' }
        elseif (-not $meetsSessions) { $reason = 'below-session-threshold' }
        elseif (-not $meetsUsers) { $reason = 'below-user-threshold' }
        elseif (-not $meetsRecency) { $reason = 'outside-recency-window' }
        else { $include = $true; $reason = 'meets-usage-threshold' }
    }
    else {
        # Dormancy scoping. Safe defaults apply, because absence of evidence is not evidence of
        # absence and a new agent has not yet had the chance to be adopted.
        if ($null -ne $usedAge -and $usedAge -le $ActiveWithinDays) {
            $include = $true; $reason = 'recently-used'
        }
        elseif ($null -ne $createdAge -and $createdAge -le $GraceDaysForNewAgents) {
            $include = $true; $reason = 'new-agent-grace-period'
        }
        elseif (-not $hasTelemetry -and -not $ExcludeUnknownUsage) {
            $include = $true; $reason = 'usage-unknown-kept-for-safety'
        }
    }

    if ($include) { $kept.Add($agent) }

    $decisions.Add([pscustomobject]@{
        Id               = $agent.id
        DisplayName      = $agent.displayName
        Included         = $include
        Reason           = $reason
        DaysSinceLastUse = $usedAge
        DaysSinceCreated = $createdAge
        TotalSessions    = $sessions
        ActiveUsers      = $users
    })
}

$excluded = $agents.Count - $kept.Count
$naiveBefore = [long]$agents.Count * ($agents.Count - 1) / 2
$naiveAfter = [long]$kept.Count * ($kept.Count - 1) / 2

Write-Host "Agents in export        : $($agents.Count)"
Write-Host "Kept for comparison     : $($kept.Count)"
Write-Host "Excluded as dormant     : $excluded"
Write-Host ''
Write-Host 'Reasons:'
$decisions | Group-Object Reason | Sort-Object Count -Descending |
    ForEach-Object { Write-Host ("  {0,-32} {1,5}" -f $_.Name, $_.Count) }
Write-Host ''
Write-Host "Exhaustive pairs before : $naiveBefore"
Write-Host "Exhaustive pairs after  : $naiveAfter"
if ($naiveAfter -gt 0) {
    Write-Host ("Comparison work reduced : {0:N1}x" -f ($naiveBefore / [double]$naiveAfter))
}

if ($kept.Count -lt 2) {
    Write-Warning 'Fewer than two agents remain, so no comparison is possible. Loosen the filter.'
}

Write-Warning ('Scope limitation: overlap between a kept agent and an excluded dormant agent will not be ' +
               'detected, and a dormant agent cannot be chosen as a consolidation target even if it is the ' +
               'better-configured canonical agent. Confirm the lifecycle process really does retire the ' +
               'excluded agents.')

# Duplicates are frequently the agents nobody adopted: someone clones an agent, it never gains
# users, and it lingers. Filtering hard on activity can therefore remove exactly the agents the
# analysis exists to find, so make that trade-off impossible to miss.
if ($agents.Count -gt 0) {
    $excludedShare = $excluded / [double]$agents.Count
    if ($excludedShare -ge 0.5) {
        # Build the message before formatting: -f binds to the last literal in a concatenation,
        # which would leave the placeholder unsubstituted.
        $template = 'This filter excluded {0:P0} of the registry. Duplicate agents are often the ' +
                    'unadopted ones, so an aggressive activity filter can remove the very overlap you ' +
                    'are looking for. Verify against an unfiltered run before trusting a reduced scope.'
        Write-Warning ($template -f $excludedShare)
    }
}
if ($ExcludeUnknownUsage) {
    Write-Warning ('-ExcludeUnknownUsage drops every agent whose telemetry is missing, not just agents ' +
                   'proven dormant. Use it only when you trust usage telemetry to be complete.')
}

if ($thresholdMode) {
    # These fields are returned by Graph but are NOT in the published copilotPackageDetail schema,
    # so their aggregation window is unspecified. Do not present the result as a windowed count.
    Write-Warning ('totalSessions and activeUsers are undocumented cumulative counters, not a rolling ' +
                   "window. This selection means 'lifetime sessions >= $MinSessions AND last used within " +
                   "$ActiveWithinDays day(s)', which APPROXIMATES but does not equal 'more than $MinSessions " +
                   "sessions in the last $ActiveWithinDays days'. A long-lived agent used once last week can " +
                   'satisfy it.')

    $noTelemetry = @($decisions | Where-Object Reason -eq 'no-usage-telemetry').Count
    if ($noTelemetry -gt 0) {
        Write-Warning ("$noTelemetry agent(s) were excluded because they report no usage telemetry at all. " +
                       'In threshold mode that is treated as "cannot demonstrate the threshold", so a ' +
                       'qualifying agent with missing telemetry would be missed.')
    }
}

if ($OutputPath) {
    $kept.ToArray() | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Filtered details written: $OutputPath"

    $decisionPath = [System.IO.Path]::ChangeExtension($OutputPath, 'decisions.csv')
    $decisions | Export-Csv -Path $decisionPath -NoTypeInformation -Encoding utf8
    Write-Host "Filter decisions written: $decisionPath"
}

return $decisions
