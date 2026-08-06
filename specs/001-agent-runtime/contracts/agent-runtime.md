# Contract: Self-Contained Agent Runtime (manifest + domain-plugin seam)

**Plan**: [../plan.md](../plan.md) | **Graph internals**: [agent-graph.md](./agent-graph.md) | **Access model**: [authorizer-ports.md](./authorizer-ports.md) | **Status**: The **composition/deployment** contract for the agent tier. It defines a **first-class, conformance-tested self-contained profile** — the one LangGraph runtime run as a config-first agent that adapts to a new domain by swapping a **manifest** (config) plus a thin **domain plugin** (code), on a swappable set of backing services, without forking the graph.

**Two axes, deliberately independent — read this before the no-behavior-change reflex:**

- **Alignment axis (unchanged default).** The AISAT Phase-1 deployment — Go kernel + Python tier + Qdrant + NATS JetStream + Redis + Postgres — is the *reference profile* and is **not altered** by this contract. The phrase 'changes no Phase-1 behavior' applies **only** to that default profile: nothing here rewires how AISAT itself ships.
- **Capability axis (first-class, tested).** 'Runs self-contained in another system' is a **supported deployment profile**, not an aspirational seam. It is **proven by conformance tests** (second-domain reuse + the backing-service swap matrix below), exactly as `PricerContract` *proves* the metering-reuse claim instead of asserting it. The AISAT default is **one point** in this profile space, not the only shape the runtime can take.

The two do not trade off: the default stays byte-identical *because* every reuse point is a named port with a swap test, so exercising a different profile can never regress the reference one. This is the counterpart to the internal [agent-graph.md](./agent-graph.md) `AgentDeps`/`SecurityCtx` seam and the [authorizer-ports.md](./authorizer-ports.md) `Policy` seam: those say *the graph is extractable*; this says *how a whole agent is composed, deployed, and proven runnable elsewhere*. It is explicitly informed by config-driven agent gateways (GoClaw/OpenClaw — 'agent = identity + tools + provider + context files'), adopting their config-first ergonomics **without** adopting their coarser trust model.

> **The load-bearing rule.** Everything the runtime *reads* is **config**; the only per-domain **code** is (1) the tool bodies and (2) the `Authorizer` `Policy`. Config may *select* a policy; it may never *be* one. The data-layer authorization floor (row-level pre-filter, SC-001 release blocker) is enforced **below** the agent and is identical for every profile — a manifest can narrow what an agent may do, never widen what a principal may see. On the AISAT profile that floor is Postgres RLS + Qdrant payload pre-filter; on a single-store profile it collapses to Postgres RLS alone (see the swap matrix), which is *fewer* copies of the predicate, not fewer guarantees.

---

## Why: what "self-contained + domain-adaptable + scalable" means here

| Goal | Mechanism (all already present in Phase 1) | This contract adds |
|------|--------------------------------------------|--------------------|
| **Self-contained** | One `StateGraph`, two compiled forms; `AgentDeps` DI at the entrypoint; transport-agnostic streaming ([agent-graph.md](./agent-graph.md)) | A single **`AgentManifest`** that fully describes an agent, so "run an agent" = "load a manifest + bind a plugin" |
| **Domain-adaptable** | `ToolRegistry` (one impl, two exposures), `RetrievalService`, swappable `Policy`, opaque `ctx.claims` | A named **`DomainPlugin`** boundary: the *only* two code interfaces a new domain implements |
| **Highly scalable** | JetStream durable pull consumers + per-subject queue groups; stateless workers; Redis checkpointer; SSE relay as a separable tier (plan.md scale-forward seams §14–§15) | The invariant that a manifest is **per-run state, never per-worker state** — so "one self-contained agent" and "N horizontally-scaled workers" are the *same image* at different replica counts |

**Self-contained ≠ single-instance.** The runtime is a stateless worker: the manifest is loaded per run from its backing row, graph state lives in the checkpointer, and scaling is nothing but more queue-group replicas of the same binary. There is no per-domain deploy pipeline and no per-domain fork of the graph.

---

## Borrowed from GoClaw — and deliberately not

| Borrow (config-first ergonomics) | How it lands here |
|---|---|
| **Agent-as-config record** (identity + tools + provider + context files) | `AgentManifest`, persisted as the existing `agent_policies` row extended additively ([data-model.md](../data-model.md)) |
| **Provider/model registry as config** | Already the LLM gateway aliases (`fast`/`smart`/`embed`/`rerank`, [llm-gateway.md](./llm-gateway.md)); the manifest only *names* aliases |
| **Tools/skills as a plugin catalog** (MCP registration) | The manifest's `allowed_tools[]` selects from the `ToolRegistry` / MCP server ([mcp-tools.md](./mcp-tools.md)); a new tool is a registered impl, not a graph edit |
| **Channels as adapters** (Telegram/Slack/web/…) | New `StreamWriter`/transport adapters behind the already-decoupled streaming seam ([agent-graph.md](./agent-graph.md) Streaming); the graph is unchanged |
| **Single self-contained deployable** | One worker image, manifest-driven — matches the `cmd/worker` stateless role (plan.md) |

| Deliberately **not** borrowed | Why |
|---|---|
| **Authorization enforced *around the tool* (RBAC/permission layers)** | Would silently downgrade the SC-001 guarantee. Isolation stays **below** the agent at row granularity (RLS + Qdrant pre-filter); the manifest never becomes the access boundary |
| **Broad `exec`/filesystem/write tool surface by default** | Phase 1 is read-mostly + two HITL-gated actions ([mcp-tools.md](./mcp-tools.md) Category D). New power tools are added deliberately behind the sandbox + human-gate, not imported wholesale |

---

## The two layers

### 1. `AgentManifest` — config (declarative, no code)

The complete, portable description of one agent. Everything here is data the runtime *reads*; nothing here is behavior.

```yaml
# an agent = one manifest row (backed by agent_policies, extended additively)
id:            aisat-default
tenant:        <workspace_id>                 # opaque; the runtime never interprets it
agent_role:    user                           # label the allowed_tools allowlist is keyed on
prompts:                                       # refs into prompt assets (T074), never inline secrets
  system:      prompts/response_format
  rewrite:     prompts/query_rewrite
allowed_tools: [search_workspace_knowledge, search_personal_knowledge, get_document_by_id, list_documents]
models:        { fast: <alias>, smart: <alias> }   # names gateway aliases only (llm-gateway.md)
retrieval:     { kind: qdrant, collections: [personal, workspace] }   # binds a RetrievalService (kind: pgvector for Profile B)
memory:        { kind: mem0 }                  # or { kind: none } — memory degrades cleanly
bus:           { kind: jetstream }             # kind: redis_streams | inprocess for the self-contained profile
mcp_servers:   []                              # external MCP tool sources to mount
channels:      [web_sse]                       # transport adapters to attach
budgets:       { token_budget_day: <int>, max_loop_depth: 20, credits_cap: <int> }
policy:        single_axis                     # ← SELECTS a Policy impl; is NOT the policy
can_write:     false
write_ops:     [note_update]
hooks_enabled: [audit, langfuse]
```

- The manifest **selects** implementations by name (`retrieval.kind`, `policy`, `models.*`); it does not contain them.
- `policy: single_axis` names a `DomainPlugin`-provided `Authorizer` `Policy` ([authorizer-ports.md](./authorizer-ports.md)). Swapping to `per_customer` / `role_x_course` is a manifest edit **plus** a registered policy impl — never a manifest-only widening.
- A different product ships a different manifest (`prompts`, `allowed_tools`, `retrieval`, `channels`, `policy`) and its own plugin; the graph binary is byte-identical.

### 2. `DomainPlugin` — code (exactly two interfaces)

The *only* code a new domain writes. Registered once at the app root (mirroring `SetupModule` / the graph entrypoint DI).

```go
// Go kernel side (authorization is a kernel concern; authorizer-ports.md)
type DomainPlugin interface {
    // 1. the domain tools — bodies behind the shared policy wrapper (allowlist + audit + RLS GUCs)
    Tools() ToolRegistry
    // 2. the access model — a pure Policy the generic Authorizer orchestrates
    Policy() authz.Policy
}
```

```python
# Python runtime side — the plugin supplies the deps the manifest named
class DomainPlugin(Protocol):
    def tools(self) -> ToolRegistry: ...          # domain tool impls (in-process + MCP)
    def retrieval(self, cfg) -> RetrievalService: ...   # binds the manifest's retrieval.kind
    # memory / llm / stream are generic; supplied by the runtime unless overridden
```

Everything else the [agent-graph.md](./agent-graph.md) Extraction checklist lists (`MemoryService`, `LLMGatewayClient`, `StreamWriter`, checkpointer, stream adapter) is **generic runtime** — provided once, reused by every domain.

---

## Composition flow

```
AgentManifest (config)  ──selects──►  DomainPlugin (code: Tools + Policy)  +  generic runtime deps
        │                                        │
        └──────────────► graph entrypoint assembles AgentDeps once per worker ──► one StateGraph, unchanged
                                                 │
                                    per run: ctx (tenant/principal/claims) stamped by trusted layer
                                                 │
                              RLS + Qdrant pre-filter enforce SC-001 BELOW the graph, every manifest
```

The manifest is resolved to `AgentDeps` at the graph entrypoint (`routers/query.py`), exactly where DI already happens — no node is aware a manifest exists.

---

## Backing-service swap matrix

What a self-contained deployment may swap, and *how much* it costs to swap — the honest truth by tier (config = env only; port backend = a config-selected backend/adapter of an existing port, gated by a conformance test). Every row keeps the SC-001 floor; none is a manifest-only widening.

| Backing service | AISAT default | Swap to | Cost of the swap | Mechanism |
|---|---|---|---|---|
| **LLM gateway** | LiteLLM (self-hosted) | any OpenAI-wire endpoint (LiteLLM/Bifrost/direct) | **config** | `LLMGatewayClient` base-URL; the manifest only *names* aliases ([llm-gateway.md](./llm-gateway.md)) |
| **Observability** | Langfuse + OTel | Langfuse endpoint, or none | **config** | OTel exporter env; tracing degrades cleanly if unset — no node depends on it |
| **Vector store (endpoint)** | Qdrant (managed/self-hosted) | any Qdrant endpoint | **config** | `RetrievalService` (Qdrant impl) endpoint env |
| **Vector store (engine)** | Qdrant | **Postgres + pgvector** (single-store) | **port backend** — the existing `RetrievalService` port with a **pgvector backend** selected by `retrieval.kind` (`qdrant`\|`pgvector`); no new service class | collapses the visibility predicate to **one** lowering (RLS-native) instead of the RLS+Qdrant parity pair — *simpler* floor. Caveat: Qdrant's native hybrid (BM25+dense+RRF) must be reproduced with `pgvector` + a lexical companion (`tsvector`/ParadeDB) to hold **retrieval quality** — the authz floor is easier, retrieval-quality parity is the work ([authorizer-ports.md](./authorizer-ports.md) `Lowerer`) |
| **Async bus** | NATS JetStream | **Redis Streams**, or **in-process** (no bus) | **port backend** — the `Bus` port with `jetstream` / `redis_streams` / `inprocess` adapters selected by `bus.kind`; **or** free by collapsing worker roles into direct calls | JetStream primitives (durable pull consumers, DLQ redelivery, lag-autoscale) are named in [nats-subjects.md](./nats-subjects.md); the `Bus` port fronts `publish/subscribe/queue-group/redeliver` so Redis-Streams (`XADD`/consumer-groups/`XCLAIM`) or an in-proc executor satisfy the same semantics. A minimal single-container agent needs **no** bus — the worker roles run as in-process function calls; the bus earns its keep only when scaling out |
| **Checkpointer** | Redis (`RedisSaver`) | Postgres / SQLite `BaseCheckpointSaver` | **config** | any LangGraph checkpointer; the durable form is checkpointer-agnostic ([agent-graph.md](./agent-graph.md)) |
| **Tool source** | in-process shared-library (`ToolRegistry`) | a **remote** domain MCP server (config-only agent) | **port backend** — the `ToolRegistry` port with `inprocess` / `mcp_client` bindings selected by `tools.kind` | `inprocess` calls the shared tool library directly (enforcement in the shared wrapper); `mcp_client` points the *unmodified* graph at a remote MCP `url` + device PAT, delegating enforcement to that server's **own boundary** (RLS GUCs from the PAT, allowlist, audit — [mcp-tools.md](./mcp-tools.md)). Lets a thin agent adapt to a domain by **config alone** when a compliant domain server exists; the config selects a tool *source*, never the access floor (conformance: T060g) |
| **Object store** | S3 | any S3-compatible (MinIO) | **config** | ingestion staging only; not on the agent read path |

Two named, supported shapes. Both run the *same* graph binary and the *same* manifest schema; they differ only in which backing services and which runtimes are present. Neither is a fork.

### Profile A — AISAT reference (the unchanged default)

**Go kernel + Python agent tier + Qdrant + JetStream + Redis + Postgres + LiteLLM + Langfuse.** The full product. The Go kernel is mandatory here for the three concerns deliberately kept out of Python — the **single `credit_ledger` writer** (SC-006), **auth/session**, and the **RLS-GUC tenant middleware**. This is Phase 1 exactly as specified; this contract adds nothing to it.

### Profile B — self-contained single-domain agent (the extraction target)

**One Python container (agent + optional in-process worker roles) + Postgres/pgvector + Redis + LiteLLM + Langfuse.** The [Extraction checklist](./agent-graph.md#extraction-checklist) profile made concrete: the async bus collapses to in-process calls (or Redis Streams via the `Bus` port when scale-out is wanted), retrieval binds the `RetrievalService` **pgvector backend** (`retrieval.kind: pgvector`) so **one Postgres is both the store and the SC-001 floor** (RLS), and metering/auth become **host concerns the embedding system re-satisfies** (the graph declares *that* they run via `guard` + the tool-policy wrapper, not *how* the host bills or authenticates). This is the OpenClaw/GoClaw-style 'single deployable' shape — with the row-level authorization floor kept intact rather than downgraded to tool-boundary RBAC.

**The one boundary that does not move:** authorization is still enforced *below* the agent (RLS in that same Postgres), never around the tool. Profile B drops the *transport and vector engine*, never the access floor. An embedding host that wants AISAT's money/auth guarantees adds the Go kernel back and is simply on Profile A — the profiles are a **superset relation, not a fork**.

---

## Backing store

The `AgentManifest` is **not** a new table. It is the existing `agent_policies` row ([data-model.md](../data-model.md)) read as a manifest and extended **additively** (prompt refs, `models`, `retrieval`, `mcp_servers`, `channels`) — the same fields the graph and MCP dispatch already consult (`allowed_tools`, `can_write`, `write_ops`, budgets, `hooks_enabled`). No new isolation unit, no schema fork.

---

## Invariants

1. **Config selects, code enforces.** A manifest may name a `policy`; it can never *be* one. The `Authorizer` `Policy` and RLS/Qdrant lowerings are the enforcement floor for every manifest ([authorizer-ports.md](./authorizer-ports.md)).
2. **A manifest narrows, never widens.** `allowed_tools`, `can_write`, and budgets can only *restrict* an agent within what the principal's clearance already permits. No manifest field raises what a `principal` may see — that is `ctx.claims` + the `Policy`, stamped by the trusted layer, never the manifest.
3. **Manifest is per-run, not per-worker.** Loaded from the row at run start; workers hold no manifest state, so any worker can serve any tenant's run and scaling is replica count alone (plan.md stateless-worker + JetStream seams).
4. **Graph is manifest-blind.** No node reads the manifest; it only sees `AgentDeps` + `ctx`. Adding a domain changes deps and config, never a node (parity with the [agent-graph.md](./agent-graph.md) Extraction checklist).
5. **One image, N domains.** The runtime binary is identical across domains and across replica counts; a domain is manifest + plugin, a scale-out is `replicas++`.
6. **Profiles are a superset, never a fork.** Profile B (self-contained) and Profile A (full AISAT) run the *same* graph binary and manifest schema; A is B plus the Go kernel (billing/auth/RLS-middleware) and the Qdrant+JetStream backing services. Swapping a backing service is a port impl or a config value — never a source fork of the graph or the nodes.
7. **The access floor is profile-invariant.** Every profile enforces visibility *below* the agent at row granularity. Profile A lowers the predicate to RLS **and** the Qdrant filter; Profile B lowers it to RLS alone. Fewer lowerings is fewer copies to keep in parity, not fewer guarantees — SC-001 holds identically on both.

---

## Contract test obligations

- **Second-domain reuse** (the load-bearing proof): a **test-only** `DomainPlugin` (e.g. a `support-bot` fixture with tools `get_ticket`/`search_kb` and a `per_customer` `Policy`) plus its manifest runs the *unmodified* graph green end-to-end — same discipline as the `PricerContract`/`HashChainContract` "prove reuse with a second fixture" tests, extended to the whole runtime.
- **Authz floor holds regardless of manifest**: a manifest that lists a tool cannot return data the `Policy`/RLS would deny; a crafted manifest with a broader `allowed_tools` never surfaces a row above the principal's clearance (SC-001 is a deps/RLS property, not a manifest property).
- **Manifest-load determinism**: two runs with the same `agent_policies` row resolve to the same `AgentDeps` wiring; a missing/invalid manifest field fails **closed** at load (no partial-permission agent).
- **Manifest is per-run**: two concurrent runs for different tenants on the *same* worker never share manifest-derived state (no worker-global manifest cache keyed off the first run).
- **Channel-adapter swap**: attaching a second `channels` adapter (e.g. a non-SSE transport) changes no node and no graph output on a golden query (parity with the streaming-decoupling test).
- **Backing-service swap proves the profile, not just the seam**: the graph runs green end-to-end under a **Profile-B wiring** — the `RetrievalService` **pgvector backend** standing in for the Qdrant backend **and** an in-process (no-bus) executor standing in for JetStream — producing a cited answer on a golden query with **no Qdrant and no NATS client bound** (the same 'prove reuse with a second fixture' discipline as `PricerContract`, now applied to the *deployment* seam). This is the test that makes 'runs self-contained' a checked capability rather than a claim.
- **Access floor is profile-invariant**: the SC-001 access-correctness suite passes **unchanged** under the Profile-B (RLS-only) wiring — a cross-clearance / cross-tenant row is a `not_found`, never surfaced — proving the floor is a property of the lowering, not of Qdrant's presence.

---

## Phase boundary

Phase 1 **ships and operates Profile A** (the AISAT reference) as the production deployment, with exactly **one** manifest (backed by `agent_policies`) and **one** `DomainPlugin` (the AISAT tools + `SingleAxisPolicy`). Profile B is a **first-class supported profile that is built *and made runnable* in Phase 1** — all three build items land as Phase-1 tasks: (1) the `RetrievalService` **pgvector backend** with hybrid-search quality parity — dense (pgvector HNSW) + a lexical companion (`tsvector`/ParadeDB) + RRF (tasks T034a/T065a); (2) the **`Bus` port** binding (`jetstream` / `redis_streams` / `inprocess`) that lets the worker roles run without JetStream (task T029a); and (3) a **Profile-B entrypoint** that re-satisfies, inside the single container, the two kernel concerns the Go tier provides in Profile A — setting the RLS GUCs (`app.workspace_id`/`app.user_id`/`app.clearance`) per request and running the `guard` + tool-policy + metering wrappers (tasks T060e/T060f, with a live single-container smoke). The swap test (T060d) binds the **production** pgvector backend + in-process bus, not fixtures, and the smoke (T060f) proves the deployed shape runs cited answers with **no Qdrant and no NATS**. What remains Phase 2+ is multi-domain **hosting** (a manifest registry, per-manifest routing, a plugin loader) ([draft-plan.md](../../draft-plan.md)) and *operating* Profile B as a production deployment — the capability is built, runnable, and CI-smoked in Phase 1 so it can never silently rot; alignment with the reference profile is preserved throughout because both profiles are the same binary behind the same ports.
