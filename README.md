# Compare-Agents

**Every team builds its own agent. Nobody sees the overlap.**

Compare-Agents inventories Microsoft 365 Copilot **Agent Builder** agents in a tenant, groups
overlapping agents by the data they are actually grounded in, and ranks each group by real
adoption — so an administrator sees which agents duplicate each other and which ones people
genuinely depend on.

It is a set of PowerShell 7 scripts plus a skill definition. Use it either way: run the scripts
directly, or install it as a Copilot skill and ask in natural language.

---

## What problem this solves

Agent Builder puts agent creation in every employee's hands, and curation never scales the way
creation does. Five teams ground five agents on the same connector and nobody ever sees it. The
registry lists what *exists*; nothing tells you what is *redundant*.

Comparing every agent with every other is quadratic — a 10,000-agent tenant is **49,995,000
possible pairs**. Blocking and multi-pass triage reduce that to roughly **109 review clusters**,
which is the number of conversations an administrator actually has.

---

## Requirements

- **PowerShell 7** (`pwsh`) — not Windows PowerShell 5.1
- **`Microsoft.Graph.Authentication`** module
  ```powershell
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser
  ```
- **Microsoft Agent 365 licence**
- **AI Administrator or Global Administrator** role
- A **commercial cloud** tenant — the Package Management API is not available in US Gov L4,
  US Gov L5/DoD, or China operated by 21Vianet

Each stage needs its own delegated Graph scope, consented separately:

| Stage | Scope |
|---|---|
| Export and analysis | `CopilotPackages.Read.All` |
| Block / unblock | `CopilotPackages.ReadWrite.All` |
| Block-date recovery | `AuditLogsQuery.Read.All` |

**No stage supports application permissions.** Every one is delegated-only, so an administrator
must sign in interactively — this cannot run unattended as a service principal.

---

## Quick start

```powershell
git clone https://github.com/<you>/compare-agents.git
cd compare-agents

# 1. Export the tenant (dry run first — it prints the agent count and changes nothing)
.\scripts\Export-AgentBuilderAgents.ps1 -TenantId "contoso.onmicrosoft.com" `
  -OutputDirectory ".\Compare-Agents-Export"

# 2. Run it for real
.\scripts\Export-AgentBuilderAgents.ps1 -TenantId "contoso.onmicrosoft.com" `
  -OutputDirectory ".\Compare-Agents-Export" -LiveMode

# 3. Analyse
.\scripts\Invoke-CompareAgentsPipeline.ps1 `
  -DetailsPath ".\Compare-Agents-Export\agent-builder-details.json"
```

> **Run the export from a real terminal window.** Interactive browser sign-in cannot complete
> inside an embedded/integrated terminal, because the auth broker needs a parent window handle.
> Use `-UseDeviceAuthentication` if a browser is unavailable.

---

## Using it as a Copilot skill

Copy the repository into your Copilot skills directory and the agent will pick it up:

```powershell
# Windows
Copy-Item -Recurse . "$env:USERPROFILE\.copilot\skills\compare-agents"
```

Then ask in natural language:

> *"Audit the Agent Builder agents in contoso.onmicrosoft.com and find consolidation opportunities."*
> *"Analyse this export and show me the duplicate clusters ranked by usage."*
> *"Which agents have been dormant for 90 days?"*

`SKILL.md` defines the evidence rules, the confidence model, and the reporting requirements the
agent follows.

---

## The scripts

| Script | Purpose |
|---|---|
| `Export-AgentBuilderAgents.ps1` | Export the tenant's agents over the Graph Package Management API |
| `Invoke-CompareAgentsPipeline.ps1` | End-to-end analysis: usage ranking → candidate pairs → clusters |
| `Get-AgentUsagePriority.ps1` | Score each agent by adoption (P1/P2/P3) |
| `Get-AgentComparisonCandidates.ps1` | Admissible blocking + Pass 1 triage |
| `Get-PurposeSimilarity.ps1` | Order the semantic review queue (advisory only) |
| `Select-AgentsBySource.ps1` | Scope analysis to one data source or connector |
| `Select-ActiveAgents.ps1` | Scope analysis by usage |
| `Invoke-AgentLifecyclePolicy.ps1` | Staged dormancy policy: warn, then block (reversible) |
| `Get-AgentBlockHistory.ps1` | Recover block/unblock dates from the unified audit log |
| `Invoke-AgentDeletionReview.ps1` | Report agents blocked past a threshold |
| `Convert-CompareAgentsReport.ps1` | Render the Markdown report as self-contained HTML |

---

## What it will not do

**It never deletes an agent.** It cannot: the Package Management API exposes list, get, update,
block, unblock and reassign — there is no delete operation, and no PowerShell cmdlet deletes an
Agent Builder agent. Deletion is a supported *admin centre* action only. The deletion review
produces a reviewed worklist; a human completes it.

**It never treats missing telemetry as proof of disuse.** On the reference tenant, 91% of agents
reported no adoption at all. A policy that blocked on that would be a governance incident, not a
cleanup.

**It never blocks on a stale export**, because dormancy computed from old data can block an agent
that has been used since.

Blocking requires `-LiveMode`, prompts for confirmation, and every live run is reversible from its
decision CSV.

---

## Your tenant data stays yours

Running these scripts produces files containing real agent names, descriptions, owner object IDs,
data-source URLs and usage telemetry. **`.gitignore` already excludes every one of them**, so a
clone of this repository will not accidentally publish your tenant.

Store and share exports according to your organisation's data-handling requirements. Nothing in
this tool transmits data anywhere except to Microsoft Graph.

---

## Tests

```powershell
.\evals\Invoke-CompareAgentsTests.ps1
```

51 regression tests over synthetic fixtures — no tenant access required. Each one protects an
invariant that broke at least once during development, where the failure was **silent**: the tool
produced a confident-looking report while quietly dropping real duplicates, or ranked a zero-usage
agent above one a department depended on.

The suite is **mutation-tested**. Reintroducing any of those bugs makes it fail. A green suite
proves nothing until you have watched it go red.

---

## Documentation

| Document | Contents |
|---|---|
| [`docs/USAGE.md`](docs/USAGE.md) | Full usage guide, prompts, scoring models, scaling guidance, and the complete **Limits and caveats** section |
| [`SKILL.md`](SKILL.md) | Skill definition: evidence rules, confidence model, reporting requirements |
| [`references/graph-agent-registry.md`](references/graph-agent-registry.md) | Graph API notes for the agent registry |
| [`references/agent-lifecycle-blocking.md`](references/agent-lifecycle-blocking.md) | Lifecycle policy, block-API constraints, deletion stage |

**Read the caveats before acting on a report.** The most important ones: usage telemetry is
undocumented and often absent; grounding may resolve only to capability names rather than specific
connectors, which caps confidence; and nothing here can run unattended.

---

## Licence

MIT — see [LICENSE](LICENSE).

Not an official Microsoft product. Uses documented Microsoft Graph APIs; some rely on `/beta`
endpoints, which Microsoft states are subject to change and unsupported for production use.
