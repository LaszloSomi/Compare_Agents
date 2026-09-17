#Requires -Version 7.0

<#
.SYNOPSIS
Runs the Compare-Agents analysis pipeline end to end and prints a review plan.

.DESCRIPTION
The analysis stages are separate scripts so each can be run and validated on its own, but a normal
assessment runs all of them in a fixed order with matching paths. Chaining them by hand is easy to
get wrong and easy to forget after a break, so this orchestrates the verified sequence:

  1. Select-AgentsBySource.ps1      (optional)  scope to one system
  2. Select-ActiveAgents.ps1        (optional)  scope to agents in use
  3. Get-AgentUsagePriority.ps1                 rank agents P1/P2/P3 by adoption
  4. Get-AgentComparisonCandidates.ps1          blocking + Pass 1 cascade routing
  5. Get-PurposeSimilarity.ps1                  order the semantic review queue

It performs no authentication and no Graph calls: point it at an existing export. It also does not
score confidence or decide consolidation. Those remain reasoning steps, because the evidence rules
in SKILL.md require judgement that a script cannot make. What this produces is the prepared,
prioritized queue those steps work through.

.EXAMPLE
Invoke-CompareAgentsPipeline.ps1 -DetailsPath .\agent-builder-details.json

.EXAMPLE
Invoke-CompareAgentsPipeline.ps1 -DetailsPath .\details.json -Source ServiceNow -OutputDirectory .\snow
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    # Scope to one or more data sources, e.g. 'ServiceNow'. Preferred over -ActiveOnly, because a
    # connector scope keeps duplicate pairs together while an activity filter can split them.
    [Parameter()]
    [string[]]$Source,

    # Scope to agents in use. Duplicates are often the unadopted agents, so this can remove the
    # very overlap the analysis exists to find. Use deliberately.
    [Parameter()]
    [switch]$ActiveOnly,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$ActiveWithinDays = 30,

    # Explicit usage selection, e.g. -MinSessions 5 keeps only agents that provably clear the bar.
    # Setting either switches scoping from "exclude dormant" to "must demonstrate this usage", so
    # agents with missing telemetry are excluded rather than kept for safety.
    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinSessions = 0,

    [Parameter()]
    [ValidateRange(0, [int]::MaxValue)]
    [int]$MinActiveUsers = 0,

    [Parameter()]
    [datetime]$ReferenceDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) {
    throw "Agent details file not found: $DetailsPath"
}

$scriptRoot = $PSScriptRoot
$resolvedDetails = (Resolve-Path -LiteralPath $DetailsPath).Path

if (-not $OutputDirectory) {
    $OutputDirectory = Split-Path -Parent $resolvedDetails
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

function Write-Stage {
    param([int]$Number, [string]$Title)
    Write-Host ''
    Write-Host ("[{0}] {1}" -f $Number, $Title) -ForegroundColor Cyan
}

$stage = 0
$workingPath = $resolvedDetails
$scopeNotes = [System.Collections.Generic.List[string]]::new()

$originalCount = @(Get-Content -LiteralPath $resolvedDetails -Raw -Encoding utf8 | ConvertFrom-Json).Count
Write-Host "Compare-Agents pipeline"
Write-Host "  input            : $resolvedDetails"
Write-Host "  agents in export : $originalCount"
Write-Host "  output directory : $OutputDirectory"

if ($Source) {
    $stage++
    Write-Stage $stage "Scoping to data source: $($Source -join ', ')"
    $scopedPath = Join-Path $OutputDirectory 'agent-details.scoped.json'
    & (Join-Path $scriptRoot 'Select-AgentsBySource.ps1') `
        -DetailsPath $workingPath -Source $Source -OutputPath $scopedPath | Out-Null
    $workingPath = $scopedPath
    $scopeNotes.Add("Scoped to source(s): $($Source -join ', '). Cross-system overlap is out of scope.")
}

if ($ActiveOnly -or $MinSessions -gt 0 -or $MinActiveUsers -gt 0) {
    $stage++
    $usingThreshold = ($MinSessions -gt 0) -or ($MinActiveUsers -gt 0)
    $label = if ($usingThreshold) {
        "Selecting agents with >= $MinSessions session(s), >= $MinActiveUsers user(s), used within $ActiveWithinDays days"
    } else {
        "Scoping to agents active within $ActiveWithinDays days"
    }
    Write-Stage $stage $label

    $activePath = Join-Path $OutputDirectory 'agent-details.active.json'
    & (Join-Path $scriptRoot 'Select-ActiveAgents.ps1') `
        -DetailsPath $workingPath -OutputPath $activePath `
        -ActiveWithinDays $ActiveWithinDays -MinSessions $MinSessions -MinActiveUsers $MinActiveUsers `
        -ReferenceDate $ReferenceDate | Out-Null
    $workingPath = $activePath

    if ($usingThreshold) {
        $scopeNotes.Add("Selected agents meeting a usage threshold. Agents with missing telemetry were " +
                        "excluded, and cumulative counters are not a rolling window.")
    }
    else {
        $scopeNotes.Add("Filtered to agents used within $ActiveWithinDays days. Dormant duplicates are excluded.")
    }
}

$scopedCount = @(Get-Content -LiteralPath $workingPath -Raw -Encoding utf8 | ConvertFrom-Json).Count
if ($scopedCount -lt 2) {
    throw "Only $scopedCount agent(s) remain after scoping, so no comparison is possible. Loosen the scope."
}

$stage++
Write-Stage $stage 'Ranking agents by usage priority'
$usagePath = Join-Path $OutputDirectory 'agent-usage-priority.csv'
$usage = & (Join-Path $scriptRoot 'Get-AgentUsagePriority.ps1') `
    -DetailsPath $workingPath -CsvPath $usagePath -ReferenceDate $ReferenceDate

$stage++
Write-Stage $stage 'Building candidate pairs (blocking + Pass 1 cascade)'
$candidatePath = Join-Path $OutputDirectory 'agent-comparison-candidates.csv'
$candidates = & (Join-Path $scriptRoot 'Get-AgentComparisonCandidates.ps1') `
    -DetailsPath $workingPath -CsvPath $candidatePath

$stage++
Write-Stage $stage 'Ordering the semantic review queue'
$similarityPath = Join-Path $OutputDirectory 'agent-purpose-similarity.csv'
$ranked = & (Join-Path $scriptRoot 'Get-PurposeSimilarity.ps1') `
    -DetailsPath $workingPath -CandidatePath $candidatePath -CsvPath $similarityPath

$exhaustive = [long]$scopedCount * ($scopedCount - 1) / 2
$highCandidates = @($candidates | Where-Object Pass1Route -eq 'HighCandidate')
$p1 = @($usage | Where-Object PriorityBand -eq 'P1')

# At scale the actionable unit is a CLUSTER, not a pair. 5,000 agents produced 92,000 candidate
# pairs but only 75 connected components: a reviewer holds ~75 consolidation conversations, not
# 92,000 pair reviews. Report components so the queue is sized to the work that actually happens.
$parent = @{}
function Find-Root {
    param([int]$Node)
    if (-not $parent.ContainsKey($Node)) { $parent[$Node] = $Node }
    $root = $Node
    while ($parent[$root] -ne $root) { $root = $parent[$root] }
    while ($parent[$Node] -ne $root) { $next = $parent[$Node]; $parent[$Node] = $root; $Node = $next }
    return $root
}
function Join-Node {
    param([int]$Left, [int]$Right)
    $a = Find-Root $Left; $b = Find-Root $Right
    if ($a -ne $b) { $parent[$a] = $b }
}

foreach ($pair in $highCandidates) { Join-Node ([int]$pair.LeftNumber) ([int]$pair.RightNumber) }

$members = @{}
$pairCount = @{}
foreach ($pair in $highCandidates) {
    $root = Find-Root ([int]$pair.LeftNumber)
    if (-not $members.ContainsKey($root)) {
        $members[$root] = [System.Collections.Generic.HashSet[int]]::new()
        $pairCount[$root] = 0
    }
    [void]$members[$root].Add([int]$pair.LeftNumber)
    [void]$members[$root].Add([int]$pair.RightNumber)
    $pairCount[$root]++
}

# Index usage by agent id so a cluster can be ranked by the disruption it would cause.
# Agent numbers refer to position in the EXPORT, but the usage CSV is sorted by priority, so
# indexing usage by its own row position silently attributes one agent's usage to another.
# Join on the stable id the candidate rows already carry instead.
$usageById = @{}
foreach ($row in $usage) {
    if (-not [string]::IsNullOrWhiteSpace($row.Id)) { $usageById[[string]$row.Id] = $row }
}
$idByNumber = @{}
$nameByNumber = @{}
foreach ($pair in $candidates) {
    $idByNumber[[int]$pair.LeftNumber] = [string]$pair.LeftId
    $idByNumber[[int]$pair.RightNumber] = [string]$pair.RightId
    $nameByNumber[[int]$pair.LeftNumber] = $pair.LeftName
    $nameByNumber[[int]$pair.RightNumber] = $pair.RightName
}

# A very large component is usually "everyone on one connector", not one duplicate set.
$largeClusterThreshold = 25

$clusters = foreach ($root in $members.Keys) {
    $agentNumbers = @($members[$root] | Sort-Object)
    $sessions = 0.0; $users = 0.0; $topBand = 'P3'; $topScore = 0
    foreach ($number in $agentNumbers) {
        $agentId = $idByNumber[$number]
        $row = if ($agentId) { $usageById[$agentId] } else { $null }
        if ($null -eq $row) { continue }
        $sessions += [double]$row.TotalSessions
        $users += [double]$row.ActiveUsers
        if ([int]$row.UsagePriority -gt $topScore) { $topScore = [int]$row.UsagePriority; $topBand = $row.PriorityBand }
    }
    [pscustomobject]@{
        ClusterSize    = $agentNumbers.Count
        CandidatePairs = $pairCount[$root]
        TopPriority    = $topBand
        TopUsageScore  = $topScore
        TotalSessions  = [long]$sessions
        TotalUsers     = [long]$users
        Kind           = if ($agentNumbers.Count -gt $largeClusterThreshold) { 'SharedPlatformGrouping' } else { 'ConsolidationCluster' }
        Agents         = (($agentNumbers | Select-Object -First 6 | ForEach-Object { $nameByNumber[$_] }) -join '; ')
        AgentNumbers   = ($agentNumbers -join ',')
    }
}

$clusters = @($clusters | Sort-Object @{ Expression = 'TopUsageScore'; Descending = $true },
                                      @{ Expression = 'TotalSessions'; Descending = $true },
                                      @{ Expression = 'ClusterSize'; Descending = $true })
$clusterPath = Join-Path $OutputDirectory 'agent-consolidation-clusters.csv'
if ($clusters.Count -gt 0) { $clusters | Export-Csv -Path $clusterPath -NoTypeInformation -Encoding utf8 }

$reviewable = @($clusters | Where-Object Kind -eq 'ConsolidationCluster')
$oversized = @($clusters | Where-Object Kind -eq 'SharedPlatformGrouping')

# The actionable head of the queue: can still reach High AND reads like the same agent.
$priorityQueue = @($ranked | Where-Object {
    $_.Pass1Route -eq 'HighCandidate' -and $_.SimilarityBand -in @('NearIdentical', 'Similar')
})

# Strong source overlap with differently-worded descriptions is a real duplicate pattern, so an
# empty lexical head must not leave the reviewer without a starting point. Fall back to the
# High path ordered by similarity, which is still the best available ordering.
$queueIsLexical = $priorityQueue.Count -gt 0
if (-not $queueIsLexical) {
    $priorityQueue = @($ranked | Where-Object Pass1Route -eq 'HighCandidate')
}

Write-Host ''
Write-Host '=== Review plan ===' -ForegroundColor Green
Write-Host ("  Agents analyzed              : {0}" -f $scopedCount) -NoNewline
if ($scopedCount -ne $originalCount) { Write-Host (" (scoped from {0})" -f $originalCount) } else { Write-Host '' }
Write-Host ("  Exhaustive pairs avoided     : {0:N0}" -f $exhaustive)
Write-Host ("  Candidate pairs              : {0:N0}" -f @($candidates).Count)
Write-Host ("  Pairs on the High path       : {0:N0}" -f $highCandidates.Count)
Write-Host ''
Write-Host ("  CONSOLIDATION CLUSTERS       : {0:N0}   <- the actual unit of work" -f $clusters.Count) -ForegroundColor Cyan
Write-Host ("    reviewable clusters        : {0:N0} (<= {1} agents)" -f $reviewable.Count, $largeClusterThreshold)
Write-Host ("    shared-platform groupings  : {0:N0} (> {1} agents; scope further)" -f $oversized.Count, $largeClusterThreshold)
Write-Host ("  Agents with live adoption(P1): {0:N0}" -f $p1.Count)

if ($reviewable.Count -gt 0) {
    Write-Host ''
    Write-Host '  Top clusters by user impact:'
    foreach ($cluster in ($reviewable | Select-Object -First 10)) {
        Write-Host ("    [{0}] {1,2} agents, {2,6:N0} sessions  {3}" -f
                    $cluster.TopPriority, $cluster.ClusterSize, $cluster.TotalSessions,
                    ($cluster.Agents.Substring(0, [math]::Min(70, $cluster.Agents.Length))))
    }
    if ($reviewable.Count -gt 10) {
        Write-Host ("    ... and {0:N0} more in {1}" -f ($reviewable.Count - 10), (Split-Path -Leaf $clusterPath))
    }
}

if ($oversized.Count -gt 0) {
    Write-Host ''
    Write-Warning ("$($oversized.Count) grouping(s) exceed $largeClusterThreshold agents. A component that large is " +
                   'usually "every agent on one connector" rather than one duplicate set. Re-run scoped to that ' +
                   'system, or compare within it by purpose, before treating it as a consolidation candidate.')
}

if ($p1.Count -gt 0) {
    Write-Host ''
    Write-Host '  P1 agents - validate with owners before any change:'
    foreach ($agent in ($p1 | Sort-Object UsagePriority -Descending)) {
        Write-Host ("    {0,3}  {1}" -f $agent.UsagePriority, $agent.DisplayName)
    }
}

if ($priorityQueue.Count -gt 0) {
    # Clusters supersede the pair list once they exist: a long pair queue restates the same work
    # thousands of times over. Only show pairs when the list is small enough to act on directly.
    $showPairs = ($reviewable.Count -eq 0) -or ($priorityQueue.Count -le 25)
    if ($showPairs) {
        Write-Host ''
        Write-Host '  Top of the review queue:'
        foreach ($pair in ($priorityQueue | Select-Object -First 10)) {
            Write-Host ("    {0:N3}  {1} <-> {2}" -f $pair.PurposeSimilarity, $pair.LeftName, $pair.RightName)
        }
        if ($priorityQueue.Count -gt 10) {
            Write-Host ("    ... and {0:N0} more in {1}" -f ($priorityQueue.Count - 10), (Split-Path -Leaf $similarityPath))
        }
    }
    else {
        Write-Host ''
        Write-Host ("  Pair-level ordering for all {0:N0} pairs is in {1}." -f
                    $priorityQueue.Count, (Split-Path -Leaf $similarityPath))
        Write-Host '  Work the clusters above first; the pair list restates the same work many times over.'
    }
}

Write-Host ''
Write-Host '  Files written:'
foreach ($file in @($usagePath, $candidatePath, $similarityPath)) {
    Write-Host ("    {0}" -f $file)
}
if ($clusters.Count -gt 0) { Write-Host ("    {0}" -f $clusterPath) }

Write-Host ''
Write-Host '  Next: work the clusters above using the evidence rules in SKILL.md.' -ForegroundColor Yellow
Write-Host '  Similarity orders the work; it is not evidence and does not set confidence.' -ForegroundColor Yellow

foreach ($note in $scopeNotes) { Write-Warning $note }

return [pscustomobject]@{
    AgentsAnalyzed      = $scopedCount
    ExhaustivePairs     = $exhaustive
    CandidatePairs      = @($candidates).Count
    HighCandidatePairs  = $highCandidates.Count
    Clusters            = $clusters.Count
    ReviewableClusters  = $reviewable.Count
    OversizedGroupings  = $oversized.Count
    PriorityQueue       = $priorityQueue.Count
    P1Agents            = $p1.Count
    UsagePath           = $usagePath
    CandidatePath       = $candidatePath
    SimilarityPath      = $similarityPath
    ClusterPath         = if ($clusters.Count -gt 0) { $clusterPath } else { $null }
}
