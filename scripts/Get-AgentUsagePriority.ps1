#Requires -Version 7.0

<#
.SYNOPSIS
Ranks Agent Builder agents by adoption using the usage telemetry in an export.

.DESCRIPTION
Reads agent-builder-details.json and scores each agent from 0-100 using activeUsers,
totalSessions, lastUsedDateTime recency, and totalRunTimeInHours. Scores are normalized against
the highest value observed in the same tenant, so the result is a relative priority ranking for
IT-pro review rather than an absolute measure of value.

Usage priority never changes consolidation confidence. Confidence answers "are these the same
agent?"; usage priority answers "which consolidation should an administrator handle first, and how
much user migration risk does it carry?".
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
    [datetime]$ReferenceDate = (Get-Date)
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) {
    throw "Agent details file not found: $DetailsPath"
}

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -eq 0) {
    throw "No agents were found in '$DetailsPath'."
}

function Get-Numeric {
    param($Value)
    if ($null -eq $Value) { return 0 }
    $parsed = 0.0
    if ([double]::TryParse([string]$Value, [ref]$parsed)) { return $parsed }
    return 0
}

# Recency keeps a dormant agent from ranking alongside a live one even when totals match.
function Get-RecencyFactor {
    param([nullable[int]]$Days)
    if ($null -eq $Days) { return 0.0 }
    if ($Days -le 30) { return 1.0 }
    if ($Days -le 90) { return 0.6 }
    if ($Days -le 180) { return 0.3 }
    return 0.0
}

$records = foreach ($agent in $agents) {
    $lastUsed = $agent.lastUsedDateTime
    $days = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$lastUsed)) {
        $days = [int]([math]::Floor(($ReferenceDate.ToUniversalTime() - ([datetime]$lastUsed).ToUniversalTime()).TotalDays))
    }

    [pscustomobject]@{
        Id                  = $agent.id
        DisplayName         = $agent.displayName
        ActiveUsers         = Get-Numeric $agent.activeUsers
        TotalSessions       = Get-Numeric $agent.totalSessions
        TotalRunTimeInHours = Get-Numeric $agent.totalRunTimeInHours
        LastUsedDateTime    = $lastUsed
        DaysSinceLastUse    = $days
        UsagePriority       = 0
        PriorityBand        = 'P3'
    }
}

# Guard only against division by zero. Clamping to 1 would flatten fractional runtime hours.
function Get-Denominator {
    param([double]$Maximum)
    if ($Maximum -le 0) { return 1 }
    return $Maximum
}

# Log compression is required at scale. With linear max-normalization a single outlier
# (for example 500,000 sessions in a 10,000-agent tenant) drives every other agent's score to
# roughly zero, so genuinely used agents get reported as unused. log1p keeps the heavy tail
# ranked without collapsing the middle of the distribution.
function Get-Scaled {
    param([double]$Value, [double]$Maximum)
    if ($Maximum -le 0) { return 0 }
    return [math]::Log(1 + $Value) / [math]::Log(1 + $Maximum)
}

$maxUsers    = Get-Denominator ($records | Measure-Object -Property ActiveUsers -Maximum).Maximum
$maxSessions = Get-Denominator ($records | Measure-Object -Property TotalSessions -Maximum).Maximum
$maxRuntime  = Get-Denominator ($records | Measure-Object -Property TotalRunTimeInHours -Maximum).Maximum

foreach ($record in $records) {
    $hasEvidence = ($record.ActiveUsers -gt 0) -or ($record.TotalSessions -gt 0) -or
                   ($record.TotalRunTimeInHours -gt 0) -or ($null -ne $record.DaysSinceLastUse)

    if (-not $hasEvidence) {
        # P3 must mean "no recorded usage at all", never "small amount of usage".
        $record.UsagePriority = 0
        $record.PriorityBand = 'P3'
        continue
    }

    $score = (35 * (Get-Scaled $record.ActiveUsers $maxUsers)) +
             (30 * (Get-Scaled $record.TotalSessions $maxSessions)) +
             (25 * (Get-RecencyFactor $record.DaysSinceLastUse)) +
             (10 * (Get-Scaled $record.TotalRunTimeInHours $maxRuntime))

    # Any agent with usage evidence is at least P2 so it is never reported as unused.
    $record.UsagePriority = [math]::Max([int][math]::Round($score), 10)
    $record.PriorityBand = if ($record.UsagePriority -ge 60) { 'P1' } else { 'P2' }
}

$ranked = $records | Sort-Object -Property UsagePriority, ActiveUsers, TotalSessions -Descending

Write-Host "Agents evaluated: $($records.Count)"
Write-Host "P1 (act first): $(@($records | Where-Object PriorityBand -eq 'P1').Count)"
Write-Host "P2 (validate): $(@($records | Where-Object PriorityBand -eq 'P2').Count)"
Write-Host "P3 (low risk): $(@($records | Where-Object PriorityBand -eq 'P3').Count)"

if ($CsvPath) {
    $ranked | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding utf8
    Write-Host "Usage priority written: $CsvPath"
}

return $ranked
