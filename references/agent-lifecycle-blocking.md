# Agent lifecycle blocking

**Status: built.** `scripts/Invoke-AgentLifecyclePolicy.ps1` implements the warn-and-block stages.
`scripts/Invoke-AgentDeletionReview.ps1` implements the delete stage as far as the platform allows:
it decides *which* agents qualify, but the removal itself must be done in the admin center, because
no delete API exists.

## Why it is separate from consolidation

Compare-Agents answers **"are these the same agent?"** — a judgement question requiring evidence
about sources, purpose, capabilities, and ownership.

Lifecycle blocking answers **"is anyone using this agent?"** — a policy question answerable from
telemetry alone, with no comparison required. Finding that 6,000 of 10,000 agents are dormant needs
no pairwise analysis, and running an O(n²) comparison to reach that conclusion would be wasted
effort.

## What the script does

Reuses the export from `Export-AgentBuilderAgents.ps1`, which already carries every field the
decision needs (`lastUsedDateTime`, `createdDateTime`, `isBlocked`, `ownerId`). No second retrieval
is required for classification.

| Days idle | Stage | Action |
|---|---|---|
| 0-29 | Active | none |
| 30 / 60 | Idle | report for owner notification |
| 90+ | Dormant | **block** (reversible) |

```powershell
# Classify only - no Graph connection, no changes
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" -DetailsPath .\agent-builder-details.json

# Block, after a fresh export
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" `
  -DetailsPath .\agent-builder-details.json -TenantId contoso.onmicrosoft.com -LiveMode

# Undo a live run
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" `
  -Rollback .\agent-lifecycle-decisions.csv -TenantId contoso.onmicrosoft.com -LiveMode
```

## API constraints, verified against Microsoft Learn

- **Beta only.** Block and unblock exist at `/beta` only. Microsoft states beta APIs are subject to
  change and are not supported for production use.
- **Different permission.** Block needs delegated `CopilotPackages.ReadWrite.All`. The export only
  requests `CopilotPackages.Read.All`, so a live run needs broader consent and a fresh sign-in.
- **No application permission.** Block is delegated-only, so this **cannot run unattended** as a
  service principal. A human admin must sign in. That is the single biggest barrier to running this
  as a scheduled job today, and it is a strong argument for the capability living in the admin
  center rather than in a script.
- **No delete operation.** The Package Management API exposes only list, get, update, block,
  unblock and reassign. A "delete after a further 30 days" stage cannot be automated; the script
  reports those agents so an admin can remove them through the admin center.

## The delete stage

`scripts/Invoke-AgentDeletionReview.ps1` answers "which agents have been blocked for 30 days?" and
produces a removal worklist. Two facts shape its whole design.

### 1. There is no delete API, but there *is* an admin-center delete

Checked across the adjacent surfaces, not just the obvious one:

| Candidate | Verdict |
|---|---|
| `DELETE /copilot/admin/catalog/packages/{id}` | **Does not exist.** The operation list is list, get, update, block, unblock, reassign. |
| `DELETE /appCatalogs/teamsApps/{id}` | **Does not apply.** Requires `distributionMethod == organization`. A user-created Agent Builder agent is a Copilot catalog item, not a tenant-catalog upload. Its documented Teams path is sideloading a ZIP. Also delegated-only. |
| `DELETE /agentRegistry/agentInstances/{id}` | **Different object.** Entra Agent Registry instances ("AI teammates"), not declarative agents. Being replaced by Agent 365 APIs from May 2026. |
| `DELETE /beta/copilot/agentRegistrations/{id}` | **Different object.** Deletes only agents created through `POST /copilot/agentRegistrations` by a developer. |
| `Remove-MgAppCatalogTeamApp` | 1:1 wrapper of the teamsApps delete; same `distributionMethod` constraint. |
| Any PowerShell cmdlet | **None exists** for Copilot package management. |

The supported path is the UI, and it is explicitly documented for this agent type:
**Microsoft 365 admin center → Agents → All agents →** filter Platform =
*Agent Builder in Microsoft Copilot* → **⁝ → Delete**.

Deleting removes the agent, **all associated files, and the underlying SharePoint Embedded
container.** It is irreversible and can take up to 24 hours to reach every user. Owners can also
delete their own agents from the Copilot app.

There is **no documented auto-purge of blocked agents.** A blocked agent persists indefinitely, so
without a delete stage the registry accumulates blocked clutter forever.

### 2. The tenant does not record *when* an agent was blocked

`isBlocked` is a bare boolean. There is no `blockedDateTime`, no `blockedBy`. So "blocked for 30
days" cannot be queried — it has to be reconstructed. The script uses three sources, in precedence
order:

| Precision | Source | Notes |
|---|---|---|
| `Audit` | `BlockedAgent` / `UnblockedAgent` in the unified audit log | Best. Recovers dates retroactively, and sees blocks made by other admins. |
| `Exact` | `BlockedDateTimeUtc` from a live `Invoke-AgentLifecyclePolicy.ps1` run | Precise, but only for blocks this toolkit applied. |
| `FirstObserved` | First run in which the ledger saw the agent blocked | A lower bound, never an invention. Conservative by design. |

The audit route matters most: without it the first run can only start every clock at today, so a
tenant would wait out the full threshold before anything became actionable — even for agents blocked
a year ago. `scripts/Get-AgentBlockHistory.ps1` retrieves those events, either through the Graph
audit query API (`AuditLogsQuery.Read.All`) or by importing a `Search-UnifiedAuditLog` export.

Its limit is **audit retention** (typically 180 days). An agent blocked before that window has no
recoverable date and falls back to `FirstObserved`.

### Safety rules in the deletion review

- **An unblock resets the clock.** An agent blocked, released, and blocked again starts from zero.
  Inheriting the original date would delete an agent someone had just deliberately re-blocked.
- **Usage after a block is an anomaly, not a green light.** Those agents are held as
  `UsedSinceBlock` for investigation rather than proposed for deletion.
- **A first sighting is never actionable.** Reported as `ClockStartedNow` so the reason the list is
  empty is visible rather than mysterious.
- Nothing is ever deleted by the script. It cannot be, and it should not be.

```powershell
# Recover block dates from the audit log (once, then periodically)
pwsh -File ".\scripts\Get-AgentBlockHistory.ps1" -TenantId contoso.onmicrosoft.com `
  -OutputPath .\agent-block-history.csv

# Report agents blocked 30+ days
pwsh -File ".\scripts\Invoke-AgentDeletionReview.ps1" `
  -DetailsPath .\agent-builder-details.json `
  -BlockHistoryPath .\agent-block-history.csv `
  -DecisionsPath .\agent-lifecycle-decisions.csv
```

## Safety behaviour built into the script

- Dry run is the default; `-LiveMode` is required and prompts for confirmation.
- **Stale exports are refused.** Dormancy computed from old data can block an agent used since the
  export. Default limit is 24 hours, overridable with `-AllowStaleExport`.
- **Missing telemetry is never treated as dormancy.** Absence of evidence is not evidence of
  absence, and telemetry can lag or reset after a republish. Those agents are reported as
  `NoTelemetry` for manual review.
- **New agents are protected** by a creation grace period; they have no usage because nobody has
  had the chance to adopt them.
- Every run writes a decision CSV, and `-Rollback` reverses a live run from it.

## How the two capabilities compose

- **Lifecycle** retires the dormant tail. Compare-Agents does not need to analyze those agents.
- **Compare-Agents** finds overlap among the agents that remain in service - the harder problem,
  and the one lifecycle cannot solve.
- Once lifecycle runs regularly, `-ExcludeBlocked` on the exporter becomes a genuine saving,
  because `isBlocked` **is** on the list response.

Measured on a production-shaped 10,000-agent registry, running lifecycle first shrinks the
comparison surface but not the review workload:

| Policy | Agents left | Pairs to compare | Clusters |
|---|---:|---:|---:|
| No rule | 10,000 | 140,920 | 109 |
| 90-day retire | 8,975 | 124,179 | 108 |
| 30-day retire | 7,033 | 97,235 | 106 |

Duplicates concentrate among agents people actually use, so retiring dormant agents removes agents
without removing many clusters. The two rules are complementary, not redundant.

## Open questions before operationalizing

- **Does the tenant's telemetry populate reliably?** On the reference tenant, 78 of 87 agents had
  no `lastUsedDateTime` at all. A dormancy policy there would classify 90% of the registry as
  `NoTelemetry` - firing on missing data rather than proven disuse. Verify this before trusting a
  block threshold.
- What is the appeal path when an owner disputes a block?
- Should blocking be scoped per business unit, so owners see only their own agents?
- Does `exceptionRate` (also undocumented) belong in the policy as a health signal?
