<!-- Extracted from aisat-intel@369756e. Consolidates the port surface that was
     previously described in-line across agent-graph.md (Dependency injection,
     Extraction checklist), agent-runtime.md (swap matrix, DomainPlugin), and the
     host-side port contracts that stayed in aisat-intel. -->

# Contract: `AgentDeps` — the port surface

**Graph internals**: [agent-graph.md](./agent-graph.md) | **Composition**: [agent-runtime.md](./agent-runtime.md) | **Host obligations**: [host-integration.md](./host-integration.md) | **Status**: the **boundary**. This is the complete list of what the runtime needs from the outside world. If something is not on this page, the runtime does not need it and must not reach for it.

`AgentDeps` is assembled **once per worker** at the graph entrypoint and passed through LangGraph's `RunnableConfig["configurable"]["deps"]`. Nodes are pure functions of `(state, config)` and never import a concrete client at module scope ([agent-graph.md](./agent-graph.md) §Dependency injection).

> **The load-bearing property.** A node that reaches around a port — importing a Qdrant client, opening a NATS connection, calling a provider SDK — silently converts this repo from *portable* to *AISAT-shaped*, and nothing fails until someone tries the second host. That is why the ban is a constitutional principle (VII) and is checked by a static import scan, not left to review.

---

## The eleven ports

| Port | Runtime needs it for | Degrades to | Supplied by |
|---|---|---|---|
| `RetrievalService` | fetching candidate context under the caller's visibility predicate | **nothing — required**; a `retrieve` outage fails the run | `DomainPlugin` |
| `ToolRegistry` | dispatching the tool catalog | empty registry (agent answers without tools) | `DomainPlugin` |
| `Policy` | the access model the `Authorizer` orchestrates | **nothing — required**; fail-closed | `DomainPlugin` |
| `LLMGatewayClient` | every model call, no exceptions | **nothing — required** | generic runtime |
| `MemoryService` | cross-session recall | no-op → `memories == []` | generic runtime |
| `StreamWriter` | token/event emission | no-op → run completes unstreamed | generic runtime |
| `Checkpointer` | durable-form resume | required for durable form only; interactive needs none | generic runtime |
| `Bus` | worker-role fan-out | `inprocess` executor (direct calls) | generic runtime |
| `Meter` | spend emission | no-op → **host must still meter**; see below | host |
| `Recorder` | append-only audit of tool calls | **nothing — required**; a tool call that cannot be audited must not run | host |
| `ApprovalStore` | human-in-the-loop gate persistence | required iff any Category-D action tool is enabled | host |

**"Degrades to" is a contract, not a convenience.** A port whose row says *nothing — required* must fail the run loudly when absent. A port that degrades must do so observably: the run records `outcome="degraded"` with a `degrade_reason`, never silently produces a thinner answer that looks identical to a healthy one.

---

## Protocols

```python
class AgentDeps(TypedDict):
    retrieval: RetrievalService
    memory: MemoryService
    llm: LLMGatewayClient
    tools: ToolRegistry
    emit: StreamWriter
    meter: Meter
    audit: Recorder
    approvals: ApprovalStore | None      # None iff no action tool is enabled
```

### `RetrievalService`

```python
class RetrievalService(Protocol):
    async def search(
        self,
        query: str,
        ctx: SecurityCtx,
        *,
        limit: int,
        doc_ids: Sequence[str] | None = None,
    ) -> list[Candidate]: ...
```

- **MUST** apply the caller's visibility predicate *inside the store*, as a pre-filter — never by post-filtering results in Python. A post-filter is a correctness bug even when the output looks identical, because it means the store returned rows the caller may not see.
- **MUST** return `[]` rather than raise when nothing matches. `source_count == 0` is a valid answer state, not a failure.
- `doc_ids` conjoins a document-scope term onto the predicate; it **narrows**, and can never widen past `ctx`.
- Backends: `qdrant` (hybrid BM25/SPLADE + dense) and `pgvector` (dense HNSW + a lexical companion + RRF). Selected by `retrieval.kind` in the manifest. Both MUST pass `RetrievalServiceContract`.

### `ToolRegistry`

```python
class ToolRegistry(Protocol):
    def list_tools(self, agent_role: str) -> list[ToolSpec]: ...
    async def call(self, name: str, args: dict, ctx: SecurityCtx) -> ToolResult: ...
```

- Bindings selected by `tools.kind`: `inprocess` (direct calls into the shared tool library) or `mcp_client` (a remote domain MCP server via URL + device PAT).
- Enforcement — allowlist check, tenant GUCs, audit write — lives in the **shared implementation**, never in the transport. The `mcp_client` binding delegates the identical wrapper to the remote server's own boundary.
- **MUST** write exactly one audit row per call, through `Recorder`, including on failure.

### `Policy`

```python
class Policy(Protocol):
    def permit(self, action: Action, ctx: SecurityCtx) -> Decision: ...
    def lower(self, ctx: SecurityCtx, target: LoweringTarget) -> Predicate: ...
```

`permit` answers *may this happen*; `lower` turns the claims bag into a store-native predicate (RLS GUCs, a vector payload filter). A `Policy` is **pure** — no I/O, no clock, no randomness — so it is exhaustively testable and cannot fail open on a network blip.

A manifest may **select** a `Policy` by name. It may never **be** one.

### `LLMGatewayClient`

```python
class LLMGatewayClient(Protocol):
    async def complete(self, req: CompletionRequest, *, deadline: float) -> Completion: ...
    async def stream(self, req: CompletionRequest, *, deadline: float) -> AsyncIterator[Token]: ...
    async def embed(self, texts: Sequence[str]) -> list[Vector]: ...
```

- Any OpenAI-wire endpoint. The runtime holds **no provider key** and names only gateway **aliases** (`fast`/`smart`/`embed`/`rerank`), never concrete model IDs — a model swap is a gateway config change, invisible here.
- `deadline` is the remaining run budget, passed down so the gateway can refuse rather than overrun.

### `MemoryService`, `StreamWriter`, `Checkpointer`, `Bus`

```python
class MemoryService(Protocol):
    async def recall(self, ctx: SecurityCtx, query: str) -> list[Memory]: ...
    async def write(self, ctx: SecurityCtx, items: Sequence[Memory]) -> None: ...

class StreamWriter(Protocol):
    async def emit(self, event: StreamEvent) -> None: ...

class Bus(Protocol):
    async def publish(self, subject: str, payload: bytes) -> None: ...
    async def subscribe(self, subject: str, group: str | None = None) -> AsyncIterator[Msg]: ...
```

- **Memories are re-filtered every turn** against current clearance, never trusted from a prior turn's snapshot — a demotion takes effect on the next turn.
- `StreamWriter` is transport-agnostic. The Redis pub/sub adapter is host-specific and stays **behind** this boundary; `graph.astream_events` MUST yield tokens with no Redis client bound.
- `Checkpointer` is any LangGraph `BaseCheckpointSaver` (Redis, Postgres, SQLite).
- `Bus` bindings: `jetstream` | `redis_streams` | `inprocess`. A single-container deployment needs **no** bus — worker roles become in-process calls.

### `Meter`, `Recorder`, `ApprovalStore` — host-supplied

```python
class Meter(Protocol):
    async def emit_spend(self, ctx: SecurityCtx, op: str, units: int, idem_key: str) -> None: ...

class Recorder(Protocol):
    async def record(self, entry: AuditEntry) -> None: ...

class ApprovalStore(Protocol):
    async def open_gate(self, ctx: SecurityCtx, subject: Subject, prompt: str) -> GateId: ...
    async def await_decision(self, gate: GateId) -> Decision: ...
```

These three are **emission points, not authorities**. The runtime emits a spend event; it never writes a ledger. It records an audit entry; it never owns the chain head. It opens a gate; it never decides the outcome. See [host-integration.md](./host-integration.md).

`emit_spend` carries an `idem_key` because the host's ledger MUST be able to reject a double-charge on redelivery (the runtime cannot guarantee exactly-once delivery, and pretending otherwise is how double-charges happen).

---

## `SecurityCtx` — two tiers

```python
class SecurityCtx(TypedDict):
    tenant: str          # opaque
    principal: str       # opaque
    agent_role: str      # opaque label the allowlist is keyed on
    allowed_tools: list[str]
    trace_id: str
    stream_id: str
    claims: dict         # OPAQUE to the runtime — deps only
```

The runtime reads the **core** and passes `claims` through untouched. Every product-specific authorization fact lives in `claims`, and only the deps (`RetrievalService`, `ToolRegistry`, `Policy`) may dereference it.

**Enforced mechanically**: an AST/import scan asserts that no module under `graph/nodes/` subscripts `ctx["claims"]`. Complementarily, the graph runs green end-to-end on a `ctx` whose `claims` bag holds an opaque test-only key — proving the runtime never depends on a particular claim shape.

> `ctx` is stamped by the host's **trusted layer**, never by a client, and never derived from model or document output. A `ctx` a caller can influence is a privilege-escalation primitive, not a parameter.

---

## Conformance

Every port ships a suite in `intel_agent.conformance`, importable by host repos:

| Suite | Proves |
|---|---|
| `RetrievalServiceContract` | pre-filter (not post-filter); empty-result is not an error; `doc_ids` narrows only |
| `ToolRegistryContract` | allowlist enforced; exactly one audit row per call incl. failures; in-process and MCP paths identical |
| `PolicyContract` | purity (same input → same decision, no I/O); fail-closed on unknown action |
| `MeterContract` | idempotency key honored; no spend on a refused/paused run |
| `ApprovalContract` | zero spend while pending; first decision wins; reject never mutates the subject |
| `AccessFloorContract` | **profile-invariant** — a cross-tenant / above-clearance row is `not_found` under both the RLS+vector-filter and RLS-only lowerings |

`AccessFloorContract` is the load-bearing one. It MUST pass **unchanged** under both profile wirings; if it needs profile-specific branches, the boundary is wrong, not the test.

---

## Contract test obligations

- **No concrete client at module scope**: a static import scan over `graph/` fails on any direct import of `qdrant_client`, `nats`, `redis`, or a provider SDK.
- **Fake-deps isolation**: every node runs green in a unit test with a fake `AgentDeps` and no running infra.
- **Streaming decoupling**: `astream_events` yields tokens with no Redis client bound.
- **Degradation is observable**: with `memory`, `emit`, and the OTel exporter all unbound, the graph still produces a cited answer and records `degraded` for each — it never reports a clean run.
- **Deterministic doubles**: a `FakeGateway` returns scripted responses covering a well-formed answer, a tool call, malformed output, a raised exception, a `429` with `Retry-After`, and a stream that disconnects mid-emit. No test in the suite reaches a provider; an offline CI run is itself the assertion.
