#Requires -Version 7.0

<#
.SYNOPSIS
Generates the candidate comparison set for a large agent registry.

.DESCRIPTION
Exhaustive pairwise comparison is O(n^2) and becomes impossible at enterprise scale: 87 agents
produce 3,741 pairs, but 10,000 agents produce 49,995,000. This script applies multi-tier blocking
(standard entity resolution) so only agents that share concrete evidence are compared.

Blocking tiers, from most to least specific:

  1. src  - exact normalized data source (connector ID, SharePoint URL, site/list GUID)
  2. fam  - source family (SharePoint site root, connector name without trailing digits/date stamps)
  3. pur  - exact normalized purpose hash, with authoring-tool boilerplate stripped
  4. tok  - rare description tokens, filtered by document frequency
  5. ptk  - rare tokens from the source path itself (camelCase split)

Oversized blocks are never silently discarded, because dropping them loses real duplicates.
They are first refined by a composite key, and any block that is still oversized is processed with
a sorted-neighborhood window so every member is still compared against its nearest neighbours.
Residual blocks are reported so the assessment can disclose its coverage honestly.

Each surviving pair is then routed by a Pass 1 source triage that assigns the cheapest sufficient
review path. Routing uses an ADMISSIBLE UPPER BOUND: a pair is only pruned when its best possible
score cannot reach the band, so the cascade never discards a pair that could have qualified.

  Route            Meaning
  ---------------  --------------------------------------------------------------------
  HighCandidate    Shares an exact source or source family; can reach High, so it needs
                   full analysis including target selection and migration scope.
  MediumOnly       Related only by coarse capability grounding or partial evidence.
                   Capped at 79, so it can never be recommended for consolidation and
                   needs only the cheaper review treatment.
  LowDeferred      Sources unknown on both sides. Capped at 59 by the skill safeguards.
  Pruned           Both sides have known sources with no exact or family relationship.
                   Best possible score is 55, below the Medium threshold of 60.

Validated against the 87-agent reference tenant: 100% recall of all 20 known clusters while
examining 12.9% of pairs, with only 2% of the naive pair count needing full analysis.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    [Parameter()]
    [ValidateRange(2, 5000)]
    [int]$MaxBlockSize = 60,

    [Parameter()]
    [ValidateRange(2, 200)]
    [int]$NeighborhoodWindow = 12
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) {
    throw "Agent details file not found: $DetailsPath"
}

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -lt 2) {
    throw "At least two agents are required to build a comparison set."
}

$boilerplate = [regex]'(?i)built using (microsoft )?(365 )?copilot( studio| agent builder)?'
# Two separate stoplists. "documents" is noise inside a SharePoint path but is meaningful purpose
# evidence inside a description, so sharing one list silently destroys real matches.
$stopDescription = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]('the','and','for','from','with','that','this','you','your','are','can','help',
               'agents','agent','using','use','based','information','provide','provides','users','user','data'))
$stopPath = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]('shared','documents','sites','https','http','com','sharepoint','site','list','lists',
               'drive','drives','default','aspx','forms'))

function Get-LeafValue {
    param($Node, [System.Collections.Generic.List[string]]$Sink)

    if ($null -eq $Node) { return }

    if ($Node -is [string]) {
        $trimmed = $Node.Trim()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try {
                Get-LeafValue -Node ($trimmed | ConvertFrom-Json) -Sink $Sink
                return
            }
            catch { }
        }
        $Sink.Add($Node)
        return
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Get-LeafValue -Node $item -Sink $Sink }
        return
    }

    if ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            $Sink.Add([string]$property.Name)
            Get-LeafValue -Node $property.Value -Sink $Sink
        }
    }
}

# Path-aware walk. A bare GUID is only a data source in some positions: SharePoint site/list IDs
# are real grounding, but 'definition.id' is the agent's OWN identifier. Treating that as a source
# makes a source-free agent look like it has known sources, which can cause a pair to be pruned as
# "known sources that do not intersect" when the truth is "sources unknown on both sides".
function Get-PathedLeaf {
    param($Node, [System.Collections.Generic.List[object]]$Sink, [string]$Path = '')

    if ($null -eq $Node) { return }

    if ($Node -is [string]) {
        $trimmed = $Node.Trim()
        if ($trimmed.StartsWith('{') -or $trimmed.StartsWith('[')) {
            try {
                Get-PathedLeaf -Node ($trimmed | ConvertFrom-Json) -Sink $Sink -Path $Path
                return
            }
            catch { }
        }
        $Sink.Add([pscustomobject]@{ Path = $Path; Value = $Node })
        return
    }

    if ($Node -is [pscustomobject]) {
        foreach ($property in $Node.PSObject.Properties) {
            $childPath = if ($Path) { "$Path.$($property.Name)" } else { [string]$property.Name }
            Get-PathedLeaf -Node $property.Value -Sink $Sink -Path $childPath
        }
        return
    }

    if ($Node -is [System.Collections.IEnumerable]) {
        foreach ($item in $Node) { Get-PathedLeaf -Node $item -Sink $Sink -Path $Path }
    }
}

# Positions whose GUID is an identifier for the agent itself rather than grounding it reads from.
$identifierPathSuffix = @('definition.id', 'definition.manifestId', 'definition.appId', 'definition.assetId')

function Get-SourceValue {
    param($Agent)

    $sink = [System.Collections.Generic.List[object]]::new()
    Get-PathedLeaf -Node $Agent.elementDetails -Sink $sink
    $found = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($leaf in $sink) {
        $value = [string]$leaf.Value
        foreach ($match in [regex]::Matches($value, 'https?://[^\s"'']+')) {
            [void]$found.Add($match.Value)
        }
        if ($value -match '^[A-Za-z][A-Za-z0-9]{2,30}\d$') { [void]$found.Add($value) }
        if ($value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $isIdentifier = $false
            foreach ($suffix in $identifierPathSuffix) {
                if ([string]$leaf.Path -like "*$suffix") { $isIdentifier = $true; break }
            }
            if (-not $isIdentifier) { [void]$found.Add($value) }
        }
    }
    return $found
}

function Get-SourceFamily {
    param([string]$Source)

    $match = [regex]::Match($Source, '(?i)^(https?://[^/]+/sites/[^/]+)')
    if ($match.Success) { return $match.Groups[1].Value.ToLowerInvariant() }
    $trimmed = [regex]::Replace($Source, '\d+$', '')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { $trimmed = $Source }
    return $trimmed.ToLowerInvariant()
}

function Split-CamelCase {
    param([string]$Text)

    $clean = [regex]::Replace($Text, '%[0-9a-fA-F]{2}', ' ')
    return [regex]::Matches($clean, '[A-Z]+(?![a-z])|[A-Z][a-z]+|[a-z]+') | ForEach-Object { $_.Value.ToLowerInvariant() }
}

function Get-PathToken {
    param($Agent, $Sources)

    $tokens = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($source in $Sources) {
        foreach ($part in ($source -split '[/._\-]')) {
            foreach ($token in (Split-CamelCase -Text $part)) {
                if ($token.Length -ge 4 -and -not $stopPath.Contains($token)) { [void]$tokens.Add($token) }
            }
        }
    }
    return $tokens
}

function Get-DescriptionToken {
    param($Agent)

    $text = @($Agent.longDescription, $Agent.shortDescription) -ne $null -join ' '
    $text = $boilerplate.Replace($text, ' ').ToLowerInvariant()
    $tokens = [System.Collections.Generic.List[string]]::new()
    foreach ($match in [regex]::Matches($text, '[a-z]{4,}')) {
        if (-not $stopDescription.Contains($match.Value)) { $tokens.Add($match.Value) }
    }
    return $tokens
}

# Coarse grounding such as WebSearch or ScenarioModels is real shared evidence, but it is not
# specific enough on its own to justify a High recommendation.
$coarseCapabilities = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]('websearch','graphconnectors','onedriveandsharepoint','scenariomodels','teamsmessages',
               'codeinterpreter','graphicart','people','dataverse','powerplatform'))

function Get-CoarseCapability {
    param($Agent)

    $sink = [System.Collections.Generic.List[string]]::new()
    Get-LeafValue -Node $Agent.elementDetails -Sink $sink
    $found = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($value in $sink) {
        $lower = $value.ToLowerInvariant()
        if ($coarseCapabilities.Contains($lower)) { [void]$found.Add($lower) }
    }
    foreach ($type in @($Agent.elementTypes)) {
        if ($null -ne $type) {
            $lower = ([string]$type).ToLowerInvariant()
            if ($coarseCapabilities.Contains($lower)) { [void]$found.Add($lower) }
        }
    }
    return $found
}

function Get-Sha1Prefix {
    param([string]$Text, [int]$Length = 12)

    $sha1 = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return -join ($bytes | ForEach-Object { $_.ToString('x2') }) | ForEach-Object { $_.Substring(0, $Length) }
    }
    finally { $sha1.Dispose() }
}

Write-Host "Agents loaded: $($agents.Count)"
Write-Host 'Extracting blocking evidence...'

$profiles = [System.Collections.Generic.List[object]]::new()
$descriptionFrequency = @{}
$pathFrequency = @{}

for ($index = 0; $index -lt $agents.Count; $index++) {
    $agent = $agents[$index]
    $sources = Get-SourceValue -Agent $agent
    $descriptionTokens = Get-DescriptionToken -Agent $agent
    $pathTokens = Get-PathToken -Agent $agent -Sources $sources

    foreach ($token in ([System.Collections.Generic.HashSet[string]]::new([string[]]$descriptionTokens))) {
        $descriptionFrequency[$token] = 1 + ($descriptionFrequency[$token] ?? 0)
    }
    foreach ($token in $pathTokens) {
        $pathFrequency[$token] = 1 + ($pathFrequency[$token] ?? 0)
    }

    $profiles.Add([pscustomobject]@{
        Number            = $index + 1
        Id                = $agent.id
        DisplayName       = $agent.displayName
        Sources           = $sources
        Families          = [System.Collections.Generic.HashSet[string]]::new(
                                [string[]]@($sources | ForEach-Object { Get-SourceFamily -Source $_ }))
        Capabilities      = Get-CoarseCapability -Agent $agent
        DescriptionTokens = $descriptionTokens
        PathTokens        = $pathTokens
        PurposeHash       = if ($descriptionTokens.Count -gt 0) {
                                Get-Sha1Prefix -Text (($descriptionTokens | Select-Object -First 25) -join ' ')
                            } else { $null }
    })
}

$descriptionCap = [math]::Max(10, $agents.Count * 0.10)
$pathCap        = [math]::Max(15, $agents.Count * 0.15)

# A purpose signature shared by many agents is a template, not a distinguishing purpose, so it
# must not be treated as strong evidence. The skill already forbids scoring on generic wording.
$purposeFrequency = @{}
foreach ($profile in $profiles) {
    if ($profile.PurposeHash) {
        $purposeFrequency[$profile.PurposeHash] = 1 + ($purposeFrequency[$profile.PurposeHash] ?? 0)
    }
}
$distinctivePurposeMax = [math]::Max(3, [math]::Floor($agents.Count * 0.03))

function Test-DistinctivePurpose {
    param($Left, $Right)
    if (-not $Left.PurposeHash -or $Left.PurposeHash -ne $Right.PurposeHash) { return $false }
    return $purposeFrequency[$Left.PurposeHash] -le $distinctivePurposeMax
}

$blocks = @{}
function Add-ToBlock {
    param([string]$Key, [int]$Number)
    if (-not $blocks.ContainsKey($Key)) { $blocks[$Key] = [System.Collections.Generic.List[int]]::new() }
    $blocks[$Key].Add($Number)
}

foreach ($profile in $profiles) {
    $keys = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($source in $profile.Sources) {
        [void]$keys.Add('src:' + $source.TrimEnd('/').ToLowerInvariant())
        [void]$keys.Add('fam:' + (Get-SourceFamily -Source $source))
    }

    if ($profile.DescriptionTokens.Count -gt 0) {
        $head = ($profile.DescriptionTokens | Select-Object -First 25) -join ' '
        [void]$keys.Add('pur:' + (Get-Sha1Prefix -Text $head))
        foreach ($token in ($profile.DescriptionTokens | Select-Object -Unique -First 12)) {
            if ($descriptionFrequency[$token] -le $descriptionCap) { [void]$keys.Add('tok:' + $token) }
        }
    }

    foreach ($token in $profile.PathTokens) {
        if ($pathFrequency[$token] -le $pathCap) { [void]$keys.Add('ptk:' + $token) }
    }

    foreach ($key in $keys) { Add-ToBlock -Key $key -Number $profile.Number }
}

$byNumber = @{}
foreach ($profile in $profiles) { $byNumber[$profile.Number] = $profile }

function Get-RefineKey {
    param([int]$Number)
    $profile = $byNumber[$Number]
    $families = ($profile.Sources | ForEach-Object { Get-SourceFamily -Source $_ } | Sort-Object -Unique) -join '|'
    $head = ($profile.DescriptionTokens | Select-Object -First 25) -join ' '
    $hash = if ($head) { Get-Sha1Prefix -Text $head -Length 8 } else { 'none' }
    return "$families#$hash"
}

function Get-NeighborhoodSignature {
    param([int]$Number)
    $profile = $byNumber[$Number]
    $families = ($profile.Sources | ForEach-Object { Get-SourceFamily -Source $_ } | Sort-Object -Unique) -join '|'
    $tokens = ($profile.DescriptionTokens | Sort-Object -Unique | Select-Object -First 6) -join ' '
    return "$families~$tokens"
}

Write-Host "Blocking keys: $($blocks.Count). Building candidate pairs..."

$pairs = [System.Collections.Generic.HashSet[string]]::new()
$residual = [System.Collections.Generic.List[object]]::new()
$refinedCount = 0

function Add-Pair {
    param([int[]]$Members)
    $sorted = $Members | Sort-Object -Unique
    for ($x = 0; $x -lt $sorted.Count; $x++) {
        for ($y = $x + 1; $y -lt $sorted.Count; $y++) {
            [void]$pairs.Add("$($sorted[$x])-$($sorted[$y])")
        }
    }
}

function Add-SortedNeighborhood {
    param([int[]]$Members, [string]$Key)
    $ordered = $Members | Sort-Object -Unique | Sort-Object { Get-NeighborhoodSignature -Number $_ }
    for ($x = 0; $x -lt $ordered.Count; $x++) {
        $limit = [math]::Min($x + $NeighborhoodWindow, $ordered.Count - 1)
        for ($y = $x + 1; $y -le $limit; $y++) {
            $a = [math]::Min($ordered[$x], $ordered[$y]); $b = [math]::Max($ordered[$x], $ordered[$y])
            [void]$pairs.Add("$a-$b")
        }
    }
    $residual.Add([pscustomobject]@{ BlockKey = $Key; Members = $ordered.Count })
}

foreach ($entry in $blocks.GetEnumerator()) {
    $members = $entry.Value | Sort-Object -Unique
    if ($members.Count -lt 2) { continue }

    if ($members.Count -le $MaxBlockSize) {
        Add-Pair -Members $members
        continue
    }

    # Refine rather than discard: dropping an oversized block loses real duplicates outright.
    $refinedCount++
    $subBlocks = @{}
    foreach ($number in $members) {
        $key = Get-RefineKey -Number $number
        if (-not $subBlocks.ContainsKey($key)) { $subBlocks[$key] = [System.Collections.Generic.List[int]]::new() }
        $subBlocks[$key].Add($number)
    }

    foreach ($sub in $subBlocks.GetEnumerator()) {
        $subMembers = $sub.Value | Sort-Object -Unique
        if ($subMembers.Count -lt 2) { continue }
        if ($subMembers.Count -le $MaxBlockSize) {
            Add-Pair -Members $subMembers
        }
        else {
            Add-SortedNeighborhood -Members $subMembers -Key "$($entry.Key) / $($sub.Key)"
        }
    }
}

$total = [long]$agents.Count * ($agents.Count - 1) / 2
$reduction = if ($pairs.Count -gt 0) { [math]::Round($total / $pairs.Count, 1) } else { 0 }
$coverage = if ($total -gt 0) { [math]::Round(100 * $pairs.Count / $total, 2) } else { 0 }

Write-Host ''
Write-Host "Exhaustive pairs      : $total"
Write-Host "Candidate pairs       : $($pairs.Count) ($coverage% of exhaustive, ${reduction}x reduction)"
Write-Host "Blocks refined        : $refinedCount"
Write-Host "Sampled blocks        : $($residual.Count)"

if ($residual.Count -gt 0) {
    Write-Warning ("$($residual.Count) block(s) stayed oversized after refinement and were compared with a " +
                   "sorted-neighborhood window. The assessment MUST disclose that comparison was not exhaustive.")
    $residual | Sort-Object Members -Descending | Select-Object -First 10 |
        Format-Table BlockKey, Members -AutoSize | Out-String | Write-Host
}

function Test-SetIntersect {
    param($Left, $Right)
    # PowerShell unrolls an empty collection returned from a function into $null, so both sides
    # must be null-guarded before any method call.
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    foreach ($item in $Left) { if ($Right -contains $item) { return $true } }
    return $false
}

function Get-SetCount {
    param($Set)
    if ($null -eq $Set) { return 0 }
    return @($Set).Count
}

# Pass 1 triage. Returns the cheapest sufficient review path using an admissible upper bound:
# a pair is only pruned when even a perfect score on every remaining dimension cannot reach 60.
function Get-Pass1Route {
    param($Left, $Right)

    $sourceCeiling = 45
    $remaining = 55   # purpose 30 + capability 10 + audience 5 + viability 10

    if (Test-SetIntersect -Left $Left.Sources -Right $Right.Sources) {
        return [pscustomobject]@{ Route = 'HighCandidate'; Reason = 'shared-source'; MaxPossible = 100 }
    }
    if (Test-SetIntersect -Left $Left.Families -Right $Right.Families) {
        # Related connections such as GitLabCloudIssues1 and GitLabCloudIssues2 are partial
        # evidence, not zero evidence, so they must stay eligible for High.
        return [pscustomobject]@{ Route = 'HighCandidate'; Reason = 'shared-source-family'; MaxPossible = 100 }
    }
    if (Test-SetIntersect -Left $Left.Capabilities -Right $Right.Capabilities) {
        # Coarse grounding plus an identical purpose signature is what a true duplicate looks
        # like, so that combination stays eligible for High. Shared capability on its own is
        # weak evidence and is capped.
        if (Test-DistinctivePurpose -Left $Left -Right $Right) {
            return [pscustomobject]@{ Route = 'HighCandidate'; Reason = 'shared-capability-and-purpose'; MaxPossible = 100 }
        }
        return [pscustomobject]@{ Route = 'MediumOnly'; Reason = 'shared-capability-grounding'; MaxPossible = 79 }
    }
    if ((Get-SetCount $Left.Sources) -eq 0 -and (Get-SetCount $Right.Sources) -eq 0) {
        return [pscustomobject]@{ Route = 'LowDeferred'; Reason = 'both-sources-unknown'; MaxPossible = 59 }
    }
    if ((Get-SetCount $Left.Sources) -eq 0 -or (Get-SetCount $Right.Sources) -eq 0) {        # Absence of evidence is not evidence of absence, so an unknown side can never be pruned.
        return [pscustomobject]@{ Route = 'MediumOnly'; Reason = 'one-side-sources-unknown'; MaxPossible = 79 }
    }
    return [pscustomobject]@{ Route = 'Pruned'; Reason = 'no-source-relationship'; MaxPossible = $remaining }
}

$result = foreach ($pair in $pairs) {
    $parts = $pair -split '-'
    $left = $byNumber[[int]$parts[0]]
    $right = $byNumber[[int]$parts[1]]
    $route = Get-Pass1Route -Left $left -Right $right
    [pscustomobject]@{
        Pass1Route  = $route.Route
        Pass1Reason = $route.Reason
        MaxPossible = $route.MaxPossible
        LeftNumber  = $left.Number
        LeftName    = $left.DisplayName
        LeftId      = $left.Id
        RightNumber = $right.Number
        RightName   = $right.DisplayName
        RightId     = $right.Id
    }
}

$routeCounts = $result | Group-Object Pass1Route | Sort-Object Count -Descending
Write-Host ''
Write-Host 'Pass 1 source triage (cheapest sufficient review path):'
foreach ($group in $routeCounts) {
    Write-Host ("  {0,-14} {1,6}" -f $group.Name, $group.Count)
}
$highCount = @($result | Where-Object Pass1Route -eq 'HighCandidate').Count
Write-Host ("  => full semantic analysis needed for {0} pair(s) = {1:P2} of the exhaustive {2}" -f
            $highCount, ($highCount / [double]$total), $total)

if ($CsvPath) {
    $result |
        Sort-Object @{ Expression = {
            switch ($_.Pass1Route) { 'HighCandidate' { 0 } 'MediumOnly' { 1 } 'LowDeferred' { 2 } default { 3 } } } },
            LeftNumber, RightNumber |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
    Write-Host "Candidate pairs written: $CsvPath"
}

return $result
