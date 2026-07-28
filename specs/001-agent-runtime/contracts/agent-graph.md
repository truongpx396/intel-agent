# Contract: LangGraph Agent — State, Nodes, Checkpointing & Streaming

**Plan**: [../plan.md](../plan.md) | The internal contract for the built-in RAG agent (`backend-python/src/services/agent/graph.py`). This is the counterpart to the external contracts ([bff-rest.md](./bff-rest.md), [nats-subjects.md](./nats-subjects.md), [mcp-tools.md](./mcp-tools.md), [sse-events.md](./sse-events.md), [llm-gateway.md](./llm-gateway.md)): it declares the **one boundary that lives entirely inside the Python tier** — the graph's shared state, each node's read/write keys, how nodes receive their dependencies, how state is checkpointed and resumed, and how tokens are streamed out. It exists so the "additive node, no refactor" claims (research §17, §22; note-enrichment §Phase-2) are *verifiable against a written state schema*, and so the graph can be reasoned about, tested per-node, and extracted as a standalone service (see [Extraction checklist](#extraction-checklist)).

## Design thesis: one graph, two compiled forms

There is **one** `StateGraph` definition. The interactive query path and the durable `long_horizon` path are the **same topology compiled two ways** — they never fork into two graphs:

| | Interactive (`intent ∈ {semantic, structured}`) | Durable (`intent = long_horizon`) |
|---|---|---|
| Compiled with | no persistent checkpointer (ephemeral in-memory) | Redis checkpointer (`RedisSaver`, AOF) |
| `agent_run` row | none | one row (SC-009, [data-model.md](../data-model.md) Long-Horizon Task Run) |
| Iteration | single forward pass | **bounded** iterative re-entry, checkpoint after every node, `credits_cap`-governed |
| Human-gate (Phase 1) | disabled (no durable approval home) | **enabled** — `human_gate` may `interrupt()` before an index-mutating / outward-reaching step, `status='paused'` (FR-040, [approval-ports.md](./approval-ports.md)) |
| Correction loop (Phase 2) | disabled | enabled, depth-capped |
| Heartbeat / janitor | n/a | every 10s + stale-heartbeat re-queue (research §15) |

This is the idiomatic LangGraph pattern (`graph.compile()` vs `graph.compile(checkpointer=…)`) and is what keeps the graph *composable*: a new node is added to the single definition and both forms inherit it. **Phase 1 long-horizon is bounded, checkpointed re-entry of the existing retrieval/generation nodes — not a planner/executor.** A planner/executor decomposition is a Phase-2 seam ([below](#phase-2-additive-seams)); it does not exist in Phase 1, and the durability machinery (checkpoint, heartbeat, cap) is meaningful without it because a long-horizon run may traverse retrieve→generate several times under the cap.

## Node identity

Nodes have **stable names** as their canonical identity. The legacy numeric labels (from the [langgraph-rag-agent](../diagrams/langgraph-rag-agent.excalidraw) diagram and older prose) are retained only as aliases for the heavily-referenced security anchors (`guard`/Node 0, `memory`/Node 5). New nodes are added **by name**; numbers are not extended.

| Name | Legacy # | Responsibility | Reads from state | Writes to state |
|------|----------|----------------|------------------|-----------------|
| `guard` | Node 0 | Moderation + injection screen + per-role `allowed_tools` gate. Fail-closed. Short-circuits before any retrieval/spend (research §5, SC-007). | `query`, `ctx` | `blocked`, `block_reason` |
| `route` | *(was folded into Node 1)* | **Intent classification** → `intent ∈ {semantic, structured, long_horizon}` **and model-tier alias** (`fast`/`smart`). Runs **exactly once** per run; its output is immutable (the correction loop never re-runs it). Phase-2 complexity router extends *this* node (research §22). | `query`, `ctx`, `history` | `intent`, `model_alias` |
| `rewrite` | Node 1 | History-aware query rewrite/expansion (BAML). Semantic path only; for `structured` it is a light normalization pass. | `query`, `history`, `intent` | `rewritten_query` |
| `retrieve` | Node 2 | **Branches on `intent`.** `semantic` → two parallel Qdrant searches (`personal` owner-filter + `workspace` clearance-filter), RRF-interleaved. `structured` → fixed parameterized tool (`query_employees`/`projects`/`metrics`). Emits `tool_use`/`tool_result`, writes `agent_audit_log`. | `rewritten_query`, `intent`, `ctx` | `candidates`, `tool_calls`, `debug.retrieval` |
| `rerank` | Node 3 | Cross-encoder rerank (`rerank` alias) over the merged candidate set; selects top-k. | `candidates` | `ranked`, `debug.rerank` |
| `assemble` | Node 4 | Child→parent expansion (`parent_doc_id`), dedupe, trim to token budget. Deterministic, no external call. | `ranked` | `context`, `source_count`, `debug.assembly` |
| `memory` | Node 5 | Mem0 per-user injection, **clearance-filtered at read time** (research §13, SC-001). Additive: never fails the run. | `context`, `ctx` | `memories` |
| `generate` | Node 6 | LLM generation via gateway with inline citations over `<retrieved_document>`-delimited context. Emits `token` deltas on the stream channel (**not** Redis directly — see [Streaming](#streaming)). | `context`, `memories`, `query`, `model_alias` | `answer`, `citations`, `usage` |
| `suggest` | *(was "Node 7")* | Post-generate: 2–3 clearance-scoped follow-up chips (FR-031). Suppressed when `source_count == 0` or the answer was refused. Never fails the run. | `answer`, `context`, `ctx` | `suggestions` |

> **Resolves the "Node 7" overload.** The single "Node 7" that previously meant *suggestions* (Phase 1), a *pre-generation groundedness gate* (research §17), **and** a *post-generation grade/reflect loop* (diagram) is now three distinctly-named things: the Phase-1 `suggest` node, and the Phase-2 `grade_retrieval` / `grade_answer` nodes with fixed insertion positions ([below](#phase-2-additive-seams)). No node is identified by the number 7.

Phase-1 edge order (semantic path):
`START → guard → route → rewrite → retrieve → rerank → assemble → memory → generate → suggest → END`
`guard` blocked ⇒ `START → guard → END` (single `error`, no spend). `structured` intent ⇒ `rewrite` normalizes, `retrieve` calls a fixed tool instead of vector search. `route` is the only conditional-branch source in Phase 1.

## AgentState schema

The single source of truth for what flows through the graph. Additive by construction: a new node adds keys; it never changes the meaning of an existing key. `ctx` (the security context) is **stamped by the BFF into the NATS payload and set read-only** — no node may widen clearance or re-derive identity from tool output (research §5).

```python
from typing import Annotated, Literal, TypedDict
from operator import add

class SecurityCtx(TypedDict):        # set once from the NATS payload; never mutated by a node
    workspace_id: str
    user_id: str
    effective_access_level: int      # requester's CURRENT clearance, evaluated at read time
    agent_role: Literal["user", "admin", "automation", "integration"]
    allowed_tools: list[str]         # read from agent_policies; never hardcoded (research §19)
    trace_id: str
    stream_id: str                   # streaming key; the graph never touches Redis with it (see Streaming)

class AgentState(TypedDict, total=False):
    # --- inputs (read-only after START) ---
    query: str
    history: list[dict]              # prior turns for history-aware rewrite (FR-009)
    ctx: SecurityCtx

    # --- guard ---
    blocked: bool
    block_reason: Literal["injection_blocked", "disallowed"] | None

    # --- route (written ONCE; immutable thereafter) ---
    intent: Literal["semantic", "structured", "long_horizon"]
    model_alias: Literal["fast", "smart"]

    # --- rewrite / retrieve / rerank / assemble ---
    rewritten_query: str
    candidates: list[dict]           # merged personal+workspace, pre-rerank
    tool_calls: Annotated[list[dict], add]   # append-only audit of tool invocations
    ranked: list[dict]
    context: list[dict]              # parent chunks sent to the LLM
    source_count: int

    # --- memory / generate / suggest ---
    memories: list[dict]
    answer: str
    citations: list[dict]
    usage: dict                      # {input_tokens, output_tokens} — drives billing.deduct
    suggestions: list[str]

    # --- long_horizon control (Phase 1) + correction loop (Phase 2) ---
    step: int                        # monotonic; checkpoint boundary index
    correction_count: int            # Phase-2 loop guard; ≤ agent_policies.max_loop_depth

    # --- human-in-the-loop (Phase 1, durable form only) ---
    pending_approval: dict | None    # {kind, subject, prompt, payload} set by the step to be gated; consumed by human_gate
    approval_decision: dict | None   # {verdict, resume_value, resolved_by} — HUMAN-authored, injected by Command(resume); NEVER from tool output

    # --- agent actions (Phase 1, durable form only; FR-041) ---
    needs_web: bool                  # web_search_decide → true when internal context is insufficient/time-sensitive
    web_results: list[dict]          # distilled web_search results, populated only AFTER the per-fetch approval

    # --- observability (SC-005) ---
    debug: dict                      # per-node trace fragments → DebugTrace (sse-events.md)
```

**Reducer semantics.** Only `tool_calls` uses a non-default reducer (`operator.add`, append-only) because a long-horizon run accrues tool calls across re-entries and none may be lost for audit (FR-023). Every other key uses last-writer-wins (the default): each key has exactly one owning node, so there is no write contention. `intent`/`model_alias` are written only by `route` and are treated as immutable — enforced by convention and a unit test, not by a reducer.

## Dependency injection

Nodes are **pure functions of `(state, config)`** — they never import a concrete client at module scope. Services (retrieval, memory, the gateway client, tool implementations, the stream writer) are injected through LangGraph's `RunnableConfig["configurable"]`, assembled once at the graph's entrypoint (`routers/query.py`), mirroring the Go rule that wiring happens only at the app root (`SetupModule`).

```python
class AgentDeps(TypedDict):          # built once per worker, passed via config["configurable"]["deps"]
    retrieval: RetrievalService
    memory: MemoryService
    llm: LLMGatewayClient            # services/llm_gateway.py (the swap seam)
    tools: ToolRegistry              # in-process tool impls (see Tool access)
    emit: StreamWriter               # transport-agnostic; adapter maps it to Redis (see Streaming)

def node_retrieve(state: AgentState, config: RunnableConfig) -> dict:
    deps = config["configurable"]["deps"]
    ...                              # returns ONLY the keys this node owns
    return {"candidates": merged, "debug": {"retrieval": frag}}
```

This makes every node unit-testable with fake `deps` and no running infra, and it is what lets the graph be lifted into another host (the host supplies its own `AgentDeps`).

## Checkpointing & resumption

- **The Redis checkpointer (`RedisSaver`, AOF) is authoritative for graph state.** It is keyed by `thread_id` (= the run's `stream_id` for interactive, `agent_run.id` for durable), plus `checkpoint_ns` / `checkpoint_id`. A checkpoint is written after every node (LangGraph default), so a crash resumes at the last completed node boundary.
- **`agent_run.state JSONB` is a *pointer*, not the state.** It holds `{ thread_id, checkpoint_ns, checkpoint_id, node: <last completed node name>, step }` plus resume metadata — the durable index (survives a full Redis flush) that lets the worker/janitor **locate** the authoritative Redis checkpoint. It is never the resume payload itself. This resolves the two-store ambiguity in [data-model.md](../data-model.md) Long-Horizon Task Run.
- **Resume flow.** The stale-heartbeat janitor conditionally re-queues (`UPDATE agent_run SET status='queued' WHERE id=$1 AND status='running' AND last_heartbeat_at < $2 RETURNING id`, research §15). A worker claiming the re-queued run reads `agent_run.state.thread_id`, loads the latest Redis checkpoint for that thread, and continues from `state.node`.
- **Checkpoint loss is explicit, never silent.** If the pointer exists but the Redis checkpoint is gone (AOF gap / failover before persist), the run transitions to `failed` with `error='checkpoint_lost'` — it does **not** restart from scratch, because a restart would re-spend credits already settled (SC-006/SC-009). Interactive runs carry no `agent_run` row and are simply re-dispatched by JetStream redelivery (a lost interactive checkpoint is cosmetic).

## Human-in-the-loop: the `human_gate` node (durable form)

The idiomatic LangGraph HITL primitive — **`interrupt()` + `Command(resume=…)`** — is built into the single `StateGraph` in Phase 1 and is the mechanism behind FR-040 and the reusable [approval-ports.md](./approval-ports.md) `HumanGate`. It exists **only in the durable (`long_horizon`) compiled form** because a pause must be recoverable; the interactive form has no durable approval home and disables it, so an interactive query can never silently pause.

| Name | Responsibility | Reads from state | Writes to state |
|------|----------------|------------------|-----------------|
| `human_gate` | Guards an index-mutating / sensitivity-raising / outward-reaching step. Opens a durable `approval_request` via `deps.gate`, then `interrupt(payload)` — the run **checkpoints and yields**. On resume it honors the human `approval_decision`: proceed on `approve`/`edit`, or short-circuit (`blocked`, `block_reason='approval_rejected'`) on `reject`/expire. **Spends nothing while paused.** | `pending_approval`, `ctx` | `approval_decision`, `blocked`, `block_reason` |

```python
from langgraph.types import interrupt, Command

def node_human_gate(state: AgentState, config: RunnableConfig) -> dict:
    deps = config["configurable"]["deps"]
    handle = deps.gate.create(state["pending_approval"])   # durable approval_request(status='pending'); ZERO spend
    # NB: on resume LangGraph re-runs this node from the top up to interrupt(), so `create` executes
    #     twice → it MUST be idempotent and no spend/mutation may precede interrupt() (approval-ports.md "sharp edge")
    decision = interrupt({"approval_id": handle.id, **state["pending_approval"]})  # ← checkpoints + yields; status='paused'
    if decision["verdict"] == "reject":
        return {"approval_decision": decision, "blocked": True, "block_reason": "approval_rejected"}
    return {"approval_decision": decision}                 # approve/edit → next node proceeds past the gate
```

- **Suspend → resume flow.** `interrupt()` writes a checkpoint and returns control; the run's `agent_run.status` becomes `paused` and the BFF emits an `approval_request` SSE event ([sse-events.md](./sse-events.md)). Resolving via `POST /approvals/{id}/resolve` publishes `agent.resume.<ws>` ([nats-subjects.md](./nats-subjects.md)); the worker loads the paused thread's checkpoint (`agent_run.state.thread_id`) and resumes with `Command(resume=decision)`.
- **Exactly-once, no re-spend.** Resume re-enters *at* the gate checkpoint, so nodes settled before the gate are not re-run and their spend is never repeated (parity with the `checkpoint_lost` rule and SC-009). A redelivered `agent.resume.<ws>` or a second approve is a no-op — the thread is already past the gate.
- **Decision provenance.** `approval_decision` is injected by `Command(resume)` from the human's resolution — it is **never** derived from tool/document output (research §5, FR-011). This is why a poisoned page can at worst influence a *draft the human reviews*.
- **Phase-1 callers of the gate.** The durable form has two always-on state-changing/reach steps in Phase 1 (FR-041), each routing through `human_gate`:
  - **`web_search_decide`** — after `retrieve`, if internal context is insufficient/time-sensitive it sets `needs_web` and, per intended fetch, sets `pending_approval={kind:'web_search', …}` → `human_gate` → on approve, `web_search` runs the SSRF-guarded `web_distill` and writes `web_results`; on reject it proceeds without web. Available to `user`+`admin` (allowlist).
  - **`edit_note`** — when the agent proposes a note edit, it sets `pending_approval={kind:'note_edit', subject:{note_id}, payload:{proposed_body}}` → `human_gate` → on approve the write commits (note `body` updated + re-indexed) **only** after the Authorizer `Permit(ActionUpdate)` + `WriteEnvelope` pass with `Clearance=min(agent,owner)`; on reject the note is unchanged.
  A time-sensitive/reach query the `route` node judges to need the web is classified `long_horizon` so its gate can pause — the interactive form has neither action tool and never pauses. The other two Phase-1 gates (enrich accept, sensitivity confirm) run the same `HumanGate` port through its non-graph (async) shape. All of this is conformance-tested by `ApprovalContract` ([approval-ports.md](./approval-ports.md)).

## Streaming

The graph is **transport-agnostic**. Nodes emit incremental output through the injected `emit` (`StreamWriter`, backed by LangGraph `get_stream_writer()` / `stream_mode=["messages","custom"]`) — they **never** publish to Redis. Exactly one component, the **stream adapter** in `routers/query.py`, consumes the graph's event stream and republishes to Redis pub/sub keyed by `ctx.stream_id`; the Go SSE relay forwards it ([sse-events.md](./sse-events.md)).

```
graph.astream_events(...)  ─consumed by→  StreamAdapter  ─publishes→  Redis pub/sub[stream_id]  →  Go relay  →  SSE
     (inside Python tier, no Redis)              (the ONLY Redis-pub/sub caller)
```

Consequence: `generate` (Node 6) yields `token` deltas onto the stream channel; the "SSE" mapping is the adapter's job, not the node's. To run this graph under a different transport (WebSocket, gRPC stream, a test harness that just collects tokens), swap the adapter — the graph is unchanged. This is the decoupling that makes the agent extractable without dragging the Redis streaming convention with it.

## Per-node reliability policy

Retry/timeout/degradation is declared per node (LangGraph `RetryPolicy` + an explicit fallback). The governing principle: **retrieval and generation failures fail the run; enrichment nodes degrade and never fail the run.**

| Node | Retries | Timeout | On exhausted failure |
|------|---------|---------|----------------------|
| `guard` | 0 | 5s | **Fail-closed** — emit `error`, block, no spend (a moderation outage must not open the gate). |
| `route` | 1 | 5s | Default to `intent=semantic`, `model_alias=fast` (safe, retrieval-scoped). |
| `rewrite` | 1 | 8s | Degrade to the original `query` verbatim. |
| `retrieve` | 2 | 10s | **Fail the run** (`error='retrieval_unavailable'`). Empty result set is *not* a failure — proceeds with `source_count=0`. |
| `rerank` | 1 | 8s | Degrade to RRF order (skip rerank). Provider fallback (Cohere→local BGE) is handled in the gateway ([llm-gateway.md](./llm-gateway.md)). |
| `assemble` | 0 | — | Deterministic; a bug fails the run. |
| `memory` | 1 | 5s | Degrade to no memory injected. |
| `generate` | 1 **pre-first-token only** | 60s | Retry only before the first token is emitted; after streaming starts, do **not** retry (would double-bill/duplicate) — settle partial per [llm-gateway.md](./llm-gateway.md) cancellation rules and mark the run `failed`. |
| `suggest` | 0 | 8s | Omit `suggestions` (the answer already streamed). |
| `human_gate` | 0 | none (pauses indefinitely) | Durable form only. Not a failure mode — the run **parks** at a checkpoint (`status='paused'`) with zero spend until resolved; an unresolved gate is auto-expired to fail-closed (`approval.expire.tick`), which ends the run cleanly (`block_reason='approval_rejected'`), never proceeds. |

## Tool access (in-process impls, one MCP server)

The ten tools ([mcp-tools.md](./mcp-tools.md)) — eight read-only (Categories A–C) plus the two HITL-gated Category-D action tools (`web_search`, `edit_note`) — are **one set of implementations, exposed two ways**:

- The built-in graph calls the tool **implementations in-process** — direct Python function calls through the injected `ToolRegistry`, no MCP-protocol round-trip (research §19b, "in-process" = shared-library calls, not a client to `:8002`).
- The FastMCP server (`:8002`) wraps the **same** implementations and exposes them over the MCP protocol for external/local agents.

Both paths run every call through the **same policy wrapper** — `allowed_tools` allowlist check, `app.workspace_id`/`app.user_id`/`app.clearance` RLS GUCs set from the Actor, and the `agent_audit_log` write with `result_hash` — because that enforcement lives in the shared implementation, not the transport (research §19). "In-process MCP" therefore means *shared tool library*, and the built-in agent and an external agent get identical access and audit guarantees.

## Phase-2 additive seams

Each future node is added to the single `StateGraph` at a **fixed insertion position**, reading/writing only the keys named below — no existing node's contract changes.

| Seam | New node(s) | Inserted | State keys it adds | Rule |
|------|-------------|----------|--------------------|------|
| CRAG corrective grading (research §17) | `grade_retrieval` | **after `memory`, before `generate`** | `retrieval_grade`, `abstain` | On weak/empty context: one **bounded** reformulation loop back to `rewrite` **with `intent` pinned** (`route` never re-runs), `correction_count++` capped at `max_loop_depth`; or `abstain`. Re-derives only from `query` + pinned `intent` — **never** from tool/document output (research §5, §17). |
| Self-RAG faithfulness (research §17) | `grade_answer` | **after `generate`, before `suggest`** | `faithfulness`, `correction_count` | On unfaithful answer: one bounded regenerate under the same pin+cap rule. This is the node the old diagram drew as the post-generate "reflect" loop — now depth-bounded and intent-pinned. |
| Complexity-based model routing (research §22) | *(extends `route`)* | in-place | *(none — sets existing `model_alias`)* | A RouteLLM classifier inside `route` picks the alias from a complexity signal; stays app-side + observable, eval-gated. No new node. |

> **`web_search` is now Phase 1, not a seam.** The agent web-search (`web_search_decide` + `web_search` action) and the scoped `edit_note` write are **built in Phase 1** as the durable form's two HITL-gated action tools (FR-041; [Human-in-the-loop](#human-in-the-loop-the-human_gate-node-durable-form) above), no longer a Phase-2 addition. The remaining seams here (CRAG `grade_retrieval`, Self-RAG `grade_answer`, complexity routing) stay Phase 2.

The regenerate loops exist **only** in the `long_horizon` compiled form (the interactive form disables them), so an interactive query can never silently fan out into multiple LLM round-trips.

## Extraction checklist

To run this graph as a standalone microservice in another system, the host must provide (and *only*) these — the boundary is the `AgentDeps` struct plus the security contract, nothing else:

1. **Inputs**: an `AgentState` seed (`query`, `history`, `ctx`) — `ctx` stamped by the host's trusted layer, never the client (research §5).
2. **`AgentDeps`**: a `RetrievalService` (any vector store with the two-collection clearance-filter semantics), a `MemoryService` (or a no-op — `memory` degrades cleanly), an `LLMGatewayClient` (any OpenAI-wire endpoint), a `ToolRegistry`, and a `StreamWriter`.
3. **A checkpointer** for the durable form (`RedisSaver` or any LangGraph `BaseCheckpointSaver` — Postgres/SQLite work unchanged).
4. **A stream adapter** for the host's transport (the Redis-pub/sub one is AISAT-specific and stays behind the boundary).

What does **not** travel with the graph and must be re-satisfied by the host's own layers: credit metering (`billing.deduct`), the RLS GUC plumbing, and the moderation provider behind `guard`. These are enforcement concerns wired at the host root, exactly as they are here — the graph declares *that* they run (via `guard` and the tool policy wrapper), not *how* the host bills or authenticates.

## Contract test obligations

- **State immutability**: no node other than `route` writes `intent`/`model_alias`; a run's `intent` is identical at `generate` and at `route` (unit test over all nodes).
- **Additivity**: adding a Phase-2 node (a no-op `grade_retrieval` stub) changes no existing node's output on a golden query (regression test) — proves the seams.
- **Reducer**: `tool_calls` accumulates across a two-re-entry `long_horizon` run; a last-writer-wins key does not.
- **Node isolation**: each node runs green in a unit test with a fake `AgentDeps` and no infra (guard/route/rewrite/rerank/assemble/memory/generate/suggest).
- **Checkpoint pointer**: after a mid-run crash, `agent_run.state.thread_id` locates a Redis checkpoint whose `node` matches the last completed node; a missing checkpoint transitions the run to `failed('checkpoint_lost')`, never a silent restart (SC-006, SC-009).
- **Streaming decoupling**: `graph.astream_events` yields `token` events for a happy-path query with **no Redis client bound** (the adapter is absent in the test) — proving no node touches Redis.
- **Fail-closed guard**: a moderation-provider timeout blocks the query (`error`), spends zero credits (SC-007), and never proceeds to `retrieve`.
- **Reliability**: a `rerank` provider outage degrades to RRF order and still produces a cited answer; a `retrieve` outage fails the run; a `memory` outage produces an answer with `memories == []`.
- **In-process tool parity**: a tool call through the in-process `ToolRegistry` writes exactly one `agent_audit_log` row with a `result_hash`, identical to the same tool called via `:8002` (FR-023, research §19).
- **Human-gate interrupt/resume** (durable form): a `long_horizon` run reaching `human_gate` interrupts (checkpoints, `status='paused'`), spends **zero** credits while paused, and on `Command(resume=decision)` continues **exactly once** from the gate checkpoint (no settled node re-runs, no re-spend); a `reject` decision short-circuits with `block_reason='approval_rejected'` and never mutates the index; the `approval_decision` is the injected human value, never derived from tool output (FR-040, SC-014; the graph half of the `ApprovalContract`, [approval-ports.md](./approval-ports.md)).
- **Agent action tools** (durable form, FR-041): `web_search_decide` performs **no** fetch until the per-search gate is approved (a reject writes no `web_results` and spends nothing for the fetch); `edit_note` commits the note update **only** after approval **and** an Authorizer `Permit(ActionUpdate)`+`WriteEnvelope` pass with `Clearance=min(agent,owner)` — an edit above clearance / outside workspace is denied (`not_found`), one that would raise `access_level` above the source floor is denied (`envelope_widens`), and a create attempt is refused (SC-015). Neither tool exists in the interactive compiled form.

---

## Phase 2 (out of scope here)

> The four seams above are designed but not built in Phase 1. The **planner/executor decomposition** for genuinely multi-step long-horizon agents (beyond bounded re-entry of the RAG nodes) is a Phase-2+ decision ([draft-plan.md](../../draft-plan.md)); if long-horizon orchestration ever outgrows LangGraph, a durable-execution engine (Temporal/River) is the escalation, not a rewrite of these nodes (research §15 alternative (b)).
