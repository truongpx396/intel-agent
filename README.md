# intel-agent

A **standalone AI agent** that a host can also embed. Ingest a corpus, ask questions, get cited
answers — running by itself on one container, or wired into a larger product through declared ports.

One LangGraph `StateGraph`, adapted to a new domain by swapping a **manifest** (config) plus a thin
**domain plugin** (code) — never by forking the graph.

Extracted from [aisat-intel](https://github.com/truongpx396/aisat-intel) at `369756e`, which remains
the reference **embedding host**.

> **Status: spec-first.** Contracts, spec, and task breakdown are complete and carry their original
> commit history. Implementation has not started; `make ci` is green on a specs-only checkout and
> lights up per gate as code lands.

## Batteries included, batteries replaceable

| Capability | Standalone (ships here) | Embedded (host overrides) |
|---|---|---|
| Corpus | built-in `Ingestor` — files, URLs, text | the host's pipeline |
| Identity | built-in `IdentityBinder` — single-user or user list | the host's auth |
| Interface | built-in chat UI + CLI | the host's front end |
| Metering | no-op `Meter` — **nobody is counting** | the host's ledger |
| Store | SQLite (Profile C) or Postgres (Profile B) | whatever the host runs |

**A default is never privileged code.** It is one implementation of a declared port, held to the same
conformance suite an override must pass. That rule is what keeps "standalone" from quietly becoming
"monolith with seams painted on".

Not a multi-tenant SaaS: the identity and metering defaults are deliberately minimal. A deployment
needing real billing or org management embeds the runtime in a host that provides them.

---

## The idea in one screen

```
AgentManifest (config)  ──selects──►  DomainPlugin (code: Tools + Policy)  +  generic runtime deps
        │                                        │
        └──────────────► graph entrypoint assembles AgentDeps once per worker ──► one StateGraph
                                                 │
                                    per run: ctx (tenant/principal/claims) stamped by trusted layer
                                                 │
                              row-level pre-filter enforces visibility BELOW the graph, every manifest
```

- **Everything the runtime reads is config.** The only per-domain **code** is (1) the tool bodies
  and (2) the authorization `Policy`.
- **Config selects, code enforces.** A manifest may *name* a policy; it may never *be* one. A
  manifest can narrow what an agent may do — never widen what a principal may see.
- **The graph is manifest-blind.** No node reads the manifest. Adding a domain changes deps and
  config, never a node.

## The graph

One `StateGraph`, compiled two ways — an ephemeral interactive pass and a checkpointed durable one — never two graphs. Phase-1 edge order for an interactive (`semantic`) run:

```
START → guard → route → rewrite → retrieve → rerank → assemble → memory → generate → suggest → END
```

| Node | Does |
|---|---|
| `guard` | Moderation + injection screen + per-role tool allowlist. Fail-closed — blocks before any retrieval or spend. |
| `route` | Classifies intent (`semantic` / `structured` / `long_horizon`) and a model-tier alias. Runs once per run; immutable after. |
| `rewrite` | History-aware query rewrite/expansion. |
| `retrieve` | Vector/hybrid search on `semantic`; a fixed parameterized tool on `structured` — never free-form Text-to-SQL. |
| `rerank` | Cross-encoder rerank over the merged candidate set. |
| `assemble` | Parent-chunk expansion, dedupe, token-budget trim. |
| `memory` | Per-user memory injection, clearance-filtered at read time. Never fails the run. |
| `generate` | Grounded generation with inline citations; streams tokens. |
| `suggest` | 2–3 follow-up suggestions. Never fails the run. |

The durable form adds a tenth node, `human_gate` — the canonical LangGraph `interrupt()` / `Command(resume=…)` pattern, pausing a run before an index-mutating or outward-reaching step and settling **zero spend** while paused. Every node is a pure `(state, config)` function with its own retry/timeout/degrade policy, so a reranker outage degrades to RRF order and a memory outage degrades to no injected memory — neither fails the run.

Full node-by-node contract, the `AgentState` schema, reliability table, run-level budgets, and the Phase-2 seams (CRAG-style corrective retrieval, Self-RAG faithfulness, complexity-based model routing): [contracts/agent-graph.md](specs/001-agent-runtime/contracts/agent-graph.md).

## Tools

Ten scoped tools across four categories — one set of implementations, exposed two ways: in-process to the built-in graph, and over MCP (`:8002`) to external/local agents, through the **same** policy wrapper (allowlist check, tenant/principal scoping, audit log):

| Category | Tools | Notes |
|---|---|---|
| A — Knowledge (Tier 1) | `search_personal_knowledge`, `search_workspace_knowledge`, `get_document_by_id`, `list_documents` | Read-only, clearance/ownership pre-filtered *before* scoring |
| B — Structured (Tier 2) | `query_employees`, `query_projects`, `query_metrics` | Typed arguments only — hand-written scoped queries, never generated SQL |
| C — Utility | `get_current_datetime`, the shared `web_distill` fetch | `web_distill` is SSRF-guarded: `https`-only, DNS-rebinding-safe, no redirects |
| D — Agent actions | `web_search`, `edit_note` | HITL-gated (per-call approval before it runs/commits), access-bounded (`min(agent, owner)` clearance), durable-form only |

A tool not in the caller's `allowed_tools` is rejected before execution — the defense against a compromised or injected run escalating its own privileges. Full catalog, arguments, and enforcement rules: [contracts/mcp-tools.md](specs/001-agent-runtime/contracts/mcp-tools.md).

## Two deployment profiles, one binary

|  | **Profile A** — reference host | **Profile B** — self-contained |
|---|---|---|
| Runtimes | Go kernel + this Python tier | this Python container alone |
| Vector store | Qdrant | Postgres + pgvector |
| Bus | NATS JetStream | in-process (or Redis Streams) |
| Auth / billing | host kernel | host concerns, re-satisfied in-container |
| Access floor | RLS **+** vector pre-filter | RLS alone |

Both run the **same graph binary** and the **same manifest schema**. A is B plus the Go kernel and
the heavier backing services — a **superset relation, not a fork**. Swapping a backing service is a
port implementation or a config value, never a source change to the graph.

The access floor is **profile-invariant**: fewer lowerings is fewer copies to keep in parity, not
fewer guarantees.

## Quickstart — the standalone profile

```bash
make up      # postgres+pgvector, redis, litellm
make smoke   # a cited answer, with NO Qdrant and NO NATS bound
make ci      # lint, typecheck, unit, conformance, link check
```

`make smoke-assert-isolation` asserts the *negative* half of that claim — that no forbidden client
is installed, no forbidden service is in the topology, and no `QDRANT_*`/`NATS_*` config is present.
A smoke test passes just as green with a stray client quietly bound; that is the half that rots
silently, so it is checked mechanically.

## Repo layout

```
specs/001-agent-runtime/
├── spec.md  plan.md  research.md  data-model.md  tasks.md  quickstart.md
├── contracts/
│   ├── agent-graph.md        # state, nodes, checkpointing, streaming
│   ├── agent-runtime.md      # manifest + plugin, profiles, swap matrix
│   ├── mcp-tools.md          # the tool catalog + allowlist dispatch
│   ├── approval-ports.md     # human-in-the-loop gate
│   ├── agent-deps.md         # the AgentDeps port bundle  ← the boundary
│   ├── host-integration.md   # what a host MUST provide   ← the boundary
│   └── channels.md           # Discord / Slack / WeChat (port now, adapters Phase 2)
└── diagrams/
src/intel_agent/              # graph/ tools/ retrieval/ memory/ ports/ channels/ conformance/
prompts/  evals/  migrations/  tests/  deploy/
```

## Developing each side without the other

The split created a testing hole in both directions, and one mechanism closes both: a **versioned event vocabulary** plus **doubles the runtime ships** ([contracts/stream-events.md](specs/001-agent-runtime/contracts/stream-events.md)).

**A host has a UI and a transport but no agent** — so it imports one:

```python
from intel_agent.testing import FakeAgentRuntime, scenarios

graph = FakeAgentRuntime(scenarios.GATE_PAUSE_RESUME)   # no model, no store, no network
```

Scenarios cover a cited answer, refusal, clarification, a human gate pausing and resuming, a degraded rerank, a deadline deferral, and an error. The double ships **here**, not in the host, so it cannot become a second unversioned definition of the vocabulary — and golden JSONL fixtures let both repos assert against the *same files*.

**This repo has an agent but no UI** — so it has two dev harnesses, both dev-only and never packaged:

| | For |
|---|---|
| `make dev` | streaming CLI REPL — the default loop: fast, scriptable, CI-friendly |
| `make dev-ui` | one self-contained SSE page — token streaming, the debug panel, a real approve/reject gate |

The page is a **reference consumer, not a product**: it renders only from the published vocabulary and calls no bespoke endpoint. If it ever needs a special case, the vocabulary is missing something — fix the vocabulary, not the page. It must never grow auth, persistence, or styling ambitions; a dev harness that becomes a second product surface re-creates the coupling this extraction removed.

## Chat platforms

Discord, Slack, and WeChat reach the runtime through the `Channel` port. The split:

| We own | You own |
|---|---|
| Protocol plumbing — connection, events, rate limits, chunking, streaming style | `IdentityBinder`: platform user → `(tenant, principal, claims)` |

Identity mapping stays yours because it *is* host obligation H1, and a wrong answer there is a privilege escalation. An unrecognized user is **refused**, never given a default identity — on a public Discord guild, unrecognized is the normal case.

Capabilities are **declared data**, not subclasses, because the platforms genuinely differ:

| | Discord | Slack | WeChat |
|---|---|---|---|
| Streaming | via message edit | via `chat.update` | **none** |
| Reply deadline | — | — | **~5 s** |
| Max message | 2,000 chars | ~3,000 | 2,048 bytes |

WeChat is why the model is data: an adapter layer built around Discord and later "extended" to WeChat works in testing and fails on any query slower than five seconds. The runtime buffers for non-streaming channels and **defers** rather than truncating when a deadline is hit.

Adapters install as extras — `intel-agent[discord]`, `intel-agent[slack,wechat]`. A platform SDK is never a base dependency. See [contracts/channels.md](specs/001-agent-runtime/contracts/channels.md).

## Integrating it into a host

A host installs the package, implements the ports, and passes the conformance suites:

```toml
# host pyproject.toml
dependencies = ["intel-agent @ git+https://github.com/truongpx396/intel-agent@v0.1.0"]
```

```python
# host tests — contract drift fails a build, not a review
from intel_agent.conformance import RetrievalServiceContract, PolicyContract

class TestHostRetrieval(RetrievalServiceContract):
    impl = MyRetrievalService
```

`intel_agent.conformance` is **public API** and is versioned as such. A change to a port protocol or
to [`host-integration.md`](specs/001-agent-runtime/contracts/host-integration.md) is a breaking
change for every host: it bumps at least the minor version and lands *before* the host PR that
consumes it.

**What does not travel with the runtime** — and must be re-satisfied by the host: credit metering,
the RLS GUC plumbing, and the moderation provider behind `guard`. The runtime declares *that* these
run; it never implements *how* a host bills or authenticates.

## Relationship to aisat-intel

| | intel-agent | aisat-intel |
|---|---|---|
| Owns | the **port** | the **implementation** and the deployment |
| Examples | `RetrievalService`, `ToolRegistry`, `Policy` protocol, `Meter` | Qdrant hybrid search, its own tool bodies, its clearance `Policy`, the sole credit-ledger writer |

That single rule resolves every ownership question at the seam. Engineering principles I–VI, IX,
and X in [the constitution](.specify/memory/constitution.md) are shared **verbatim** with
aisat-intel and are amended there first — a local-only edit to a shared principle is a defect.

## License

Proprietary. All rights reserved.
