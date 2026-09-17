#Requires -Version 7.0

<#
.SYNOPSIS
Pre-scores candidate pairs by lexical purpose similarity so expensive semantic review is ordered.

.DESCRIPTION
Blocking and Pass 1 source triage are cheap and already automated, but Pass 2 (purpose comparison)
was left entirely to the reviewing agent. On a 10,000-agent tenant that is roughly 9,000 pairs of
full-text reading, which is the real bottleneck once O(n^2) pairing is solved.

This script does NOT decide anything. It computes a deterministic TF-IDF cosine similarity over
each agent's purpose text and uses it only to ORDER the queue and flag obvious cases, so the
expensive model adjudicates the most likely duplicates first and can stop early with a known
remaining tail.

Deliberate limits, to stay consistent with the skill's evidence rules:

  * It never emits a confidence score and never decides consolidation. Lexical overlap is not
    evidence of shared purpose; two agents can describe the same job in different words, and two
    unrelated agents can share a template.
  * Generic template wording is down-weighted by inverse document frequency, because the skill
    forbids scoring on phrases like "Get answers quickly, grounded in your knowledge".
  * A LOW similarity never removes a pair. It only sends it to the back of the queue, so the
    cascade stays lossless.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    # Candidate pair CSV produced by Get-AgentComparisonCandidates.ps1.
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CandidatePath,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$CsvPath,

    # Only pre-score these routes. Pruned pairs are already out of scope.
    [Parameter()]
    [string[]]$Route = @('HighCandidate', 'MediumOnly', 'LowDeferred')
)

$ErrorActionPreference = 'Stop'

foreach ($path in @($DetailsPath, $CandidatePath)) {
    if (-not (Test-Path -LiteralPath $path)) { throw "File not found: $path" }
}

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
$candidates = @(Import-Csv -LiteralPath $CandidatePath | Where-Object { $_.Pass1Route -in $Route })

if ($candidates.Count -eq 0) {
    Write-Warning "No candidate pairs matched route(s): $($Route -join ', ')"
    return @()
}

$boilerplate = [regex]'(?i)built using (microsoft )?(365 )?copilot( studio| agent builder)?'
$stopWords = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]('the','and','for','from','with','that','this','you','your','are','can','will','has','have',
               'help','helps','agent','agents','using','use','used','based','information','provide',
               'provides','user','users','data','when','what','which','they','them','their','also','into',
               'about','more','than','then','there','these','those','been','being','other','some','such'))

function Get-PurposeText {
    param($Agent)

    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($value in @($Agent.longDescription, $Agent.shortDescription)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $parts.Add([string]$value) }
    }

    # Instructions carry the real purpose signal; descriptions are often a template.
    foreach ($element in @($Agent.elementDetails)) {
        foreach ($item in @($element.elements)) {
            $definition = $item.definition
            if ($definition -is [string]) {
                try { $definition = $definition | ConvertFrom-Json } catch { $definition = $null }
            }
            if ($null -ne $definition) {
                if ($definition.PSObject.Properties.Name -contains 'instructions') {
                    $instructions = [string]$definition.instructions
                    if (-not [string]::IsNullOrWhiteSpace($instructions)) { $parts.Add($instructions) }
                }
            }
        }
    }
    return ($parts -join ' ')
}

function Get-TermVector {
    param([string]$Text)

    $clean = $boilerplate.Replace([string]$Text, ' ').ToLowerInvariant()
    $counts = @{}
    foreach ($match in [regex]::Matches($clean, '[a-z][a-z0-9]{2,}')) {
        $term = $match.Value
        if ($stopWords.Contains($term)) { continue }
        $counts[$term] = 1 + ($counts[$term] ?? 0)
    }
    return $counts
}

Write-Host "Agents loaded          : $($agents.Count)"
Write-Host "Candidate pairs to rank: $($candidates.Count)"

$vectors = @{}
$documentFrequency = @{}
for ($index = 0; $index -lt $agents.Count; $index++) {
    $number = $index + 1
    $terms = Get-TermVector -Text (Get-PurposeText -Agent $agents[$index])
    $vectors[$number] = $terms
    foreach ($term in $terms.Keys) {
        $documentFrequency[$term] = 1 + ($documentFrequency[$term] ?? 0)
    }
}

# Inverse document frequency suppresses template wording shared across the tenant.
$total = [double]$agents.Count
$idf = @{}
foreach ($term in $documentFrequency.Keys) {
    $idf[$term] = [math]::Log($total / $documentFrequency[$term]) + 1.0
}

$weighted = @{}
$norms = @{}
foreach ($number in $vectors.Keys) {
    $vector = @{}
    $sumSquares = 0.0
    foreach ($entry in $vectors[$number].GetEnumerator()) {
        $weight = (1.0 + [math]::Log($entry.Value)) * $idf[$entry.Key]
        $vector[$entry.Key] = $weight
        $sumSquares += $weight * $weight
    }
    $weighted[$number] = $vector
    $norms[$number] = [math]::Sqrt($sumSquares)
}

function Get-CosineSimilarity {
    param([int]$Left, [int]$Right)

    $a = $weighted[$Left]; $b = $weighted[$Right]
    if ($null -eq $a -or $null -eq $b) { return 0.0 }
    if ($norms[$Left] -le 0 -or $norms[$Right] -le 0) { return 0.0 }

    # Iterate the smaller vector for speed.
    $small = $a; $large = $b
    if ($a.Count -gt $b.Count) { $small = $b; $large = $a }

    $dot = 0.0
    foreach ($entry in $small.GetEnumerator()) {
        $other = $large[$entry.Key]
        if ($null -ne $other) { $dot += $entry.Value * $other }
    }
    return $dot / ($norms[$Left] * $norms[$Right])
}

$results = foreach ($pair in $candidates) {
    $left = [int]$pair.LeftNumber
    $right = [int]$pair.RightNumber
    $similarity = Get-CosineSimilarity -Left $left -Right $right

    # Bands order the queue. They never decide, and never remove a pair.
    $band = if ($similarity -ge 0.75) { 'NearIdentical' }
            elseif ($similarity -ge 0.40) { 'Similar' }
            elseif ($similarity -ge 0.15) { 'Weak' }
            else { 'Distant' }

    [pscustomobject]@{
        Pass1Route       = $pair.Pass1Route
        PurposeSimilarity = [math]::Round($similarity, 4)
        SimilarityBand   = $band
        LeftNumber       = $left
        LeftName         = $pair.LeftName
        RightNumber      = $right
        RightName        = $pair.RightName
        Pass1Reason      = $pair.Pass1Reason
    }
}

$ordered = $results |
    Sort-Object @{ Expression = { if ($_.Pass1Route -eq 'HighCandidate') { 0 } elseif ($_.Pass1Route -eq 'MediumOnly') { 1 } else { 2 } } },
                @{ Expression = 'PurposeSimilarity'; Descending = $true }

Write-Host ''
Write-Host 'Purpose similarity bands (review order, highest value first):'
$ordered | Group-Object SimilarityBand | Sort-Object @{ Expression = {
        switch ($_.Name) { 'NearIdentical' { 0 } 'Similar' { 1 } 'Weak' { 2 } default { 3 } } } } |
    ForEach-Object { Write-Host ("  {0,-14} {1,6}" -f $_.Name, $_.Count) }

$highNear = @($ordered | Where-Object { $_.Pass1Route -eq 'HighCandidate' -and $_.SimilarityBand -in @('NearIdentical','Similar') }).Count
Write-Host ''
Write-Host "HighCandidate pairs with strong lexical overlap: $highNear (review these first)"

Write-Warning ('Advisory only. Lexical similarity is not evidence of shared purpose and never sets ' +
               'confidence: two agents can describe the same job in different words, and unrelated agents ' +
               'can share a template. A low score defers a pair in the queue, it never removes it.')

if ($CsvPath) {
    $ordered | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
    Write-Host "Ranked queue written: $CsvPath"
}

return $ordered
