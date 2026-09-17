#Requires -Version 7.0

<#
.SYNOPSIS
Recovers when agents were blocked and unblocked, from the unified audit log.

.DESCRIPTION
The Graph package schema has no blocked-on date - isBlocked is a bare boolean - so the elapsed block
time needed for a deletion decision cannot be read from the agent itself. The unified audit log is
the one place it survives. Microsoft 365 admin center agent management writes these operations:

    BlockedAgent      an admin blocked an agent
    UnblockedAgent    an admin unblocked a previously blocked agent
    DeletedAgent      an admin deleted a shared agent

This script pulls the block and unblock events and writes them as a flat CSV that
Invoke-AgentDeletionReview.ps1 consumes through -BlockHistoryPath.

WHY THIS MATTERS: without it, the deletion clock can only start the first time this tooling sees an
agent blocked, so a tenant has to wait out the full threshold before anything is actionable, even
for agents blocked a year ago. With it, existing blocks are dated retroactively.

THE LIMIT THAT REMAINS: audit retention. Typically 180 days, plan dependent. An agent blocked before
the retention window has no recoverable date, and this script will simply not return an event for
it. Those agents fall back to first-observation dating, which is a lower bound - correct, just
conservative. It never invents a date.

PERMISSIONS: delegated AuditLogsQuery.Read.All. This is a different scope again from the export
(CopilotPackages.Read.All) and the block policy (CopilotPackages.ReadWrite.All).

STATUS: the audit query flow follows the documented Graph contract but has not been executed against
a live tenant from this toolkit. Run it once interactively and check the record count before wiring
it into anything scheduled. -RawPath dumps the untouched records so the shape can be inspected.

ALTERNATIVE, if the Graph audit query is unavailable: Exchange Online PowerShell produces the same
events, and -FromUnifiedAuditLogCsv imports the result.

    Connect-ExchangeOnline
    Search-UnifiedAuditLog -StartDate (Get-Date).AddDays(-180) -EndDate (Get-Date) `
        -Operations BlockedAgent,UnblockedAgent -ResultSize 5000 |
        Export-Csv .\raw-audit.csv -NoTypeInformation

.EXAMPLE
Get-AgentBlockHistory.ps1 -TenantId contoso.onmicrosoft.com -OutputPath .\agent-block-history.csv

.EXAMPLE
# Convert an existing Search-UnifiedAuditLog export instead of querying Graph
Get-AgentBlockHistory.ps1 -FromUnifiedAuditLogCsv .\raw-audit.csv -OutputPath .\agent-block-history.csv
#>

[CmdletBinding(DefaultParameterSetName = 'Query')]
param(
    [Parameter(ParameterSetName = 'Query')]
    [string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'Import')]
    [ValidateNotNullOrEmpty()]
    [string]$FromUnifiedAuditLogCsv,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = '.\agent-block-history.csv',

    [Parameter(ParameterSetName = 'Query')]
    [ValidateRange(1, 3650)]
    [int]$LookbackDays = 180,

    [Parameter(ParameterSetName = 'Query')]
    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 20,

    [Parameter()]
    [string]$RawPath,

    [Parameter(ParameterSetName = 'Query')]
    [switch]$UseDeviceAuthentication
)

$ErrorActionPreference = 'Stop'
$graphRoot = 'https://graph.microsoft.com/beta'

# The audit payload nests the agent identifier, and the property name is not contractually fixed
# across record versions. Probe the documented candidates rather than assuming one.
function Resolve-AgentId {
    param($AuditData)
    if ($null -eq $AuditData) { return $null }

    $candidates = @('AgentId', 'agentId', 'PackageId', 'packageId', 'AppId', 'appId',
                    'ObjectId', 'objectId', 'Id', 'id', 'TargetId', 'targetId')
    foreach ($name in $candidates) {
        $value = $null
        if ($AuditData -is [hashtable] -or $AuditData -is [System.Collections.IDictionary]) {
            if ($AuditData.Contains($name)) { $value = $AuditData[$name] }
        }
        elseif ($AuditData.PSObject.Properties.Name -contains $name) {
            $value = $AuditData.$name
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return [string]$value }
    }
    return $null
}

function ConvertFrom-AuditRecords {
    param([object[]]$Records)

    $rows = foreach ($record in $Records) {
        $operation = $record.operation
        if (-not $operation) { $operation = $record.Operations }
        if ($operation -notin @('BlockedAgent', 'UnblockedAgent')) { continue }

        $when = $record.createdDateTime
        if (-not $when) { $when = $record.CreationDate }
        if (-not $when) { $when = $record.CreationTime }
        if (-not $when) { continue }

        $data = $record.auditData
        if (-not $data) { $data = $record.AuditData }
        if ($data -is [string]) {
            try { $data = $data | ConvertFrom-Json } catch { $data = $null }
        }

        $agentId = Resolve-AgentId -AuditData $data
        if (-not $agentId) { continue }

        [pscustomobject]@{
            Id        = $agentId
            Operation = $operation
            DateUtc   = ([datetime]$when).ToUniversalTime().ToString('o')
        }
    }
    return @($rows)
}

# ------------------------------------------------------------------ IMPORT PATH
if ($PSCmdlet.ParameterSetName -eq 'Import') {
    if (-not (Test-Path -LiteralPath $FromUnifiedAuditLogCsv)) {
        throw "Audit CSV not found: $FromUnifiedAuditLogCsv"
    }
    $raw = @(Import-Csv -LiteralPath $FromUnifiedAuditLogCsv)
    Write-Host "Rows in source CSV: $($raw.Count)"

    $converted = ConvertFrom-AuditRecords -Records $raw
    if ($converted.Count -eq 0) {
        Write-Warning ('No BlockedAgent/UnblockedAgent rows carried a resolvable agent id. Check that the export ' +
                       'includes the AuditData column, and inspect it to find the identifier property.')
    }
    $converted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Host "Block history written: $OutputPath ($($converted.Count) event(s))"
    return $converted
}

# ------------------------------------------------------------------ QUERY PATH
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    throw 'Microsoft.Graph.Authentication is required. Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
}
Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

$connectArgs = @{ Scopes = @('AuditLogsQuery.Read.All'); NoWelcome = $true }
if ($TenantId) { $connectArgs.TenantId = $TenantId }
if ($UseDeviceAuthentication) { $connectArgs.UseDeviceAuthentication = $true }

Write-Host 'Connecting to Microsoft Graph (AuditLogsQuery.Read.All)...'
Connect-MgGraph @connectArgs | Out-Null

try {
    $context = Get-MgContext
    if (-not $context) { throw 'Graph connection failed.' }
    if ($context.Scopes -notcontains 'AuditLogsQuery.Read.All') {
        throw ("The token lacks AuditLogsQuery.Read.All. Granted: $($context.Scopes -join ', '). " +
               'An administrator must consent to this scope.')
    }
    Write-Host "Connected to $($context.TenantId) as $($context.Account)"

    $start = (Get-Date).ToUniversalTime().AddDays(-$LookbackDays)
    $end = (Get-Date).ToUniversalTime()

    $body = @{
        '@odata.type'        = '#microsoft.graph.security.auditLogQuery'
        displayName          = "Agent block history $(Get-Date -Format 'yyyyMMdd-HHmmss')"
        filterStartDateTime  = $start.ToString('o')
        filterEndDateTime    = $end.ToString('o')
        operationFilters     = @('BlockedAgent', 'UnblockedAgent')
    } | ConvertTo-Json -Depth 5

    Write-Host "Submitting audit query over the last $LookbackDays day(s)..."
    $query = Invoke-MgGraphRequest -Method POST -Uri "$graphRoot/security/auditLog/queries" `
        -Body $body -ContentType 'application/json'
    $queryId = $query.id
    if (-not $queryId) { throw 'The audit query was accepted but returned no id.' }

    # Audit queries run asynchronously; the job can take many minutes on a large window.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $status = $query.status
    while ($status -notin @('succeeded', 'failed', 'cancelled')) {
        if ((Get-Date) -gt $deadline) {
            throw ("The audit query did not finish within $TimeoutMinutes minute(s). It is still running server " +
                   "side as query id $queryId; re-run with a longer -TimeoutMinutes or a shorter -LookbackDays.")
        }
        Start-Sleep -Seconds 20
        $poll = Invoke-MgGraphRequest -Method GET -Uri "$graphRoot/security/auditLog/queries/$queryId"
        $status = $poll.status
        Write-Host "  status: $status"
    }
    if ($status -ne 'succeeded') { throw "The audit query ended with status '$status'." }

    $records = [System.Collections.Generic.List[object]]::new()
    $uri = "$graphRoot/security/auditLog/queries/$queryId/records?`$top=200"
    while ($uri) {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri
        foreach ($item in @($page.value)) { $records.Add($item) }
        $uri = $page.'@odata.nextLink'
        if ($uri) { Write-Host "  retrieved $($records.Count) record(s)..." }
    }
    Write-Host "Audit records returned: $($records.Count)"

    if ($RawPath) {
        $records | ConvertTo-Json -Depth 12 | Set-Content -Path $RawPath -Encoding utf8
        Write-Host "Raw records written: $RawPath"
    }

    $converted = ConvertFrom-AuditRecords -Records $records.ToArray()
    if ($records.Count -gt 0 -and $converted.Count -eq 0) {
        Write-Warning ('Records were returned but no agent id could be resolved from their auditData. Re-run with ' +
                       '-RawPath to dump the payload and identify the correct property name.')
    }

    $converted | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding utf8
    Write-Host "Block history written: $OutputPath ($($converted.Count) event(s))"

    if ($converted.Count -eq 0) {
        Write-Warning ("No block events found in the last $LookbackDays day(s). Agents blocked before the audit " +
                       'retention window cannot be dated this way; they will fall back to first-observation dating.')
    }
    return $converted
}
finally { if (Get-MgContext) { Disconnect-MgGraph | Out-Null } }
