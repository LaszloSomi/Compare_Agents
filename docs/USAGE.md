# Compare-Agents Usage Guide

Compare-Agents inventories Microsoft 365 Copilot Agent Builder agents in a tenant and identifies
opportunities to consolidate overlapping agents. It compares descriptions, knowledge sources,
actions, audiences, hosts, and governance boundaries, then produces confidence-scored
recommendations.

The skill is **read-only for analysis**. Export, comparison, and reporting never modify anything.

The lifecycle scripts are a separate, opt-in capability that **can** change your tenant:
`Invoke-AgentLifecyclePolicy.ps1` blocks dormant agents when run with `-LiveMode`. Blocking is
reversible; nothing in this toolkit deletes an agent, because no delete API exists. Read
[Limits and caveats](#limits-and-caveats) before a live run.

## Prerequisites

- PowerShell 7 (`pwsh`)
- `Microsoft.Graph.Authentication` PowerShell module
- Microsoft Agent 365 license
- AI admin or Global admin role
- Microsoft commercial cloud tenant

Each stage needs a different delegated scope, and consent is required for each one separately:

| Stage | Script | Delegated scope |
|---|---|---|
| Export and analysis | `Export-AgentBuilderAgents.ps1` | `CopilotPackages.Read.All` |
| Block / unblock | `Invoke-AgentLifecyclePolicy.ps1` | `CopilotPackages.ReadWrite.All` |
| Block-date recovery | `Get-AgentBlockHistory.ps1` | `AuditLogsQuery.Read.All` |

**None of these support application permissions.** Every stage that talks to Graph is
delegated-only, so a human admin must sign in interactively — this cannot run as a scheduled job or
service principal. (`Get-AgentBlockHistory.ps1` is the one partial exception: with
`-FromUnifiedAuditLogCsv` it converts an existing `Search-UnifiedAuditLog` export offline, with no
Graph connection at all.)

The Agent 365 Package Management API does not currently support US Government L4, US Government
L5/DoD, or China operated by 21Vianet.

## How to use it

Ask Copilot to audit, compare, rationalize, deduplicate, or consolidate your Agent Builder agents.
Compare-Agents will:

1. Explain the required read-only Graph connection.
2. Ask for your tenant ID or verified tenant domain.
3. Prompt you to authenticate interactively.
4. Run a dry-run inventory export for review.
5. Download the Agent Builder inventory and detailed package metadata.
6. Compare agents using evidence-weighted scoring.
7. Save raw JSON exports plus Markdown and self-contained HTML consolidation reports.

You can also provide a previous `agent-builder-details.json` export. In that case, the skill skips
authentication and analyzes the supplied file.

### Running the analysis directly

To analyze an existing export without going through chat, use the pipeline runner instead of
chaining the individual scripts:

```powershell
# Full registry
pwsh -File ".\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json"

# One system at a time (preferred for large registries)
pwsh -File ".\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -Source 'ServiceNow' -OutputDirectory ".\snow"
```

It runs scoping, usage ranking, blocking, cascade routing, and queue ordering, then prints a review
plan: how many pairs need full analysis, which agents have live adoption, and where to start. It
makes no Graph calls and does not score confidence — that judgement stays with the reviewer.

| Option | Purpose |
|---|---|
| `-Source` | Scope to one or more data sources (preferred) |
| `-ActiveOnly` | Scope to agents in use (can hide unadopted duplicates) |
| `-MinSessions` / `-MinActiveUsers` | Keep only agents that provably clear a usage bar |
| `-OutputDirectory` | Where analysis CSVs are written |

## Best prompts

### Complete tenant audit

```text
Audit all Microsoft 365 Copilot Agent Builder agents in my tenant. Download the agent registry,
compare their purposes and data sources, and create a Markdown consolidation report with confidence
scores. Recommend only high-confidence consolidations and flag uncertain matches for owner review.
```

### Find duplicate agents

```text
Find duplicate or overlapping Agent Builder agents in our tenant. Pay special attention to agents
that use the same SharePoint sites, connectors, APIs, or knowledge sources. Tell me which agent
should remain and what unique behavior must be preserved.
```

### Conservative governance review

```text
Perform a conservative governance review of our Copilot agent registry. Recommend consolidation
only when both purpose and data-source overlap are supported by concrete evidence. Keep agents
separate when ownership, permissions, audience, regional scope, or actions differ.
```

### Analyze an existing export

```text
Analyze the attached agent-builder-details.json file using Compare-Agents. Create a Markdown report
with an inventory, high-confidence consolidation recommendations, medium-confidence review items,
agents that should remain separate, evidence gaps, and follow-up questions.
```

### Review a specific business area

```text
Compare the HR-related Agent Builder agents in our registry. Identify shared knowledge sources,
overlapping employee questions, regional or security boundaries, and actions that would need to be
preserved. Recommend a final target agent only when confidence is at least 80%.
```

### Create an owner-review agenda

```text
Use our Agent Builder registry export to prepare an owner-review agenda. Group overlapping agents,
show the evidence and confidence score for each group, list unresolved ownership or permission
questions, and propose the validation needed before any agent is retired.
```

## Output files

The default export directory contains:

| File | Purpose |
|---|---|
| `agent-builder-inventory.json` | Agent Builder packages returned by the registry list API |
| `agent-builder-details.json` | Detailed metadata for every package |
| `export-metadata.json` | Tenant context, API version, retrieval time, and counts |
| `agent-usage-priority.csv` | Per-agent usage priority score, band, and raw telemetry |
| `agent-comparison-candidates.csv` | Every candidate pair and its route, including `Pruned` pairs that were not compared |
| `agent-purpose-similarity.csv` | Candidate pairs ranked for semantic review order |
| `agent-lifecycle-decisions.csv` | Dormancy stage and block decision per agent |
| `agent-block-ledger.csv` | Durable record of when each agent's current block began |
| `agent-deletion-worklist.csv` | Blocked agents assessed against the deletion threshold |
| `compare-agents-report.md` | Inventory and confidence-scored consolidation assessment |
| `compare-agents-report.html` | Responsive, self-contained browser version of the complete report |

`Get-AgentBlockHistory.ps1` writes `agent-block-history.csv` to the **current directory** by
default, not the export directory. Pass `-OutputPath` to place it alongside the export.

## Confidence model

Each candidate pair is scored from 0 to 100:

| Dimension | Weight |
|---|---:|
| Data-source overlap | 45 |
| Purpose and description overlap | 30 |
| Capability and action overlap | 10 |
| Audience and host overlap | 5 |
| Consolidation viability | 10 |

- **80-100:** High confidence; consolidation can be recommended.
- **60-79:** Medium confidence; owner review is required.
- **0-59:** Low confidence; retain separately unless more evidence is gathered.

Missing metadata lowers confidence. Similar names, publishers, or generic descriptions alone are
not sufficient evidence.

## Usage priority model

Confidence tells you whether two agents are duplicates. **Usage priority** tells an administrator
which consolidation to handle first and how much user-migration risk it carries. The two scores are
reported separately, and usage never changes confidence.

Each agent is scored from 0 to 100 using the telemetry in the export, normalized against the
highest value in the same tenant:

| Signal | Weight |
|---|---:|
| `activeUsers` | 35 |
| `totalSessions` | 30 |
| `lastUsedDateTime` recency | 25 |
| `totalRunTimeInHours` | 10 |

- **P1 — Act first (60-100):** Live adoption; validate with owners and plan redirects first.
- **P2 — Validate (10-59):** Any agent with usage evidence that is not P1; confirm whether it is an
  abandoned pilot.
- **P3 — No recorded usage (0):** No sessions, users, runtime, or last-used date at all.

Volume signals are log-compressed before normalization. Without this, one very high-volume agent
drives every other score toward zero and genuinely used agents get reported as unused.

Run the ranking directly at any time:

```powershell
pwsh -File ".\scripts\Get-AgentUsagePriority.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -CsvPath ".\Compare-Agents-Export\agent-usage-priority.csv"
```

Low usage is never a reason to retire an agent on its own, and telemetry can lag or reset after a
republish, so owners must confirm a zero value before anything is retired.

## Large registries

Enterprise registries commonly hold **5,000-10,000 agents**, where exhaustive comparison is
impossible: 10,000 agents produce 49,995,000 pairs.

| Registry size | Exhaustive pairs | Feasible exhaustively? |
|---:|---:|---|
| 100 | 4,950 | Yes |
| 500 | 124,750 | Marginal |
| 2,000 | 1,999,000 | No |
| 5,000 | 12,497,500 | No |
| 10,000 | **49,995,000** | No |

The pipeline runner applies the full reduction in one command, and is the recommended entry point:

```powershell
pwsh -File ".\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json"
```

### Measured on production-shaped tenants

Synthetic tenants with a realistic usage distribution (about 90% of agents used, heavy-tailed
volumes, duplicates spread across many systems):

| Agents | Exhaustive pairs | Candidate pairs | **Clusters** | Reviewable | Runtime |
|---:|---:|---:|---:|---:|---:|
| 5,000 | 12,497,500 | 92,016 | **75** | 25 | 1.6 min |
| 10,000 | 49,995,000 | 140,920 | **109** | 44 | 3.0 min |
| 10,000 scoped to `-MinSessions 5` | — | 100,741 | **91** | 30 | 1.5 min |

### Clusters are the unit of work, not pairs

This is the single most important thing to understand at scale. On the 5,000-agent tenant the
cascade produced 92,016 candidate pairs — but those pairs form only **75 connected components**.
An administrator holds roughly 75 consolidation conversations, not 92,000 pair reviews.

The pipeline therefore writes `agent-consolidation-clusters.csv`, ranked by user impact, and
classifies each component:

| Kind | Meaning | Action |
|---|---|---|
| `ConsolidationCluster` | Up to 25 agents sharing grounding and purpose | Review directly |
| `SharedPlatformGrouping` | More than 25 agents in one component | Usually "every agent on one connector" rather than one duplicate set — scope further before treating it as a consolidation candidate |

Each cluster carries its size, pair count, highest usage-priority band, and total sessions and
users, so the queue is ordered by the disruption a consolidation would cause rather than by score
alone.

Do not report raw pair counts as the workload. A five-figure pair count restates the same handful
of conversations thousands of times over and makes a tractable result look impossible.

### Blocking and cascade routing

```powershell
pwsh -File ".\scripts\Get-AgentComparisonCandidates.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -CsvPath ".\Compare-Agents-Export\agent-comparison-candidates.csv"
```

Agents are grouped by exact data source, source family, exact normalized purpose, rare description
tokens, and rare source-path tokens; only agents sharing a key are compared. On the reference
tenant this recovers 100% of known clusters while examining 12.8% of pairs.

The same script then routes each pair through a multi-pass cascade, so expensive semantic work only
runs where it can change the answer:

| `Pass1Route` | Meaning | Treatment |
|---|---|---|
| `HighCandidate` | Shares a source, source family, or grounding plus a distinctive purpose | Full analysis and target selection |
| `MediumOnly` | Coarse or one-sided evidence, capped at 79 | Cheaper review; never recommended |
| `LowDeferred` | Sources unknown on both sides, capped at 59 | Lowest priority |
| `Pruned` | Known sources with no relationship; peaks at 55 | Not compared |

Pruning is **admissible**: a pair is dropped only when its best possible score cannot reach the
band. Because sources are worth 45 and all other dimensions total 55, a pair needs source ≥ 25 to
be capable of reaching High. On the reference tenant this cut 3,741 exhaustive pairs to 81 needing
full semantic analysis (2.2%) with no known cluster lost.

Do not replace this with a hard filter such as "only read descriptions when sources match".
Validation showed that unknown sources are not disjoint sources, that related connections such as
`GitLabCloudIssues1` and `GitLabCloudIssues2` carry partial credit, and that coarse grounding such
as `WebSearch` combined with a distinctive purpose can still support a High recommendation.

Oversized blocks are refined rather than discarded, because dropping them silently loses real
duplicates. Testing showed a fixed size cap loses roughly 22% of real duplicate pairs. Any block
still oversized after refinement is compared with a sorted-neighborhood window and reported, so the
assessment can disclose that its comparison was not exhaustive.

### Ordering the semantic pass

Pass 2 (purpose comparison) has no cheap automation and is the bottleneck at scale — roughly 9,000
pairs of reading on a 10,000-agent tenant. Rank that queue first:

```powershell
pwsh -File ".\scripts\Get-PurposeSimilarity.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -CandidatePath ".\Compare-Agents-Export\agent-comparison-candidates.csv" `
  -CsvPath ".\Compare-Agents-Export\agent-purpose-similarity.csv"
```

Deterministic TF-IDF cosine similarity over instructions and descriptions, with boilerplate
stripped and template wording suppressed. On the reference tenant the top 25 pairs were all real
duplicates, and half the queue captured 100% of them.

It is **advisory only**: it emits no confidence, decides nothing, and a low score defers a pair
rather than removing it.

### Operating a very large tenant

- Export with `-Resume` so an interrupted or throttled run continues instead of restarting. The
  exporter checkpoints every 250 packages and honors Graph `Retry-After` responses.
- Use `-ExcludeBlocked` to skip blocked agents before their detail requests. `isBlocked` is on the
  list response, so this is the one filter that genuinely reduces download cost.
- Scope runs by source family, owner, or business unit and produce several bounded assessments
  (see [Scoping a large registry](#scoping-a-large-registry)).
- Work the usage-priority queue from the top rather than trying to review every finding.
- Expect roughly 36 MB of detail JSON and 10,000 individual Graph calls at 10,000 agents. Cap the
  in-report inventory table and ship the full inventory as CSV.

**Disclose coverage.** A blocked or scoped run has not examined every pair. State the agent count,
candidate pairs compared, exhaustive pair count, and whether any oversized block was sampled.
Reporting otherwise is a false assurance.

## Scoping a large registry

### Scope by data source (preferred)

Data-source overlap is worth 45 of the 100 confidence points, so agents grounded in the same system
are exactly the ones that can reach a High recommendation. Scoping by connector therefore keeps
duplicate pairs together.

```powershell
# Discover what the tenant uses
pwsh -File ".\scripts\Select-AgentsBySource.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" -ListSources

# Scope to one system
pwsh -File ".\scripts\Select-AgentsBySource.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -Source 'ServiceNow' `
  -OutputPath ".\Compare-Agents-Export\agent-builder-details.servicenow.json"
```

On the reference tenant a ServiceNow scope cut 3,741 exhaustive pairs to 21 (178x) while keeping
both ServiceNow clusters fully intact. Across every connector scope tested, 9 of 10 preserved every
cluster they touched.

The pipeline runner accepts the same `-Source` parameter, so a scoped assessment is one command:

```powershell
pwsh -File ".\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -Source 'ServiceNow' -OutputDirectory ".\snow"
```

Use a topic pattern for SharePoint rather than a single site name, because content for one subject
can span several sites; the script warns when out-of-scope agents use a related system name.
Cross-system overlap is out of scope by construction, so run each system in turn, or run unscoped,
when you need full coverage.

### Scope by activity (use with care)

```powershell
pwsh -File ".\scripts\Select-ActiveAgents.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -OutputPath ".\Compare-Agents-Export\agent-builder-details.active.json" `
  -ActiveWithinDays 30
```

| Option | Purpose |
|---|---|
| `-ActiveWithinDays` | Days since last use that still count as active (default 30) |
| `-MinSessions` / `-MinActiveUsers` | Switch to usage-threshold selection (see below) |
| `-GraceDaysForNewAgents` | Protects newly created agents that have not been adopted yet |
| `-ExcludeUnknownUsage` | Also drops agents with missing telemetry (aggressive) |

#### Usage-threshold selection

Setting `-MinSessions` or `-MinActiveUsers` changes the question from "which agents look dormant?"
to "which agents provably clear this bar?", so missing evidence is handled differently:

```powershell
# "Agents with at least 5 sessions, used in the last 30 days"
pwsh -File ".\scripts\Select-ActiveAgents.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -MinSessions 5 -ActiveWithinDays 30
```

| | Dormancy scoping | Usage threshold |
|---|---|---|
| Missing telemetry | Kept for safety | **Excluded** |
| Newly created agent | Kept via grace period | **Excluded** |
| Conditions | Any one qualifies | **All** must hold |

Two caveats the scripts print at runtime:

- **Cumulative counters are not a rolling window.** `totalSessions` is a lifetime total, so this
  means *lifetime sessions ≥ 5 **and** last used within 30 days* — which approximates but does not
  equal "5 sessions in the last 30 days". The API exposes no windowed counter.
- **The usage fields are undocumented.** `totalSessions`, `activeUsers`, `totalRunTimeInHours`, and
  `lastUsedDateTime` are returned by Graph but absent from the published `copilotPackageDetail`
  schema, so their aggregation window is unspecified and they may change without notice.

**Whether usage filtering costs you findings depends on the tenant.** On a small test tenant where
almost nobody uses the agents, every duplicate is also unused, so an activity filter removes the
findings entirely. On a production-shaped 10,000-agent tenant where roughly 90% of agents have real
usage, `-MinSessions 5 -ActiveWithinDays 30` kept 5,633 agents and still surfaced 91 clusters.

Check your own tenant before deciding:

```powershell
# What share of the registry has any recorded usage?
pwsh -File ".\scripts\Get-AgentUsagePriority.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json"
```

If most agents are P3 with no telemetry at all, treat usage filtering as a reporting lens rather
than an analysis scope, and verify against an unfiltered run. If most agents show real usage, it is
a sound way to focus the work on agents people actually depend on.

Usage filtering pairs naturally with the dormancy rule below: lifecycle handles the unused tail,
while Compare-Agents finds overlap among the agents that remain in service. With that split,
filtering to active agents is not losing findings — the excluded agents are being handled by the
other process.

## Lifecycle: warn, then block dormant agents

`Invoke-AgentLifecyclePolicy.ps1` applies a staged dormancy policy to the **same export** the
comparison uses. No second retrieval is needed: the export already carries `lastUsedDateTime`,
`createdDateTime`, `isBlocked` and `ownerId`.

| Days idle | Stage | Action |
|---|---|---|
| 0–29 | Active | none |
| 30 / 60 | Idle | report for owner notification |
| 90+ | Dormant | **block** (reversible) |

```powershell
# Classify only - no Graph connection, no changes
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json"

# Block, after a fresh export
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -TenantId "contoso.onmicrosoft.com" -LiveMode

# Undo a live run
pwsh -File ".\scripts\Invoke-AgentLifecyclePolicy.ps1" `
  -Rollback ".\Compare-Agents-Export\agent-lifecycle-decisions.csv" `
  -TenantId "contoso.onmicrosoft.com" -LiveMode
```

Four constraints matter before you rely on it:

- **Block is `/beta` only** and Microsoft states beta APIs are not supported for production use.
- **It needs a different permission** — delegated `CopilotPackages.ReadWrite.All`, not the
  read-only scope the export uses.
- **There is no application permission**, so it cannot run unattended as a service principal. A
  human admin must sign in each time.
- **There is no delete API.** Block, unblock, reassign and update are the only write operations, so
  a "delete after N more days" stage has to be finished by hand in the admin center.

Safety behaviour: dry run by default, stale exports refused (dormancy from old data can block an
agent used since), missing telemetry never treated as dormancy, new agents protected by a grace
period, and every live run reversible from its decision CSV.

Full detail and the measured composition effect are in
[`references/agent-lifecycle-blocking.md`](../references/agent-lifecycle-blocking.md).

## Lifecycle: delete agents blocked 30+ days

`Invoke-AgentDeletionReview.ps1` closes the loop. It decides which agents have been blocked long
enough to remove, and produces a reviewed worklist.

**It never deletes anything, because nothing can.** There is no delete operation in the Package
Management API, `DELETE /appCatalogs/teamsApps/{id}` does not apply to Agent Builder agents (it
requires `distributionMethod == organization`), and no PowerShell cmdlet does it either. The
supported path is **Microsoft 365 admin center → Agents → All agents →** filter Platform =
*Agent Builder in Microsoft Copilot* → **⁝ → Delete**. That deletion is irreversible, removes all
associated files and the underlying SharePoint Embedded container, and takes up to 24 hours to
reach every user.

There is also **no auto-purge of blocked agents**, so without this stage blocked agents accumulate
indefinitely.

### The problem it solves

The tenant does not record *when* an agent was blocked — `isBlocked` is a bare boolean with no
accompanying date. So elapsed block time has to be reconstructed. The script keeps a durable ledger
(`agent-block-ledger.csv`) and dates each block from the best source available:

| Precision | Source | Quality |
|---|---|---|
| `Audit` | `BlockedAgent` / `UnblockedAgent` in the unified audit log | Best — recovers dates retroactively, including blocks made by other admins |
| `Exact` | A live `Invoke-AgentLifecyclePolicy.ps1` run | Precise, but only for blocks this toolkit applied |
| `FirstObserved` | The first run that saw the agent blocked | A lower bound, never an invention |

```powershell
# 1. Recover historical block dates from the audit log (needs AuditLogsQuery.Read.All)
pwsh -File ".\scripts\Get-AgentBlockHistory.ps1" `
  -TenantId "contoso.onmicrosoft.com" -OutputPath ".\agent-block-history.csv"

# 2. Report agents blocked 30+ days
pwsh -File ".\scripts\Invoke-AgentDeletionReview.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" `
  -BlockHistoryPath ".\agent-block-history.csv" `
  -DecisionsPath ".\Compare-Agents-Export\agent-lifecycle-decisions.csv"

# Just accumulate history, no worklist
pwsh -File ".\scripts\Invoke-AgentDeletionReview.ps1" `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json" -UpdateLedgerOnly
```

Without the audit step the first run can only start every clock at today, so nothing is eligible
for a further 30 days even if an agent has been blocked for a year. Audit retention (typically 180
days) is the limit; older blocks fall back to `FirstObserved`.

### Safety rules

- **An unblock resets the clock.** An agent blocked, released, then re-blocked starts from zero —
  inheriting the old date would delete something an admin had just deliberately re-blocked.
- **Usage after a block is held for investigation** (`UsedSinceBlock`), never proposed for deletion.
- **A first sighting is never actionable** (`ClockStartedNow`), so an empty worklist is explained
  rather than mysterious.
- Raising the threshold can only ever shrink the worklist.

## Limits and caveats

Everything below was measured or verified against Microsoft Learn rather than assumed. Read it
before acting on a report or running a live stage.

### Nothing here can run unattended

Block, unblock, and the audit query are all **delegated-only** — there is no application permission
for any of them. A human admin must sign in interactively every time. There is no supported way to
schedule this pipeline as a service principal, which is the single biggest barrier to operating it
at scale and the strongest argument for the capability living in the admin center.

### The write APIs are preview

`block`, `unblock`, `update`, and `reassign` exist only on `/beta`. Microsoft states beta APIs are
subject to change and are **not supported for production use**. The read path used for export and
analysis is on `v1.0` and is not affected.

Watch item: the Agent Registry APIs are being replaced by Agent 365 APIs from **May 2026**, which
is the most likely vehicle for a supported delete operation. Recheck the Package Management
overview after that ships.

### Deletion is not automatable

There is no delete operation anywhere that applies to an Agent Builder agent:

| Candidate | Verdict |
|---|---|
| `DELETE /copilot/admin/catalog/packages/{id}` | Does not exist — the API is list, get, update, block, unblock, reassign |
| `DELETE /appCatalogs/teamsApps/{id}` | Requires `distributionMethod == organization`; a user-created Agent Builder agent never qualifies. Delegated-only as well |
| `DELETE /agentRegistry/agentInstances/{id}` | Different object — Entra Agent Registry instances ("AI teammates") |
| `DELETE /copilot/agentRegistrations/{id}` | Different object — only agents created via `POST /copilot/agentRegistrations` |
| `Remove-MgAppCatalogTeamApp` | Wrapper of the teamsApps delete; identical constraint |

Deletion is a **supported admin-center action**, just not an API: **Agents → All agents →** filter
Platform = *Agent Builder in Microsoft Copilot* → **⁝ → Delete**. It is irreversible, removes all
associated files and the underlying SharePoint Embedded container, and can take up to 24 hours to
reach every user. Owners can also delete their own agents from the Copilot app.

There is **no documented auto-purge of blocked agents** — they persist indefinitely until someone
removes them.

### The tenant does not record when an agent was blocked

`isBlocked` is a bare boolean. There is no `blockedDateTime` and no `blockedBy`. Elapsed block time
is therefore **reconstructed, not queried**, and every row carries a `Precision` column saying how:

- `Audit` — recovered from the unified audit log. Bounded by **audit retention, typically 180
  days**; an agent blocked before that window cannot be dated this way.
- `Exact` — a live policy run this toolkit performed.
- `FirstObserved` — the first run that saw the agent blocked. A **lower bound**, so the agent may
  have been blocked much longer.

Consequence: on a first run, every clock starts that day and the deletion worklist is **empty by
design**. Run `Get-AgentBlockHistory.ps1` to date existing blocks retroactively.

### Usage telemetry is undocumented and often absent

`totalSessions`, `activeUsers`, `totalRunTimeInHours`, and `lastUsedDateTime` are returned by Graph
but are **absent from the published `copilotPackageDetail` schema**. They can change or disappear
without notice.

- They are **cumulative lifetime counters, not rolling windows**, and the aggregation window is
  unspecified. "5 sessions in the last 30 days" is not directly expressible; `-MinSessions` filters
  lifetime totals.
- **Sparsity is the biggest operational risk.** On the reference tenant, **78 of 87 agents had no
  `lastUsedDateTime` at all.** A dormancy policy there would classify ~90% as `NoTelemetry`. Note
  that the API **cannot distinguish "never used" from "telemetry missing"** — they look identical.
  The scripts never block on either, but verify the distribution with a dry run before trusting any
  threshold; a policy firing on absent data is a governance incident, not a cleanup.
- Never use `lastModifiedDateTime` as an activity proxy. It tracks configuration changes; on the
  reference tenant a 30-day filter on it dropped half the genuinely active agents.
- **`-ExcludeUnknownUsage` on `Select-ActiveAgents.ps1` is a footgun on a sparse tenant.** It drops
  every agent whose telemetry is missing, not just agents proven idle — which on the reference
  tenant would discard 78 of 87. Use it only after confirming telemetry actually populates.

### Retrieval cost grows linearly with the registry

There is no bulk detail endpoint: the export issues **one detail request per package**. A
10,000-agent tenant means 10,000 requests, and Graph will throttle. Both the exporter and the
lifecycle script retry with exponential backoff and honour `Retry-After`, but a full export of a
large registry takes time and cannot be parallelised away. Plan for it, and prefer re-analysing an
existing export over re-exporting.

### Filtering does not reduce download cost

Usage telemetry and connector identity are returned only by the per-package detail call, and there
is no server-side filter for a data source or any usage field. `-MinSessions`, `-MinActiveUsers`,
and `-UsedWithinDays` all run **after** retrieval: every agent is still fetched, and the filter
writes an extra `agent-builder-details.selected.json` beside the full export.

Only two switches reduce retrieval: `-ExcludeBlocked` (because `isBlocked` is on the list response)
and `-ModifiedSince` (a server-side `lastModifiedDateTime` filter). **`-ModifiedSince` is not an
activity filter** — it tracks configuration changes, and on the reference tenant a 30-day window
dropped half the genuinely active agents. Use it to resume an interrupted export, not to find
active agents.

### Analysis coverage is bounded

- **Scoping hides cross-scope overlap.** Two agents that share only capability-level grounding plus
  an identical purpose can still be High confidence, and a single-source scope will not see them.
  Run each system in turn, or run unscoped, for full coverage.
- **Source scoping drops source-free agents by default.** `Select-AgentsBySource.ps1` excludes
  agents with no detectable data source unless you pass `-IncludeUnknownSources`. Two agents that
  overlap purely on purpose, with no grounding at all, will not appear in a scoped run.
- **Lexical similarity is advisory only** and never sets confidence. Two agents can describe the
  same job in different words, and unrelated agents can share a template. A low score defers a pair
  in the queue; it never removes it.
- **A cluster larger than ~25 agents is usually a platform grouping**, not a duplicate set — report
  it as needing further scoping.
- Oversized comparison blocks are **refined first**, and the resulting sub-blocks are compared
  exhaustively; only blocks still oversized after refinement are sampled. The report states
  coverage explicitly — never read it as an exhaustive review.

### Guards depend on export metadata

The stale-export guard reads `export-metadata.json` from beside the details file. If that file is
**missing**, age cannot be computed, and both the lifecycle policy and the deletion review **warn
and continue rather than refuse**. Keep the metadata file with its export; do not hand a bare
`agent-builder-details.json` to a live stage.

### Paths not yet exercised against a live tenant

- The **live block call** has never been executed. It needs `CopilotPackages.ReadWrite.All` consent
  and a real sign-in. Dry run, the stale-export guard, and rollback are all tested.
- **`Get-AgentBlockHistory.ps1`'s Graph audit query** follows the documented contract but has not
  been run live. The audit payload's agent-id property name is not contractually fixed, so the
  script probes several candidates. Run it once interactively with `-RawPath` and confirm the
  record count before wiring it into anything.

### Interactive sign-in needs a real terminal

Browser authentication cannot complete inside an embedded terminal — WAM needs a parent window
handle. Run the export from a real `pwsh` window, or use `-UseDeviceAuthentication`.

### Policy questions this toolkit cannot answer for you

These are governance decisions, not technical gaps. Settle them before operating the lifecycle
stages on a real tenant:

- **What is the appeal path when an owner disputes a block?** Blocking is reversible, but there is
  no built-in notification or request-review flow.
- **Should blocking be scoped per business unit**, so owners only ever see their own agents?
- **Does `exceptionRate` belong in the policy?** It is another undocumented field, and a
  high-failure agent may deserve different treatment from a merely idle one.
- **Who confirms the deletion?** The worklist is a recommendation; someone must own the irreversible
  admin-center action and the 24-hour propagation window that follows.

## Regression tests

The analysis scripts have a self-contained test suite covering invariants that were each broken at
least once during development, where the failure was silent rather than loud:

```powershell
pwsh -File ".\evals\Invoke-CompareAgentsTests.ps1"
```

It verifies that related connector families still reach the High path, that an agent's own
`definition.id` is never mistaken for a data source, that a genuinely used agent is never scored
P3 beside a high-volume outlier, that newly created agents survive the activity filter, that an
explicit usage threshold is not overridden by the safety defaults, and that the purpose pre-scorer
never drops a pair.

For the lifecycle stages it also verifies that missing telemetry never causes a block, that
re-blocking an agent **resets** its deletion clock rather than inheriting the old one, that audit
replay dates a block from the current block rather than the first one ever, and that an agent used
after being blocked is held back for investigation instead of deleted.

The suite is **mutation-tested**: reintroducing the identifier bug, linear usage normalization, the
threshold-override bug, the empty-review-queue bug, or removing the deletion-clock reset each make
it fail. A green suite proves nothing until you have watched it go red.

## Authentication and privacy

Authentication is interactive and delegated through Microsoft Graph. Do not paste passwords,
tokens, client secrets, certificates, or browser cookies into chat. The export requests only
`CopilotPackages.Read.All` and disconnects from Graph when it finishes.

The lifecycle stages request broader scopes — `CopilotPackages.ReadWrite.All` to block and
`AuditLogsQuery.Read.All` to read block history — and each also disconnects on completion,
including on failure. All three are delegated-only; no stage stores a credential or token.

If browser authentication cannot open from the terminal, the exporter also supports delegated
device-code authentication:

```powershell
pwsh -File ".\scripts\Export-AgentBuilderAgents.ps1" `
  -TenantId "contoso.onmicrosoft.com" `
  -OutputDirectory ".\Compare-Agents-Export" `
  -UseDeviceAuthentication
```

The raw exports can contain internal agent names, descriptions, source URLs, group identifiers,
and configuration details. Store and share them according to your organization's data-handling
requirements.

## Common issues

| Symptom | Likely cause |
|---|---|
| `Microsoft.Graph.Authentication is required` | Install the module with `Install-Module Microsoft.Graph.Authentication -Scope CurrentUser` |
| `401` or missing scope | Sign in again and grant `CopilotPackages.Read.All` |
| `403` | The account lacks the required admin role, consent, or Agent 365 license |
| No agents returned | Confirm the tenant contains Agent Builder agents and the commercial-cloud API is available |
| Low confidence throughout the report | Graph did not expose enough source, action, ownership, or audience metadata |
| Browser sign-in never opens | Embedded terminals cannot host the WAM prompt. Use a real `pwsh` window or `-UseDeviceAuthentication` |
| `The token lacks CopilotPackages.ReadWrite.All` | Blocking needs a broader scope than the export. An admin must consent, then sign in again |
| `The export is N hour(s) old` | Deliberate guard: dormancy from stale data can block an agent used since. Re-export, or pass `-AllowStaleExport` |
| Most agents classified `NoTelemetry` | The tenant is not populating `lastUsedDateTime`. Do not lower the threshold to compensate — investigate the telemetry first |
| Deletion worklist is empty on first run | Expected. Every clock starts on first sighting. Run `Get-AgentBlockHistory.ps1` to date existing blocks retroactively |
| Audit query returns records but no events | The agent-id property in `auditData` differs from the probed names. Re-run with `-RawPath` and inspect the payload |
| `The audit query did not finish within N minute(s)` | Audit queries run asynchronously and a wide window is slow. Increase `-TimeoutMinutes` or reduce `-LookbackDays`; the query keeps running server-side |
| Scoped run returns fewer agents than expected | Agents with no detectable data source are excluded unless you pass `-IncludeUnknownSources` |

Owners must validate source permissions, audience boundaries, security controls, and feature
parity before retiring any agent.
