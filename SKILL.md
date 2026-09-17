---
name: compare-agents
description: "Download Microsoft 365 Copilot Agent Builder agents from a tenant through the Microsoft Graph Agent 365 Package Management API, inspect their descriptions and data sources, and produce a confidence-scored consolidation report. Use this skill whenever the user asks to inventory, audit, compare, rationalize, deduplicate, merge, or consolidate Agent Builder agents, Copilot agents, or the Microsoft 365 agent registry—even if they only mention agent sprawl, overlapping agents, duplicate knowledge sources, or governance review."
compatibility: "Requires PowerShell 7, Microsoft.Graph.Authentication, a Microsoft Agent 365 license, delegated CopilotPackages.Read.All consent, and an AI admin or Global admin account. Commercial cloud only."
---

# Compare-Agents

Inventory Microsoft 365 Copilot Agent Builder agents and identify defensible consolidation
opportunities. Treat the consolidation report as governance advice: the analysis path never blocks,
deletes, reassigns, or modifies an agent, and you must never recommend acting on it without owner
validation.

The Phase 5 lifecycle scripts are the one exception, and only when the user explicitly asks for
them: `Invoke-AgentLifecyclePolicy.ps1 -LiveMode` blocks dormant agents (reversibly). Never run a
live stage without saying what will change and confirming first. Nothing deletes agents.

Read `references/graph-agent-registry.md` before connecting. Use
`scripts/Export-AgentBuilderAgents.ps1` for tenant retrieval rather than rebuilding Graph calls.

## Phase 1: Intake and tenant export

Use `ask_user` and ask one question at a time for information that is not already known:

1. Ask for the tenant ID or verified tenant domain.
2. Ask for the output directory, offering a timestamped `Compare-Agents-Export` directory under
   the current directory as the default.
3. Confirm the person signing in has an AI admin or Global admin role, a Microsoft Agent 365
   license, and permission to consent to `CopilotPackages.Read.All`.

Before asking the first question, briefly orient the user so they can assess the connection:

- Authentication will be interactive and delegated with `CopilotPackages.Read.All`.
- The signing account needs AI admin or Global admin and a Microsoft Agent 365 license.
- The export will filter the registry to platform
  `Microsoft 365 Copilot Agent Builder`, follow pagination, and retrieve package details for every
  result.
- The workflow is read-only and will not modify agents.

Then ask only for the tenant ID or verified tenant domain. Never request, handle, echo, or save a
password, token, certificate, client secret, or browser cookie.

Check for PowerShell 7 and `Microsoft.Graph.Authentication`. If the module is missing, surface the
dependency and ask before installing it. Do not silently install modules.

Run a dry run first:

```powershell
pwsh -File "<skill-path>\scripts\Export-AgentBuilderAgents.ps1" `
  -TenantId "<tenant-id-or-domain>" `
  -OutputDirectory "<output-directory>"
```

The dry run authenticates, retrieves the inventory, and prints what it would write. Review the
agent count and destination with the user. Then run the live export:

```powershell
pwsh -File "<skill-path>\scripts\Export-AgentBuilderAgents.ps1" `
  -TenantId "<tenant-id-or-domain>" `
  -OutputDirectory "<output-directory>" `
  -LiveMode
```

The exporter writes:

- `agent-builder-inventory.json`: list response for Agent Builder packages.
- `agent-builder-details.json`: detailed package objects for every listed package.
- `export-metadata.json`: tenant context, API version, retrieval time, and counts.

The Package Management API requires commercial cloud, a Microsoft Agent 365 license,
`CopilotPackages.Read.All`, and AI admin or Global admin. Explain `401`, `403`, licensing, cloud,
or consent failures directly; do not turn a failed or partial retrieval into a successful-looking
report.

## Phase 2: Normalize agent evidence

Read `agent-builder-details.json`. If the user provides an existing export, skip authentication
and begin here.

For each agent, normalize:

- ID, display name, publisher, owner information when present, deployment state, blocked state,
  version, modified time, hosts, categories, and element types.
- Short and long descriptions.
- Capabilities, actions, topics, instructions, and trigger phrases found in element definitions.
- Data sources and connection targets found in `elementDetails`.
- Usage telemetry: `totalSessions`, `totalRunTimeInHours`, `activeUsers`, and `lastUsedDateTime`.
  Treat a missing or null value as no recorded usage, not as proof the agent is unused.

Definitions can contain JSON encoded as strings. Parse nested JSON strings recursively when they
are valid JSON. Inspect keys and values related to connectors, connections, knowledge, sites,
SharePoint URLs, lists, drives, tables, APIs, endpoints, datasets, Dataverse, files, and websites.
Normalize host names, URLs, IDs, and source names for comparison, but preserve the original values
as evidence. Do not reproduce tokens, secrets, or credentials if unexpected sensitive values are
present.

Distinguish absence of evidence from evidence of absence. If Graph metadata does not expose enough
detail to identify an agent's sources or behavior, mark that dimension `Unknown` and lower the
confidence.

## Phase 2b: Scope the comparison (optional)

Two scoping levers exist, and they behave very differently. Prefer **connector scoping**.

### Preferred: scope by data source

```powershell
# Discover what the tenant actually uses
pwsh -File "<skill-path>\scripts\Select-AgentsBySource.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" -ListSources

# Scope to one system
pwsh -File "<skill-path>\scripts\Select-AgentsBySource.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -Source 'ServiceNow' `
  -OutputPath "<output-directory>\agent-builder-details.servicenow.json"
```

This is the most defensible way to break a large registry into reviewable pieces, because
data-source overlap is worth 45 of the 100 confidence points. Agents grounded in the same system
are exactly the agents that can reach a High recommendation, so a connector scope keeps duplicate
pairs together instead of separating them.

Measured on the reference tenant: scoping to ServiceNow cut 3,741 exhaustive pairs to 21 (178x)
and kept both ServiceNow clusters fully intact. Sweeping every connector scope, 9 of 10 preserved
every cluster they touched.

Two cautions:

- **SharePoint needs a topic pattern, not a site name.** Content for one subject can live on
  several sites. Scoping to `SharePoint:MicrosoftTeamsPhoneKnowledgeBase` split a real cluster
  because a sibling agent used `SharePoint:TeamsPhone`; the broader pattern `*TeamsPhone*` kept it
  whole. The script warns when out-of-scope agents use a related system name.
- **Cross-system overlap is out of scope by construction.** A pair matched only on capability
  grounding plus an identical purpose can still be High, and a single system scope will not
  necessarily contain it. Run each system in turn, or run unscoped, for full coverage.

### Use with care: scope by activity

```powershell
# Dormancy scoping: exclude agents nobody uses, with safety defaults
pwsh -File "<skill-path>\scripts\Select-ActiveAgents.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -OutputPath "<output-directory>\agent-builder-details.active.json" `
  -ActiveWithinDays 30

# Usage threshold: keep only agents that provably clear a bar
pwsh -File "<skill-path>\scripts\Select-ActiveAgents.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -MinSessions 5 -ActiveWithinDays 30
```

Setting `-MinSessions` or `-MinActiveUsers` switches the question from "which agents look dormant?"
to "which agents provably clear this bar?", so the two modes handle missing evidence differently:

| | Dormancy scoping | Usage threshold |
|---|---|---|
| Missing telemetry | Kept for safety | **Excluded** (cannot demonstrate the bar) |
| Newly created agent | Kept via grace period | **Excluded** (zero sessions is still zero) |
| Conditions | Any one qualifies | **All** must hold |

The strict handling is deliberate: an explicit threshold is a precise selection, and returning
agents with zero recorded sessions when the caller asked for five or more is not a defensible
interpretation.

**Cumulative counters are not a rolling window.** `totalSessions` and `activeUsers` are lifetime
totals, so `-MinSessions 5 -ActiveWithinDays 30` means *lifetime sessions ≥ 5 **and** last used
within 30 days*. That approximates but does not equal "more than 5 sessions in the last 30 days":
a long-lived agent used once last week satisfies it. The API exposes no windowed usage counter, so
report the approximation rather than the phrasing the user asked for.

**These fields are undocumented.** `totalSessions`, `activeUsers`, `totalRunTimeInHours`, and
`lastUsedDateTime` are returned by Graph but are absent from the published `copilotPackageDetail`
schema, so their aggregation window is unspecified and they may change without notice.

An activity filter can remove the very duplicates you are hunting when a tenant has little real
usage, because a cloned agent that nobody adopted is both a duplicate and unused. On a small test
tenant where all 15 high-confidence retirement candidates had zero usage, a strict active-only
filter removed **all 20 findings**. On a production-shaped 10,000-agent tenant where roughly 90% of
agents had real usage, the same filter kept 5,633 agents and still surfaced 91 clusters.

Check the usage distribution before choosing a scope. If most agents report no telemetry, treat
usage filtering as a reporting lens and verify against an unfiltered run. If most agents show real
usage, it is a sound way to focus on agents people depend on.

Treat the two processes as complementary: a lifecycle process retires the dormant tail, while
Compare-Agents finds overlap among agents people actually use. With that split in place, filtering
to active agents is not losing findings, because the excluded agents are handled elsewhere.

### Neither filter reduces download cost

Both usage telemetry and connector identity live in fields returned only by the per-package detail
call. `elementDetails` is not in the list response, there is no server-side `$filter` for a data
source or for any usage field, so scoping reduces analysis effort rather than Graph requests.

`Export-AgentBuilderAgents.ps1` accepts `-MinSessions`, `-MinActiveUsers`, and `-UsedWithinDays`
for convenience. They run **after** retrieval and write an extra `agent-builder-details.selected.json`
beside the full export; every agent is still fetched, and the full export is always kept because
re-fetching details is the expensive part.

The only genuine download saving is `-ExcludeBlocked`, because `isBlocked` **is** returned by the
list call. Never substitute `lastModifiedDateTime` for activity: it tracks configuration changes,
and on the reference tenant a 30-day filter dropped 2 of the 4 genuinely active agents.

## Phase 3: Compare candidates

**Run the pipeline first.** The analysis stages are separate scripts so each can be validated on
its own, but a normal assessment runs them in a fixed order with matching paths. Use the
orchestrator rather than chaining them by hand:

```powershell
pwsh -File "<skill-path>\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -OutputDirectory "<output-directory>"

# Scope to one system (preferred for large registries)
pwsh -File "<skill-path>\scripts\Invoke-CompareAgentsPipeline.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -Source 'ServiceNow' -OutputDirectory "<output-directory>\servicenow"
```

It runs optional scoping, usage ranking, blocking with Pass 1 cascade routing, and semantic queue
ordering, then prints a review plan: how many pairs need full analysis, which agents have live
adoption, and which pairs to start with. It performs no authentication and makes no Graph calls.

It deliberately stops short of scoring. Confidence and consolidation decisions stay with the
reasoning steps below, because the evidence rules require judgement a script cannot make.

**Scale first.** Exhaustive pairwise comparison is O(n²) and is only viable for small registries.
87 agents produce 3,741 pairs, but 10,000 agents produce **49,995,000**. Never attempt an exhaustive
comparison on a large registry, and never claim one was performed.

Before comparing, generate the candidate set with blocking:

```powershell
pwsh -File "<skill-path>\scripts\Get-AgentComparisonCandidates.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -CsvPath "<output-directory>\agent-comparison-candidates.csv"
```

Blocking compares only agents that share concrete evidence, using five tiers: exact data source,
source family, exact normalized purpose, rare description tokens, and rare source-path tokens. On
the reference tenant this recovers 100% of known clusters while examining 12.8% of pairs.

### Multi-pass cascade

The script also assigns each surviving pair a `Pass1Route`, so semantic effort is spent only where
it can change the outcome. Work the passes in order and stop as soon as a pair is resolved:

| Pass | Cost | Work |
|---|---|---|
| 0 — Blocking | Mechanical | Group by shared evidence; discard unrelated agents |
| 1 — Source triage | Mechanical | Route each pair by the best score it could still reach |
| 2 — Purpose | Semantic | Score purpose only for pairs that survived Pass 1 |
| 3 — Capability, audience, viability, target | Semantic | Only for pairs that can still reach High |

Pass 2 is the real bottleneck once pairing is solved: at 10,000 agents it is roughly 9,000 pairs of
full-text reading. Order that queue before working it:

```powershell
pwsh -File "<skill-path>\scripts\Get-PurposeSimilarity.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -CandidatePath "<output-directory>\agent-comparison-candidates.csv" `
  -CsvPath "<output-directory>\agent-purpose-similarity.csv"
```

This computes a deterministic TF-IDF cosine similarity over each agent's instructions and
descriptions, with authoring-tool boilerplate stripped and template wording suppressed by inverse
document frequency. On the reference tenant the top 25 ranked pairs were all real duplicates, and
working half the queue found 100% of them.

Treat the output strictly as **review order**:

- It never emits a confidence score and never decides consolidation.
- Lexical overlap is not evidence of shared purpose. Two agents can describe the same job in
  different words, and unrelated agents can share a template, so the semantic judgement in Pass 2
  still has to be made.
- A low similarity only defers a pair to the back of the queue. It never removes one, so the
  cascade stays lossless.

`Pass1Route` values:

- **HighCandidate** — shares an exact source, a source family, or coarse grounding plus a
  distinctive purpose. Can reach High, so it needs full analysis and target selection.
- **MediumOnly** — related only by coarse capability grounding or one-sided evidence. Capped at 79,
  so it can never be recommended for consolidation; give it the cheaper review treatment and skip
  target selection and migration scope entirely.
- **LowDeferred** — sources unknown on both sides, capped at 59.
- **Pruned** — both sides have known sources with no exact or family relationship.

**Pruning must be admissible.** A pass may discard a pair only when its *best possible* remaining
score cannot reach the band. Sources are worth 45 and everything else totals 55, so a pair with
genuinely no source relationship peaks at 55, below the Medium threshold of 60, and can be dropped
safely. Two thresholds follow directly from the weights:

- A pair needs **source ≥ 25/45** to reach High (25 + 55 = 80).
- After purpose is scored, a pair needs **source + purpose ≥ 55** to stay eligible for High.

Never convert this into a hard filter such as "only compare descriptions when sources match
exactly." Validation against the reference tenant showed three ways a naive filter silently loses
real duplicates:

1. **Unknown is not disjoint.** Absence of source evidence cannot be treated as proof of no
   overlap, so a pair with an unknown side must never be pruned.
2. **Related sources are not zero evidence.** `GitLabCloudIssues1` and `GitLabCloudIssues2` are
   distinct connections to the same system and score partial credit, so match on source family.
3. **Coarse grounding still counts.** Capability-level grounding such as `WebSearch` is real shared
   evidence, and combined with a distinctive purpose it can support a High recommendation.

On the reference tenant the full cascade reduced 3,741 exhaustive pairs to 81 needing full semantic
analysis (2.2%), while every one of the 20 known clusters survived.

Then compare **only the candidate pairs**, and apply the same scoring and safeguards below. Record
the coverage figures the script reports; the assessment must state how many pairs were compared and
whether any oversized block was sampled rather than fully expanded.

Observe these scale rules:

- If the script reports sampled blocks, say so explicitly in the report. A sampled run has **not**
  reviewed every possible pair, and claiming otherwise is a false assurance.
- For very large registries, scope the run (by source family, owner, or business unit) and produce
  several bounded assessments instead of one unreviewable report.
- Rank the output by usage priority so the administrator receives a queue they can actually work
  through, not a list of thousands of undifferentiated findings.
- Never lower the evidence bar to make a large run finish. Blocking reduces which pairs are
  compared; it never changes how a compared pair is scored.

Compare agents pairwise, but use names only as a weak discovery signal. Base conclusions on
specific evidence.

Score each pair from 0 to 100:

| Dimension | Weight | Evidence |
|---|---:|---|
| Data-source overlap | 45 | Exact sources, sites, connectors, tables, or substantially overlapping knowledge scope |
| Purpose and description overlap | 30 | Same user jobs, questions, outcomes, domain, and intent—not merely shared generic words |
| Capability and action overlap | 10 | Similar actions, topics, instructions, APIs, or supported tasks |
| Audience and host overlap | 5 | Similar users, groups, deployment scope, and hosts |
| Consolidation viability | 10 | A credible target can absorb the other agent without losing distinct security, ownership, or lifecycle needs |

Use these confidence bands:

- **High: 80-100** — recommend consolidation and identify a target agent.
- **Medium: 60-79** — flag for owner review; do not recommend consolidation yet.
- **Low: 0-59** — retain as separate unless new evidence is gathered.

Apply these safeguards:

- Cap confidence at 79 when either data-source overlap or purpose overlap lacks concrete evidence.
- Cap confidence at 59 when data sources are unknown for both agents unless unusually strong
  capability evidence is available.
- Shared platform, host, publisher, or generic phrases such as "helps employees" are not enough.
- Keep agents separate when security boundaries, audiences, owners, regulatory scope, update
  cadence, or specialized actions materially differ.
- Do not manufacture precision. Use a range or lower score when metadata is incomplete.

For high-confidence pairs, select the consolidation target using maintainability and coverage:
prefer the agent with the clearer purpose, more complete and current configuration, appropriate
security boundary, broader relevant source coverage, active deployment, and identifiable owner.
Do not choose solely because it is newer. If neither agent is a safe target, recommend a new
shared agent instead and explain why.

When more than two agents form a cluster, analyze the cluster as a whole. Avoid contradictory
pairwise recommendations such as merging A into B and B into C without naming the final target.

## Phase 3b: Rank by usage priority

Confidence answers "are these the same agent?". It does **not** tell an administrator what to do
first. Compute a separate **usage priority** so high-adoption agents surface at the top of the
review queue and low-adoption duplicates are recognized as low-risk cleanup.

Use `scripts/Get-AgentUsagePriority.ps1` rather than recomputing the model by hand:

```powershell
pwsh -File "<skill-path>\scripts\Get-AgentUsagePriority.ps1" `
  -DetailsPath "<output-directory>\agent-builder-details.json" `
  -CsvPath "<output-directory>\agent-usage-priority.csv"
```

Score each agent from 0 to 100, using **log-compressed** normalization against the highest value in
the same tenant so the result is a relative ranking:

| Signal | Weight | Why it matters |
|---|---:|---|
| `activeUsers` | 35 | People who lose an agent if it is retired |
| `totalSessions` | 30 | Depth of real, repeated use |
| `lastUsedDateTime` recency | 25 | Whether the agent is live, dormant, or abandoned |
| `totalRunTimeInHours` | 10 | Sustained workload rather than a single trial |

Log compression is mandatory, not cosmetic. With plain linear normalization a single outlier
(for example one agent with 500,000 sessions in a 10,000-agent tenant) drives every other score to
approximately zero, so thousands of genuinely used agents are reported as unused. Use
`log(1 + value) / log(1 + max)` for each volume signal.

Apply recency as a decay factor: 30 days or fewer scores full weight, 90 days scores 0.6, 180 days
scores 0.3, and anything older or missing scores 0.

Use these priority bands:

- **P1 — Act first (60-100):** Live adoption. Consolidation affects real users, so owner validation,
  redirect planning, and user communication are required before any change.
- **P2 — Validate (10-59):** Any agent with usage evidence that is not P1, including dormant or
  shallow use. Confirm whether the agent is an abandoned pilot before treating it as disposable.
- **P3 — No recorded usage (0):** Reserved **exclusively** for agents with no sessions, no active
  users, no runtime, and no `lastUsedDateTime`. An agent with any usage evidence must never fall
  into P3, so apply a floor of 10 to every agent that has any signal.

A cluster inherits the highest priority band of any agent it contains. Rank the recommendation
queue by priority band first, then by confidence within each band. At enterprise scale this queue
is the deliverable: an administrator can act on the top of a ranked list, but not on thousands of
undifferentiated findings.

Apply these safeguards so usage never overstates a conclusion:

- Usage priority **never** raises or lowers consolidation confidence. Report the two scores
  separately.
- Zero usage is not evidence that agents are duplicates, and high usage is not evidence that they
  differ.
- Never recommend retiring an agent because usage is low. Low usage changes migration risk and
  sequencing, not whether a duplicate exists.
- Telemetry can lag, exclude some hosts, or reset after republishing, so state that a zero value
  means "no recorded usage in the export" and ask the owner to confirm before retirement.

When usage differs materially inside a high-confidence cluster, prefer the more-adopted agent as
the surviving target, because retiring it would displace existing users. Override this only when
configuration completeness, security boundary, or ownership evidence clearly favors another agent,
and say so explicitly.

## Phase 4: Write the reports

Save `compare-agents-report.md` next to the raw exports. Use this structure:

```markdown
# Agent Builder Consolidation Assessment

## Executive summary

## Usage priority ranking

## Inventory

## High-confidence consolidation recommendations
### <Cluster or pair>
- Confidence: <score>/100 (High)
- Usage priority: <P1|P2|P3> (<score>/100) — <sessions, active users, last used>
- Consolidate: <source agent(s)> into <target agent or new shared agent>
- Evidence:
- Distinct behavior to preserve:
- Proposed migration scope:
- Owner validation required:

## Medium-confidence opportunities requiring review

## Agents that should remain separate

## Data-quality gaps and follow-up questions

## Method and scoring
```

Include an inventory table and a recommendation table. Show `totalSessions`, `activeUsers`,
`totalRunTimeInHours`, and `lastUsedDateTime` in the inventory, and show the usage priority band
alongside confidence in the recommendation table so an administrator can sort by impact.

The **Usage priority ranking** section must list the P1 agents first, state which clusters they
belong to, and give the IT pro an explicit action sequence: validate P1 clusters before changing
them, then execute zero-usage high-confidence retirements as low-risk cleanup, then confirm whether
P2 agents are abandoned pilots.

### Reporting at scale

A registry with thousands of agents cannot be rendered as one exhaustive document:

- **Report clusters, not pairs.** The pipeline writes `agent-consolidation-clusters.csv`, grouping
  candidate pairs into connected components. On a 5,000-agent tenant, 92,016 candidate pairs formed
  only 75 components: an administrator holds ~75 consolidation conversations, not 92,000 pair
  reviews. Reporting the pair count as the workload makes a tractable result look impossible.
- **Separate real clusters from platform groupings.** A component larger than ~25 agents is usually
  "every agent on one connector" rather than one duplicate set. Report it as a grouping that needs
  further scoping, not as a consolidation candidate.
- **Rank by user impact.** Order clusters by the highest usage-priority band and total sessions
  they contain, so the administrator starts where a change would affect the most people.
- State the **comparison coverage** near the top: agents, candidate pairs compared, exhaustive pair
  count, cluster count, and whether any oversized block was sampled. Never imply an exhaustive
  review that did not happen.
- Cap the inline inventory (about 500 rows) inside its collapsible section and write the full
  inventory to CSV alongside the report. A 10,000-row HTML table is unusable.
- Prefer several scoped assessments over one enormous report when the registry is very large.

For every high- or medium-confidence item,
cite the exact shared descriptions, data sources, capabilities, or audiences that support the
score. State what is unique and must be preserved. Ask follow-up questions for unknown ownership,
security boundaries, audiences, or sources that could change a recommendation.

End with a clear reminder that owners must validate source permissions, audience boundaries, and
feature parity before retiring an agent.

After the Markdown report is complete, generate `compare-agents-report.html` from it:

```powershell
pwsh -File "<skill-path>\scripts\Convert-CompareAgentsReport.ps1" `
  -MarkdownPath "<output-directory>\compare-agents-report.md" `
  -HtmlPath "<output-directory>\compare-agents-report.html"
```

The HTML file is a self-contained, accessible rendering of the complete Markdown report. It must
not omit inventory rows, evidence, scores, recommendations, or data-quality gaps. The bundled
converter supplies responsive tables, print styling, and light/dark theme support without external
CDNs or network dependencies. Deliver both `.md` and `.html` files.

## Phase 5: Lifecycle governance (separate from consolidation)

Consolidation asks "are these the same agent?". Lifecycle asks "is anyone using this one?" — a
policy question answerable from telemetry alone, needing no pairwise comparison. Do not run an
O(n²) analysis to find dormant agents.

The same export drives all three stages, so never re-retrieve for them:

| Stage | Script | What it does |
|---|---|---|
| Warn, then block | `scripts/Invoke-AgentLifecyclePolicy.ps1` | Classifies by days idle; blocks at 90+ days. Dry run by default, reversible via `-Rollback`. |
| Recover block dates | `scripts/Get-AgentBlockHistory.ps1` | Pulls `BlockedAgent` / `UnblockedAgent` from the unified audit log. |
| Delete review | `scripts/Invoke-AgentDeletionReview.ps1` | Reports agents blocked past the threshold and maintains the block ledger. |

Rules that must not be softened when reporting on these stages:

- **Never state or imply that the tooling deletes agents.** There is no delete operation in the
  Package Management API and no PowerShell cmdlet for it. Deletion happens in the Microsoft 365
  admin center: **Agents → All agents →** filter Platform = *Agent Builder in Microsoft Copilot* →
  **⁝ → Delete**. Warn that it is irreversible, removes all associated files and the underlying
  SharePoint Embedded container, and takes up to 24 hours to propagate.
- **Never treat missing telemetry as dormancy.** On the reference tenant 78 of 87 agents had no
  `lastUsedDateTime` at all. Report those as needing manual review, and say so plainly if they
  dominate the tenant — a policy firing on absent data is a governance incident, not a cleanup.
- **Never present a block date as known when it is inferred.** The agent resource has no
  `blockedDateTime`. Always surface the `Precision` column (`Audit`, `Exact`, or `FirstObserved`)
  so the administrator knows whether a date was recovered from audit history or is merely the first
  time this tooling saw the agent blocked.
- **Explain an empty deletion worklist rather than reporting zero findings.** On a first run every
  clock starts that day, so nothing can be eligible. Recommend `Get-AgentBlockHistory.ps1` to date
  existing blocks retroactively, and note that audit retention (typically 180 days) bounds it.
- Blocking needs `CopilotPackages.ReadWrite.All`, audit queries need `AuditLogsQuery.Read.All`, and
  neither block nor the Teams app delete offers an application permission — so **no part of this
  can run unattended.** State this whenever scheduling comes up.
