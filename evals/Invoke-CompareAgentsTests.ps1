#Requires -Version 7.0

<#
.SYNOPSIS
Regression tests for the Compare-Agents analysis scripts.

.DESCRIPTION
These protect invariants that were each broken at least once during development, where the failure
was silent: the scripts still produced a confident-looking report while quietly dropping real
duplicates. Every test below corresponds to a real defect that was found by validation rather than
by the code failing loudly.

Run after any change to the scoring, blocking, cascade, or filtering logic.

.EXAMPLE
pwsh -File Invoke-CompareAgentsTests.ps1
#>

[CmdletBinding()]
param(
    [Parameter()]
    [string]$FixturePath = (Join-Path $PSScriptRoot 'fixtures\regression-agent-details.json'),

    [Parameter()]
    [string]$ScriptRoot = (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts')
)

$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-That {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Condition,
        [string]$Detail = ''
    )
    if ($Condition) {
        $script:Passed++
        Write-Host ("  PASS  {0}" -f $Name)
    }
    else {
        $script:Failed++
        Write-Host ("  FAIL  {0}{1}" -f $Name, $(if ($Detail) { " -- $Detail" } else { '' })) -ForegroundColor Red
    }
}

if (-not (Test-Path -LiteralPath $FixturePath)) { throw "Fixture not found: $FixturePath" }

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ("compare-agents-tests-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

try {
    $candidatePath = Join-Path $workDir 'candidates.csv'
    $similarityPath = Join-Path $workDir 'similarity.csv'
    $activePath = Join-Path $workDir 'active.json'
    $scopedPath = Join-Path $workDir 'scoped.json'

    Write-Host ''
    Write-Host 'Blocking and Pass 1 cascade' -ForegroundColor Cyan
    & (Join-Path $ScriptRoot 'Get-AgentComparisonCandidates.ps1') `
        -DetailsPath $FixturePath -CsvPath $candidatePath 6>$null | Out-Null

    $pairs = @(Import-Csv -LiteralPath $candidatePath)
    function Get-Route {
        param([int]$Left, [int]$Right)
        $hit = $pairs | Where-Object {
            ([int]$_.LeftNumber -eq $Left -and [int]$_.RightNumber -eq $Right) -or
            ([int]$_.LeftNumber -eq $Right -and [int]$_.RightNumber -eq $Left)
        } | Select-Object -First 1
        if ($null -eq $hit) { return 'ABSENT' }
        return $hit.Pass1Route
    }

    # Exact shared connector must always reach the full-analysis path.
    Assert-That -Name 'Exact shared source routes to HighCandidate' `
        -Condition ((Get-Route 1 2) -eq 'HighCandidate') -Detail (Get-Route 1 2)

    # Regression: AcmeKB1 vs AcmeKB2 are distinct connections to the same system. Treating them as
    # disjoint silently pruned 5 real clusters.
    Assert-That -Name 'Related connector family routes to HighCandidate' `
        -Condition ((Get-Route 1 3) -eq 'HighCandidate') -Detail (Get-Route 1 3)

    # Regression: definition.id is the agent's OWN id. Reading it as a data source made source-free
    # agents look like they had known, non-intersecting sources, so the pair was wrongly pruned.
    Assert-That -Name 'Source-free pair is not pruned (definition.id is not a source)' `
        -Condition ((Get-Route 4 5) -in @('LowDeferred', 'MediumOnly', 'HighCandidate')) `
        -Detail (Get-Route 4 5)

    # Admissible pruning: unrelated sources AND unrelated purpose can never reach Medium.
    Assert-That -Name 'Unrelated source and purpose is pruned or absent' `
        -Condition ((Get-Route 1 6) -in @('Pruned', 'ABSENT')) -Detail (Get-Route 1 6)

    Assert-That -Name 'No candidate pair is self-referential' `
        -Condition (-not ($pairs | Where-Object { $_.LeftNumber -eq $_.RightNumber }))

    Write-Host ''
    Write-Host 'Usage priority scoring' -ForegroundColor Cyan
    $usage = & (Join-Path $ScriptRoot 'Get-AgentUsagePriority.ps1') `
        -DetailsPath $FixturePath -ReferenceDate '2026-08-20' 6>$null
    $byName = @{}
    foreach ($row in $usage) { $byName[$row.DisplayName] = $row }

    # Regression: linear max-normalization let one 50k-session outlier drive every other agent to
    # ~0, mislabelling thousands of used agents as "no recorded usage".
    Assert-That -Name 'Modest real usage is never scored P3' `
        -Condition ($byName['Modest Usage Agent'].PriorityBand -ne 'P3') `
        -Detail ("band=$($byName['Modest Usage Agent'].PriorityBand) score=$($byName['Modest Usage Agent'].UsagePriority)")

    # The decisive scale case: real usage that is NOT recent, so recency cannot mask a volume score
    # crushed by an outlier. This is precisely what collapsed at 10,000 agents.
    Assert-That -Name 'Stale but genuinely used agent is never scored P3' `
        -Condition ($byName['Stale But Used Agent'].PriorityBand -ne 'P3') `
        -Detail ("band=$($byName['Stale But Used Agent'].PriorityBand) score=$($byName['Stale But Used Agent'].UsagePriority)")

    Assert-That -Name 'Heavy usage outlier ranks P1' `
        -Condition ($byName['Heavy Usage Agent'].PriorityBand -eq 'P1') `
        -Detail $byName['Heavy Usage Agent'].PriorityBand

    Assert-That -Name 'Modest agent keeps a meaningful score beside a 50k outlier' `
        -Condition ($byName['Modest Usage Agent'].UsagePriority -ge 10) `
        -Detail "score=$($byName['Modest Usage Agent'].UsagePriority)"

    # P3 must mean strictly zero evidence, never "a small amount of usage".
    Assert-That -Name 'Zero-evidence agent is P3' `
        -Condition ($byName['Zero Evidence Agent'].PriorityBand -eq 'P3') `
        -Detail $byName['Zero Evidence Agent'].PriorityBand

    $p3WithUsage = $usage | Where-Object {
        $_.PriorityBand -eq 'P3' -and ($_.ActiveUsers -gt 0 -or $_.TotalSessions -gt 0 -or $null -ne $_.DaysSinceLastUse)
    }
    Assert-That -Name 'No agent with usage evidence is classified P3' `
        -Condition (-not $p3WithUsage) -Detail ("offenders=" + (($p3WithUsage | ForEach-Object DisplayName) -join ', '))

    Write-Host ''
    Write-Host 'Activity filter safeguards' -ForegroundColor Cyan
    & (Join-Path $ScriptRoot 'Select-ActiveAgents.ps1') `
        -DetailsPath $FixturePath -OutputPath $activePath -ReferenceDate '2026-08-20' 6>$null | Out-Null
    $activeNames = @((Get-Content -LiteralPath $activePath -Raw -Encoding utf8 | ConvertFrom-Json) | ForEach-Object displayName)

    # Regression: a naive dormancy filter deletes agents that simply have not been adopted yet.
    Assert-That -Name 'Newly created agent survives via grace period' `
        -Condition ($activeNames -contains 'Brand New Agent')

    Assert-That -Name 'Recently used agent survives the activity filter' `
        -Condition ($activeNames -contains 'Heavy Usage Agent')

    # Regression: an explicit usage threshold was previously OR-ed with the safety escape hatches,
    # so asking for ">= 5 sessions" returned 80 of 87 agents, nearly all with zero usage.
    $thresholdDir = Join-Path $workDir 'threshold.json'
    & (Join-Path $ScriptRoot 'Select-ActiveAgents.ps1') `
        -DetailsPath $FixturePath -OutputPath $thresholdDir `
        -MinSessions 5 -ActiveWithinDays 30 -ReferenceDate '2026-08-20' 6>$null | Out-Null
    $thresholdNames = @((Get-Content -LiteralPath $thresholdDir -Raw -Encoding utf8 | ConvertFrom-Json) | ForEach-Object displayName)

    Assert-That -Name 'Threshold mode includes an agent that clears the bar' `
        -Condition ($thresholdNames -contains 'Heavy Usage Agent') -Detail ($thresholdNames -join ', ')

    Assert-That -Name 'Threshold mode excludes agents with no telemetry' `
        -Condition ($thresholdNames -notcontains 'Zero Evidence Agent')

    # A brand-new agent with zero sessions does not meet ">= 5 sessions", however recently created.
    Assert-That -Name 'Threshold mode does not let the grace period bypass the bar' `
        -Condition ($thresholdNames -notcontains 'Brand New Agent')

    # Cumulative sessions clear the bar, but the agent falls outside the recency window.
    Assert-That -Name 'Threshold mode applies the recency window as well as the count' `
        -Condition ($thresholdNames -notcontains 'Stale But Used Agent')

    Assert-That -Name 'Threshold mode never returns the whole registry' `
        -Condition ($thresholdNames.Count -lt $activeNames.Count) `
        -Detail "threshold=$($thresholdNames.Count) dormancy=$($activeNames.Count)"

    Write-Host ''
    Write-Host 'Source scoping' -ForegroundColor Cyan
    & (Join-Path $ScriptRoot 'Select-AgentsBySource.ps1') `
        -DetailsPath $FixturePath -Source 'AcmeKB' -OutputPath $scopedPath 6>$null | Out-Null
    $scopedNames = @((Get-Content -LiteralPath $scopedPath -Raw -Encoding utf8 | ConvertFrom-Json) | ForEach-Object displayName)

    # A connector scope must keep the whole family together, or it splits real clusters.
    Assert-That -Name 'Connector scope keeps the whole AcmeKB family' `
        -Condition (('Alpha KB', 'Alpha KB Copy', 'Beta KB' | Where-Object { $scopedNames -notcontains $_ }).Count -eq 0) `
        -Detail ($scopedNames -join ', ')

    Assert-That -Name 'Connector scope excludes an unrelated system' `
        -Condition ($scopedNames -notcontains 'Delta CRM')

    Write-Host ''
    Write-Host 'Purpose similarity pre-scoring' -ForegroundColor Cyan
    & (Join-Path $ScriptRoot 'Get-PurposeSimilarity.ps1') `
        -DetailsPath $FixturePath -CandidatePath $candidatePath -CsvPath $similarityPath 6>$null | Out-Null
    $ranked = @(Import-Csv -LiteralPath $similarityPath)

    function Get-Similarity {
        param([int]$Left, [int]$Right)
        $hit = $ranked | Where-Object {
            ([int]$_.LeftNumber -eq $Left -and [int]$_.RightNumber -eq $Right) -or
            ([int]$_.LeftNumber -eq $Right -and [int]$_.RightNumber -eq $Left)
        } | Select-Object -First 1
        if ($null -eq $hit) { return $null }
        return [double]$hit.PurposeSimilarity
    }

    $identical = Get-Similarity 1 2
    Assert-That -Name 'Identical purpose scores high similarity' `
        -Condition ($null -ne $identical -and $identical -ge 0.75) -Detail "similarity=$identical"

    # The pre-scorer must only ORDER work. It must never drop a pair the cascade kept.
    Assert-That -Name 'Pre-scorer preserves every ranked candidate pair' `
        -Condition ($ranked.Count -eq @($pairs | Where-Object Pass1Route -ne 'Pruned').Count) `
        -Detail "ranked=$($ranked.Count)"

    Write-Host ''
    Write-Host 'Pipeline orchestration' -ForegroundColor Cyan
    $pipelineDir = Join-Path $workDir 'pipeline'
    $summary = & (Join-Path $ScriptRoot 'Invoke-CompareAgentsPipeline.ps1') `
        -DetailsPath $FixturePath -OutputDirectory $pipelineDir -ReferenceDate '2026-08-20' 6>$null

    Assert-That -Name 'Pipeline writes all three analysis artifacts' `
        -Condition ((Test-Path $summary.UsagePath) -and (Test-Path $summary.CandidatePath) -and (Test-Path $summary.SimilarityPath))

    Assert-That -Name 'Pipeline candidate count matches a direct run' `
        -Condition ($summary.CandidatePairs -eq $pairs.Count) `
        -Detail "pipeline=$($summary.CandidatePairs) direct=$($pairs.Count)"

    # At scale the actionable unit is a cluster, not a pair: 5,000 agents produced 92,000 candidate
    # pairs but only 75 connected components. Reporting pairs alone is unusable on a large tenant.
    Assert-That -Name 'Pipeline reports consolidation clusters' `
        -Condition ($summary.Clusters -ge 1) -Detail "clusters=$($summary.Clusters)"

    Assert-That -Name 'Clusters never outnumber the pairs they summarize' `
        -Condition ($summary.Clusters -le [math]::Max($summary.HighCandidatePairs, 1)) `
        -Detail "clusters=$($summary.Clusters) pairs=$($summary.HighCandidatePairs)"

    Assert-That -Name 'Cluster file is written when clusters exist' `
        -Condition ((-not $summary.ClusterPath) -or (Test-Path $summary.ClusterPath))

    if ($summary.ClusterPath) {
        $clusterRows = @(Import-Csv -LiteralPath $summary.ClusterPath)
        $agentsInClusters = ($clusterRows | ForEach-Object { ($_.AgentNumbers -split ',').Count } | Measure-Object -Sum).Sum
        Assert-That -Name 'Every clustered agent appears exactly once across clusters' `
            -Condition ($agentsInClusters -eq (($clusterRows | ForEach-Object { $_.AgentNumbers -split ',' } | Sort-Object -Unique).Count)) `
            -Detail "listed=$agentsInClusters"

        Assert-That -Name 'Clusters are ranked with the highest usage impact first' `
            -Condition ($clusterRows.Count -lt 2 -or ([int]$clusterRows[0].TopUsageScore -ge [int]$clusterRows[-1].TopUsageScore)) `
            -Detail "first=$($clusterRows[0].TopUsageScore) last=$($clusterRows[-1].TopUsageScore)"

        # Agent numbers are export-order positions, but the usage CSV is sorted by priority.
        # Indexing usage by its own row position attributed one agent's sessions to a different
        # agent entirely, promoting zero-usage duplicates above genuinely adopted clusters while
        # every ordering check still passed. Verify the arithmetic, not just the sort order.
        $usageById = @{}
        foreach ($row in @(Import-Csv -LiteralPath $summary.UsagePath)) {
            if (-not [string]::IsNullOrWhiteSpace($row.Id)) { $usageById[[string]$row.Id] = $row }
        }
        $idByNumber = @{}
        foreach ($row in @(Import-Csv -LiteralPath $summary.CandidatePath)) {
            $idByNumber[[int]$row.LeftNumber] = [string]$row.LeftId
            $idByNumber[[int]$row.RightNumber] = [string]$row.RightId
        }

        $misattributed = 0
        foreach ($cluster in $clusterRows) {
            $expectedSessions = 0
            $expectedTop = 0
            foreach ($number in ($cluster.AgentNumbers -split ',')) {
                $agentId = $idByNumber[[int]$number]
                if (-not $agentId) { continue }
                $row = $usageById[$agentId]
                if ($null -eq $row) { continue }
                $expectedSessions += [int]$row.TotalSessions
                if ([int]$row.UsagePriority -gt $expectedTop) { $expectedTop = [int]$row.UsagePriority }
            }
            if ([int]$cluster.TotalSessions -ne $expectedSessions -or [int]$cluster.TopUsageScore -ne $expectedTop) {
                $misattributed++
            }
        }

        Assert-That -Name 'Cluster usage totals match the usage of their own member agents' `
            -Condition ($misattributed -eq 0) `
            -Detail "clusters with borrowed usage=$misattributed of $($clusterRows.Count)"
    }

    # Regression: source-matched duplicates whose wording differs produced an empty "start here"
    # list, leaving the reviewer with pairs to analyse but no starting point. Scope to a connector
    # whose only members are worded differently, so the lexical head is genuinely empty.
    $boltDir = Join-Path $workDir 'pipeline-bolt'
    $boltSummary = & (Join-Path $ScriptRoot 'Invoke-CompareAgentsPipeline.ps1') `
        -DetailsPath $FixturePath -OutputDirectory $boltDir -Source 'BoltDB' -ReferenceDate '2026-08-20' 6>$null

    Assert-That -Name 'Shared-source pair is High even when wording differs' `
        -Condition ($boltSummary.HighCandidatePairs -ge 1) `
        -Detail "high=$($boltSummary.HighCandidatePairs)"

    Assert-That -Name 'Review queue is never empty when High pairs exist' `
        -Condition (($boltSummary.HighCandidatePairs -eq 0) -or ($boltSummary.PriorityQueue -gt 0)) `
        -Detail "high=$($boltSummary.HighCandidatePairs) queue=$($boltSummary.PriorityQueue)"
    Write-Host ''
    Write-Host 'Lifecycle dormancy policy' -ForegroundColor Cyan
    $lifecycleCsv = Join-Path $workDir 'lifecycle.csv'
    $lifecycle = & (Join-Path $ScriptRoot 'Invoke-AgentLifecyclePolicy.ps1') `
        -DetailsPath $FixturePath -ReferenceDate '2026-08-20' `
        -BlockAfterDays 90 -CsvPath $lifecycleCsv 3>$null 6>$null
    $byAgent = @{}
    foreach ($row in $lifecycle) { $byAgent[$row.DisplayName] = $row }

    # 100 days idle with real prior usage: the one agent the policy should act on.
    Assert-That -Name 'Long-dormant agent is staged for Block' `
        -Condition ($byAgent['Stale But Used Agent'].Action -eq 'Block') `
        -Detail "stage=$($byAgent['Stale But Used Agent'].Stage) action=$($byAgent['Stale But Used Agent'].Action)"

    Assert-That -Name 'Recently used agent is not blocked' `
        -Condition ($byAgent['Heavy Usage Agent'].Action -ne 'Block') `
        -Detail $byAgent['Heavy Usage Agent'].Stage

    # Missing telemetry is not proof of dormancy; blocking on it would hit agents that are simply
    # not reporting.
    Assert-That -Name 'Agent with no telemetry is never blocked' `
        -Condition ($byAgent['Zero Evidence Agent'].Action -ne 'Block' -and $byAgent['Zero Evidence Agent'].Stage -eq 'NoTelemetry') `
        -Detail $byAgent['Zero Evidence Agent'].Stage

    Assert-That -Name 'Newly created agent is protected by the grace period' `
        -Condition ($byAgent['Brand New Agent'].Stage -eq 'NewAgent' -and $byAgent['Brand New Agent'].Action -ne 'Block') `
        -Detail $byAgent['Brand New Agent'].Stage

    Assert-That -Name 'Dry run applies nothing' `
        -Condition (-not (@($lifecycle | Where-Object { $_.Applied -eq $true }).Count)) `
        -Detail ("applied=" + @($lifecycle | Where-Object { $_.Applied -eq $true }).Count)

    Assert-That -Name 'Lifecycle decision file is written' -Condition (Test-Path $lifecycleCsv)

    # A stricter threshold must widen the block set, never narrow it.
    $strict = & (Join-Path $ScriptRoot 'Invoke-AgentLifecyclePolicy.ps1') `
        -DetailsPath $FixturePath -ReferenceDate '2026-08-20' `
        -BlockAfterDays 30 -CsvPath (Join-Path $workDir 'lifecycle-30.csv') 3>$null 6>$null
    Assert-That -Name 'Lowering the threshold does not shrink the block set' `
        -Condition (@($strict | Where-Object Action -eq 'Block').Count -ge @($lifecycle | Where-Object Action -eq 'Block').Count) `
        -Detail ("30d=" + @($strict | Where-Object Action -eq 'Block').Count + " 90d=" + @($lifecycle | Where-Object Action -eq 'Block').Count)
    # ---------------------------------------------------------------- DELETION REVIEW
    # The Graph schema has no blocked-on date, so elapsed block time is measured by this script's
    # own ledger. The invariants below are the ones that decide whether an agent gets deleted.
    Write-Host ''
    Write-Host 'Deletion review (block-duration ledger):'

    $reviewScript = Join-Path $ScriptRoot 'Invoke-AgentDeletionReview.ps1'
    $ledgerPath = Join-Path $workDir 'block-ledger.csv'

    function New-BlockFixture {
        param([string]$Dir, [string]$ExportedAtUtc, [object[]]$Agents)
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $Agents | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $Dir 'agent-builder-details.json') -Encoding utf8
        @{ exportedAtUtc = $ExportedAtUtc } | ConvertTo-Json |
            Set-Content (Join-Path $Dir 'export-metadata.json') -Encoding utf8
        return (Join-Path $Dir 'agent-builder-details.json')
    }

    function New-BlockAgent {
        param([string]$Id, [string]$Name, [bool]$Blocked, [string]$LastUsed = '')
        [pscustomobject]@{
            id = $Id; displayName = $Name; ownerId = "$Id@contoso.com"; appId = "app-$Id"
            isBlocked = $Blocked; lastUsedDateTime = $LastUsed; totalSessions = 3; activeUsers = 1
            createdDateTime = '2025-01-01T00:00:00Z'
        }
    }

    # T0: A and B blocked, C free.
    $t0 = New-BlockFixture -Dir (Join-Path $workDir 'blk-t0') -ExportedAtUtc '2026-01-01T00:00:00Z' -Agents @(
        (New-BlockAgent -Id 'A' -Name 'Long Blocked Agent' -Blocked $true),
        (New-BlockAgent -Id 'B' -Name 'Will Be Unblocked' -Blocked $true),
        (New-BlockAgent -Id 'C' -Name 'Blocked Later' -Blocked $false))
    $run1 = @(& $reviewScript -DetailsPath $t0 -LedgerPath $ledgerPath `
        -CsvPath (Join-Path $workDir 'work1.csv') -ReferenceDate '2026-01-01' 3>$null 6>$null)

    # History that was never recorded cannot be invented, so a first sighting must not be actionable.
    Assert-That -Name 'First sighting of a blocked agent is never immediately eligible' `
        -Condition (@($run1 | Where-Object Status -eq 'EligibleForDeletion').Count -eq 0) `
        -Detail ("eligible=" + @($run1 | Where-Object Status -eq 'EligibleForDeletion').Count)

    # T0+31: A still blocked, B released, C newly blocked.
    $t1 = New-BlockFixture -Dir (Join-Path $workDir 'blk-t1') -ExportedAtUtc '2026-02-01T00:00:00Z' -Agents @(
        (New-BlockAgent -Id 'A' -Name 'Long Blocked Agent' -Blocked $true),
        (New-BlockAgent -Id 'B' -Name 'Will Be Unblocked' -Blocked $false),
        (New-BlockAgent -Id 'C' -Name 'Blocked Later' -Blocked $true))
    $run2 = @(& $reviewScript -DetailsPath $t1 -LedgerPath $ledgerPath `
        -CsvPath (Join-Path $workDir 'work2.csv') -ReferenceDate '2026-02-01' 3>$null 6>$null)
    $a2 = $run2 | Where-Object Id -eq 'A'

    Assert-That -Name 'Agent blocked past the threshold becomes eligible' `
        -Condition ($a2.Status -eq 'EligibleForDeletion' -and $a2.DaysBlocked -ge 30) `
        -Detail "status=$($a2.Status) days=$($a2.DaysBlocked)"

    Assert-That -Name 'Unblocked agent drops off the worklist' `
        -Condition (@($run2 | Where-Object Id -eq 'B').Count -eq 0) `
        -Detail 'B is no longer blocked and must not be evaluated'

    # T0+70: B is blocked again. Its ORIGINAL clock is 70 days old; the new one is not.
    $t2 = New-BlockFixture -Dir (Join-Path $workDir 'blk-t2') -ExportedAtUtc '2026-03-12T00:00:00Z' -Agents @(
        (New-BlockAgent -Id 'A' -Name 'Long Blocked Agent' -Blocked $true -LastUsed '2026-02-15T00:00:00Z'),
        (New-BlockAgent -Id 'B' -Name 'Will Be Unblocked' -Blocked $true),
        (New-BlockAgent -Id 'C' -Name 'Blocked Later' -Blocked $true))
    $run3 = @(& $reviewScript -DetailsPath $t2 -LedgerPath $ledgerPath `
        -CsvPath (Join-Path $workDir 'work3.csv') -ReferenceDate '2026-03-12' 3>$null 6>$null)
    $b3 = $run3 | Where-Object Id -eq 'B'
    $a3 = $run3 | Where-Object Id -eq 'A'

    # The dangerous case: inheriting a stale clock would delete an agent someone just re-blocked.
    Assert-That -Name 'Re-blocking an agent RESETS its deletion clock' `
        -Condition ($b3.DaysBlocked -eq 0 -and $b3.Status -ne 'EligibleForDeletion') `
        -Detail "status=$($b3.Status) days=$($b3.DaysBlocked)"

    # Usage after a block means the block is not doing what the record claims.
    Assert-That -Name 'Agent used after its block is held back for investigation' `
        -Condition ($a3.Status -eq 'UsedSinceBlock') `
        -Detail "status=$($a3.Status)"

    Assert-That -Name 'Block ledger persists across runs' `
        -Condition ((Test-Path $ledgerPath) -and (@(Import-Csv $ledgerPath).Count -ge 3)) `
        -Detail ("rows=" + @(Import-Csv $ledgerPath).Count)

    # An exact timestamp from a live block beats a first-observation lower bound.
    $decisionCsv = Join-Path $workDir 'seed-decisions.csv'
    @([pscustomobject]@{
        Id = 'D'; DisplayName = 'Policy Blocked Agent'; OwnerId = 'd@contoso.com'
        Action = 'Block'; Applied = 'True'; BlockedDateTimeUtc = '2026-01-05T00:00:00Z'
    }) | Export-Csv -Path $decisionCsv -NoTypeInformation -Encoding utf8

    $t3 = New-BlockFixture -Dir (Join-Path $workDir 'blk-t3') -ExportedAtUtc '2026-03-12T00:00:00Z' -Agents @(
        (New-BlockAgent -Id 'D' -Name 'Policy Blocked Agent' -Blocked $true))
    $run4 = @(& $reviewScript -DetailsPath $t3 -LedgerPath (Join-Path $workDir 'ledger-seed.csv') `
        -DecisionsPath $decisionCsv -CsvPath (Join-Path $workDir 'work4.csv') `
        -ReferenceDate '2026-03-12' 3>$null 6>$null)
    $d4 = $run4 | Where-Object Id -eq 'D'

    Assert-That -Name 'Exact block date from a policy run seeds the ledger' `
        -Condition ($d4.Precision -eq 'Exact' -and $d4.Status -eq 'EligibleForDeletion' -and $d4.DaysBlocked -ge 60) `
        -Detail "precision=$($d4.Precision) status=$($d4.Status) days=$($d4.DaysBlocked)"

    # A higher threshold must never widen the deletion set.
    $strictDelete = @(& $reviewScript -DetailsPath $t2 -LedgerPath (Join-Path $workDir 'ledger-strict.csv') `
        -CsvPath (Join-Path $workDir 'work5.csv') -DeleteAfterBlockedDays 3650 `
        -ReferenceDate '2026-03-12' 3>$null 6>$null)
    Assert-That -Name 'Raising the threshold never widens the deletion set' `
        -Condition (@($strictDelete | Where-Object Status -eq 'EligibleForDeletion').Count -eq 0) `
        -Detail ("eligible=" + @($strictDelete | Where-Object Status -eq 'EligibleForDeletion').Count)
    # An audit trail can date a block retroactively, which is the only way to act on agents blocked
    # before this tooling existed. Replaying it wrongly is dangerous, so both directions are tested.
    $historyPath = Join-Path $workDir 'block-history.csv'
    @(
        [pscustomobject]@{ Id = 'E'; Operation = 'BlockedAgent'; DateUtc = '2026-01-05T00:00:00Z' }
        [pscustomobject]@{ Id = 'F'; Operation = 'BlockedAgent'; DateUtc = '2026-01-05T00:00:00Z' }
        [pscustomobject]@{ Id = 'F'; Operation = 'UnblockedAgent'; DateUtc = '2026-02-01T00:00:00Z' }
        [pscustomobject]@{ Id = 'F'; Operation = 'BlockedAgent'; DateUtc = '2026-03-10T00:00:00Z' }
        [pscustomobject]@{ Id = 'G'; Operation = 'BlockedAgent'; DateUtc = '2026-01-05T00:00:00Z' }
        [pscustomobject]@{ Id = 'G'; Operation = 'UnblockedAgent'; DateUtc = '2026-02-01T00:00:00Z' }
    ) | Export-Csv -Path $historyPath -NoTypeInformation -Encoding utf8

    $t4 = New-BlockFixture -Dir (Join-Path $workDir 'blk-t4') -ExportedAtUtc '2026-03-12T00:00:00Z' -Agents @(
        (New-BlockAgent -Id 'E' -Name 'Old Block No Unblock' -Blocked $true),
        (New-BlockAgent -Id 'F' -Name 'Re-blocked Recently' -Blocked $true),
        (New-BlockAgent -Id 'G' -Name 'Blocked Outside Window' -Blocked $true))
    $run6 = @(& $reviewScript -DetailsPath $t4 -LedgerPath (Join-Path $workDir 'ledger-audit.csv') `
        -BlockHistoryPath $historyPath -CsvPath (Join-Path $workDir 'work6.csv') `
        -ReferenceDate '2026-03-12' 3>$null 6>$null)
    $e6 = $run6 | Where-Object Id -eq 'E'
    $f6 = $run6 | Where-Object Id -eq 'F'
    $g6 = $run6 | Where-Object Id -eq 'G'

    Assert-That -Name 'Audit history dates an old block retroactively' `
        -Condition ($e6.Precision -eq 'Audit' -and $e6.Status -eq 'EligibleForDeletion' -and $e6.DaysBlocked -eq 66) `
        -Detail "precision=$($e6.Precision) status=$($e6.Status) days=$($e6.DaysBlocked)"

    # Replaying to the FIRST block instead of the current one would delete a just-re-blocked agent.
    Assert-That -Name 'Audit replay uses the current block, not the first ever' `
        -Condition ($f6.DaysBlocked -eq 2 -and $f6.Status -ne 'EligibleForDeletion') `
        -Detail "days=$($f6.DaysBlocked) start=$($f6.BlockStartUtc)"

    # Trailing unblock means the current block happened after the window; inventing a date would be wrong.
    Assert-That -Name 'Audit ending on an unblock seeds nothing' `
        -Condition ($g6.Precision -eq 'FirstObserved' -and $g6.DaysBlocked -eq 0) `
        -Detail "precision=$($g6.Precision) days=$($g6.DaysBlocked)"

    # The audit importer must ignore unrelated agent-management operations.
    $rawAudit = Join-Path $workDir 'raw-audit.csv'
    @(
        [pscustomobject]@{ CreationDate = '2026-01-05T00:00:00Z'; Operations = 'BlockedAgent'; AuditData = '{"AgentId":"E"}' }
        [pscustomobject]@{ CreationDate = '2026-03-10T00:00:00Z'; Operations = 'BlockedAgent'; AuditData = '{"PackageId":"F"}' }
        [pscustomobject]@{ CreationDate = '2026-02-02T00:00:00Z'; Operations = 'DeployedAgent'; AuditData = '{"AgentId":"Z"}' }
    ) | Export-Csv -Path $rawAudit -NoTypeInformation -Encoding utf8

    $convertedPath = Join-Path $workDir 'converted-history.csv'
    $converted = @(& (Join-Path $ScriptRoot 'Get-AgentBlockHistory.ps1') `
        -FromUnifiedAuditLogCsv $rawAudit -OutputPath $convertedPath 3>$null 6>$null)

    Assert-That -Name 'Audit importer keeps only block/unblock events' `
        -Condition ($converted.Count -eq 2 -and $converted.Id -notcontains 'Z') `
        -Detail ("count=" + $converted.Count + " ids=" + ($converted.Id -join ','))
}
finally {
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("Passed: {0}  Failed: {1}" -f $script:Passed, $script:Failed)
if ($script:Failed -gt 0) { exit 1 }
Write-Host 'All regression tests passed.' -ForegroundColor Green
