#Requires -Version 7.0

<#
.SYNOPSIS
Scopes an Agent Builder export to the agents grounded in a given data source or connector.

.DESCRIPTION
Scoping by connector is the most defensible way to break a large registry into reviewable pieces,
because data-source overlap is worth 45 of the 100 confidence points and is the dominant evidence
for a duplicate. Agents grounded in the same system are exactly the agents that can reach a High
recommendation.

This differs sharply from filtering by usage:

  * An activity filter can remove the very duplicates you are hunting, because a cloned agent
    that nobody adopted is both a duplicate and unused.
  * A connector scope keeps every agent that shares the selected grounding, so duplicate pairs
    within that system stay intact.

Two limits apply and must be stated in any scoped report:

  1. It does NOT reduce download cost. Connector identity lives in elementDetails, which is
     returned only by the per-package detail call, never by the list call. There is no
     server-side $filter for a data source. Scope reduces analysis effort, not Graph requests.

  2. Cross-system overlap is out of scope by construction. Two agents answering the same
     questions from different systems, or a pair matched only on shared capability grounding plus
     an identical purpose, will not be compared. Run an unscoped pass, or scope each system in
     turn, to cover those.

.EXAMPLE
Select-AgentsBySource.ps1 -DetailsPath .\agent-builder-details.json -Source ServiceNow

.EXAMPLE
Select-AgentsBySource.ps1 -DetailsPath .\details.json -Source 'GitLab','AzureDevOps' -OutputPath .\devops.json
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DetailsPath,

    # Matched case-insensitively against connector names, URLs, and SharePoint site names.
    # Wildcards are supported, e.g. '*sharepoint.com/sites/TeamsPhone*'.
    [Parameter(Mandatory, ParameterSetName = 'Filter')]
    [ValidateNotNullOrEmpty()]
    [string[]]$Source,

    # List the data sources present in the export and exit.
    [Parameter(Mandatory, ParameterSetName = 'Inventory')]
    [switch]$ListSources,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    # Source-free agents cannot be matched to a system, so they are excluded from a scoped run
    # by default. Include them when you want the scope to also cover unknown-source agents.
    [Parameter(ParameterSetName = 'Filter')]
    [switch]$IncludeUnknownSources
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DetailsPath)) {
    throw "Agent details file not found: $DetailsPath"
}

$agents = @(Get-Content -LiteralPath $DetailsPath -Raw -Encoding utf8 | ConvertFrom-Json)
if ($agents.Count -eq 0) { throw "No agents were found in '$DetailsPath'." }

# 'definition.id' and friends are the agent's own identifiers, not grounding it reads from.
$identifierPathSuffix = @('definition.id', 'definition.manifestId', 'definition.appId', 'definition.assetId')

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

function Get-AgentSource {
    param($Agent)

    $sink = [System.Collections.Generic.List[object]]::new()
    Get-PathedLeaf -Node $Agent.elementDetails -Sink $sink
    $found = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($leaf in $sink) {
        $value = [string]$leaf.Value
        foreach ($match in [regex]::Matches($value, 'https?://[^\s"'']+')) {
            [void]$found.Add($match.Value.TrimEnd('/'))
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

# Collapse an instance-specific source into the system it belongs to, so ServiceNowKB1 and
# ServiceNowKB2 are recognised as the same platform.
function Get-SourceSystem {
    param([string]$Source)

    $siteMatch = [regex]::Match($Source, '(?i)^https?://[^/]+/sites/([^/]+)')
    if ($siteMatch.Success) { return "SharePoint:$($siteMatch.Groups[1].Value)" }

    if ($Source -match '^(?i)https?://') {
        # $host is a reserved automatic variable in PowerShell.
        $hostName = [regex]::Replace($Source, '(?i)^https?://(www\.)?', '').Split('/')[0]
        return "Web:$hostName"
    }

    if ($Source -match '^[0-9a-fA-F\-]{36}$') { return 'UnresolvedGuidSource' }

    $trimmed = [regex]::Replace($Source, '\d+$', '')
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $Source }
    return $trimmed
}

$profiles = foreach ($agent in $agents) {
    $sources = Get-AgentSource -Agent $agent
    $systems = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($item in $sources) { [void]$systems.Add((Get-SourceSystem -Source $item)) }
    [pscustomobject]@{
        Agent       = $agent
        Id          = $agent.id
        DisplayName = $agent.displayName
        Sources     = $sources
        Systems     = $systems
    }
}

if ($ListSources) {
    Write-Host "Data sources present in $($agents.Count) agent(s):"
    Write-Host ''
    $rows = $profiles |
        ForEach-Object { $p = $_; $p.Systems | ForEach-Object { [pscustomobject]@{ System = $_; Agent = $p.DisplayName } } } |
        Group-Object System |
        Sort-Object Count -Descending
    foreach ($row in $rows) {
        Write-Host ("  {0,-40} {1,4} agent(s)" -f $row.Name, $row.Count)
    }
    $noSource = @($profiles | Where-Object { $_.Sources.Count -eq 0 }).Count
    Write-Host ''
    Write-Host "  $noSource agent(s) expose no data source at all."
    return $rows
}

function Test-SourceMatch {
    param($Profile, [string[]]$Patterns)

    foreach ($pattern in $Patterns) {
        $wild = if ($pattern -match '[\*\?]') { $pattern } else { "*$pattern*" }
        foreach ($item in $Profile.Sources) { if ($item -like $wild) { return $true } }
        foreach ($system in $Profile.Systems) { if ($system -like $wild) { return $true } }
    }
    return $false
}

$matched = [System.Collections.Generic.List[object]]::new()
$unknownKept = 0

foreach ($profile in $profiles) {
    if (Test-SourceMatch -Profile $profile -Patterns $Source) {
        $matched.Add($profile)
        continue
    }
    if ($IncludeUnknownSources -and $profile.Sources.Count -eq 0) {
        $matched.Add($profile)
        $unknownKept++
    }
}

$kept = $matched.Count
$before = [long]$agents.Count * ($agents.Count - 1) / 2
$after = [long]$kept * ($kept - 1) / 2

Write-Host "Source filter           : $($Source -join ', ')"
Write-Host "Agents in export        : $($agents.Count)"
Write-Host "Agents in scope         : $kept"
if ($unknownKept -gt 0) {
    Write-Host "  (includes $unknownKept agent(s) with no declared source)"
}
Write-Host "Exhaustive pairs before : $before"
Write-Host "Exhaustive pairs after  : $after"
if ($after -gt 0) {
    Write-Host ("Comparison work reduced : {0:N1}x" -f ($before / [double]$after))
}

if ($kept -gt 0) {
    Write-Host ''
    Write-Host 'Systems represented in scope:'
    $matched |
        ForEach-Object { $_.Systems } |
        Group-Object |
        Sort-Object Count -Descending |
        ForEach-Object { Write-Host ("  {0,-40} {1,4}" -f $_.Name, $_.Count) }
}

if ($kept -lt 2) {
    Write-Warning 'Fewer than two agents match, so no comparison is possible. Broaden the pattern or use -ListSources.'
}

# A scope can split a real cluster when related grounding lives under different names, most often
# with SharePoint: one topic can be spread across several sites. Detect that instead of leaving the
# user to discover it from a missing finding.
$inScopeIds = [System.Collections.Generic.HashSet[string]]::new([string[]]@($matched | ForEach-Object { [string]$_.Id }))
$inScopeTokens = [System.Collections.Generic.HashSet[string]]::new()
foreach ($profile in $matched) {
    foreach ($system in $profile.Systems) {
        foreach ($token in ([regex]::Matches($system, '[A-Z]+(?![a-z])|[A-Z][a-z]{3,}|[a-z]{4,}') | ForEach-Object { $_.Value.ToLowerInvariant() })) {
            if ($token.Length -ge 5 -and $token -notin @('sharepoint','unresolvedguidsource','source')) {
                [void]$inScopeTokens.Add($token)
            }
        }
    }
}

$nearMisses = foreach ($profile in $profiles) {
    if ($inScopeIds.Contains([string]$profile.Id)) { continue }
    foreach ($system in $profile.Systems) {
        $hit = $false
        foreach ($token in $inScopeTokens) {
            if ($system -like "*$token*") { $hit = $true; break }
        }
        if ($hit) {
            [pscustomobject]@{ DisplayName = $profile.DisplayName; System = $system }
            break
        }
    }
}

if ($nearMisses) {
    Write-Warning ("$(@($nearMisses).Count) agent(s) outside the scope are grounded in a related system name. " +
                   'A cluster may be split across scopes; consider a broader pattern.')
    $nearMisses | Select-Object -First 10 | Format-Table DisplayName, System -AutoSize | Out-String | Write-Host
}

Write-Warning ('Scope limitation: overlap between an in-scope agent and an out-of-scope agent is not evaluated. ' +
               'Pairs that share only capability-level grounding (for example WebSearch) plus an identical ' +
               'purpose can still be High confidence, and those are not necessarily captured by a single ' +
               'system scope. Run each system in turn, or run unscoped, for full coverage.')

if ($OutputPath) {
    $matched.Agent | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Scoped details written  : $OutputPath"
}

return $matched | Select-Object Id, DisplayName, @{ N = 'Systems'; E = { ($_.Systems | Sort-Object) -join '; ' } }
