<!-- Extracted from aisat-intel@369756e. Consolidates the port surface that was
     previously described in-line across agent-graph.md (Dependency injection,
     Extraction checklist), agent-runtime.md (swap matrix, DomainPlugin), and the
     host-side port contracts that stayed in aisat-intel. -->

# Contract: `AgentDeps` — the port surface

**Graph internals**: [agent-graph.md](./agent-graph.md) | **Composition**: [agent-runtime.md](./agent-runtime.md) | **Host obligations**: [host-integration.md](./host-integration.md) | **Status**: the **boundary**. This is the complete list of what the runtime needs from the outside world. If something is not on this page, the runtime does not need it and must not reach for it.

`AgentDeps` is assembled **once per worker** at the graph entrypoint and passed through LangGraph's `RunnableConfig["configurable"]["deps"]`. Nodes are pure functions of `(state, config)` and never import a concrete client at module scope ([agent-graph.md](./agent-graph.md) §Dependency injection).

> **The load-bearing property.** A node that reaches around a port — importing a Qdrant client, opening a NATS connection, calling a provider SDK — silently converts this repo from *portable* to *host-shaped*, and nothing fails until someone tries the second host. That is why the ban is a constitutional principle (VII) and is checked by a static import scan, not left to review.

---

## The fourteen ports

| Port | Runtime needs it for | Ships a default? | If absent | Tier |
|---|---|---|---|---|
| `RetrievalService` | fetching context under the caller's visibility predicate | **yes** — pgvector / sqlite / qdrant | **required** — a `retrieve` outage fails the run | Stable |
| `Policy` | the access model | **yes** — single-tenant allow-own | **required** — fail closed | Stable |
| `LLMGatewayClient` | every model call | **yes** — any OpenAI-wire endpoint | **required** | Stable |
| `Ingestor` | getting content **into** the store | **yes** — files / URLs / text | store must be populated externally | Beta |
| `IdentityBinder` | who a caller is | **yes** — single-user / user list, fail-closed | **required** once any inbound surface is attached | Experimental |
| `Meter` | usage accounting | **yes** — real local ledger (tokens, cost, per principal) | **required** — never silently unmetered | Stable |
| `Recorder` | append-only audit of tool calls | **yes** — local audit log | **required** — a tool call that cannot be audited must not run | Stable |
| `ApprovalStore` | human-in-the-loop gates | **yes** — local store + resolve surface | required iff an action tool is enabled | Stable |
| `ToolRegistry` | dispatching the tool catalog | **yes** — the built-in read-only tier | empty registry: the agent answers without tools | Stable |
| `Checkpointer` | durable-form resume | **yes** — SQLite / Redis | interactive form needs none | Stable |
| `Bus` | worker-role fan-out | **yes** — `inprocess` | n/a — `inprocess` *is* the no-broker case | Beta |
| `StreamWriter` | token/event emission | **yes** — CLI + built-in UI writers | run completes **unstreamed**, recorded as degraded | Stable |
| `MemoryService` | cross-session recall | **yes** — local memory store | `memories == []`, recorded as degraded | Beta |
| `Channel` | reaching the agent from a chat platform | Phase 2 | the CLI/UI drive the graph directly | Experimental |

**Three different columns, deliberately.** *Ships a default* is what you get out of the box; *if absent* is what happens when a host explicitly binds nothing; *Tier* is the compatibility promise ([host-integration.md §Versioning](./host-integration.md#versioning-stability-tiers-and-breaking-changes)). A port can ship a real default **and** be required — that combination means "you will never accidentally run without this, and you do not have to build it either".

**Why `Channel` and `IdentityBinder` are Experimental and everything on the read path is Stable.** A tier is a statement about how much evidence a shape has, not about how much care went into it. The Stable ports have been exercised by a real deployment; the channel pair has been *designed* against three platform specs and built against none. Freezing them at Stable before the first adapter exists would mean either a major-version bump for the first thing WeChat teaches us, or — far likelier — quietly breaking the promise. Declaring the uncertainty is the honest move and it costs a host nothing it was not already exposed to.

**No port degrades to a silent success.** Where a column says *required*, the run fails loudly. Where it says *degraded*, the run records `outcome="degraded"` with a reason — it never produces a thinner answer that looks identical to a healthy one.

**Every port has a working default.** The runtime is a product: it ingests, retrieves, meters, moderates, gates, and answers without a host. A host overrides a port when its own implementation is better for its context — not because ours is a placeholder.

> **No hollow defaults.** A default that does nothing is worse than no default, because it makes a broken deployment look configured. Where a capability genuinely cannot work without host context, the runtime **fails to start without a binding** instead of shipping a no-op that silently passes. There is no port whose default is "pretend it worked".

**"If absent" is a contract, not a convenience.** A row marked *required* must fail the run **loudly** when nothing is bound. A row marked *degraded* must degrade **observably** — the run records `outcome="degraded"` with a `degrade_reason`. Neither may quietly return a thinner answer that looks identical to a healthy one.

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

> **Why `AgentDeps` has eight fields but the table lists fourteen ports.** `Checkpointer` and `Bus` are bound at **graph compilation** and worker wiring, not per run — a node never reaches for them. `Ingestor` runs **before** any graph does, populating the store a run later reads. `Channel` and `IdentityBinder` sit **above** the graph entirely: the `ChannelRunner` uses them to *produce* a `ctx` and *consume* the event stream, so by the time `AgentDeps` exists the channel has already done its job. Keeping them out of `AgentDeps` is what makes the graph channel-blind ([channels.md](./channels.md)).

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
- Backends selected by `retrieval.kind`; **all** MUST pass `RetrievalServiceContract` **and** `AccessFloorContract`:
  - `qdrant` — hybrid BM25/SPLADE + dense, payload pre-filter, paired with RLS (Profile A)
  - `pgvector` — dense HNSW + a lexical companion + RRF, RLS as the sole floor (Profile B)
  - `sqlite` — dense + FTS5, **predicate enforced by the query, not the engine** (Profile C). A weaker floor, single-tenant only; it MUST emit a startup warning saying so. See [agent-runtime.md § Profile C](./agent-runtime.md#profile-c--minimal-single-tenant-agent-one-container-one-file).

### `ToolRegistry`

```python
class ToolSpec(TypedDict):
    name: str
    description: str
    args_schema: dict
    max_result_bytes: int            # DECLARED, not optional — see below

class ToolResult(TypedDict):
    ok: bool
    data: Any
    truncated: bool                  # True iff max_result_bytes clipped the result
    result_hash: str

class ToolRegistry(Protocol):
    def list_tools(self, agent_role: str) -> list[ToolSpec]: ...
    async def call(self, name: str, args: dict, ctx: SecurityCtx) -> ToolResult: ...
```

- Bindings selected by `tools.kind`: `inprocess` (direct calls into the shared tool library) or `mcp_client` (a remote domain MCP server via URL + device PAT).
- Enforcement — allowlist check, tenant GUCs, audit write — lives in the **shared implementation**, never in the transport. The `mcp_client` binding delegates the identical wrapper to the remote server's own boundary.
- **MUST** write exactly one audit row per call, through `Recorder`, including on failure.
- **Every tool declares `max_result_bytes`, and the wrapper enforces it.** `assemble`'s token trim backstops the *context window*, so an oversized result is not a correctness bug — but it is a cost, latency, and rerank-quality bug that the trim happens after and therefore cannot prevent. A `query_employees` filter matching 40,000 rows is paid for in full at fetch, at rerank, and in the funnel arithmetic before a single row is dropped. A clipped result **MUST** set `truncated: true` and carry an explicit in-band marker, never silently return a short list — the model must be able to tell "there were three results" from "there were three thousand and you are seeing the first page", because those warrant different answers.
- **Tool output is scrubbed before it leaves the wrapper.** Results flow into the prompt *and* into `debug` fragments, neither of which passes the gateway client's PII chokepoint (AR-020). The wrapper applies a **credential scrubber** — static patterns plus a **dynamic registry of the runtime's own secret values** (gateway keys, device PATs, DSNs, whatever was bound at composition) — replacing matches with `[REDACTED]`. Always on, never a config flag. The dynamic half is what catches the case static patterns cannot: a tool that echoes back a connection string the deployment itself supplied.

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
class CompletionRequest(TypedDict):
    alias: str                       # fast | smart | embed | rerank | vision
    messages: list[dict]
    max_output_tokens: int           # DEFAULT 8192 — see the escalation rule below

class Completion(TypedDict):
    text: str
    usage: dict
    finish_reason: Literal["stop", "length", "content_filter", "error"]

class LLMGatewayClient(Protocol):
    async def complete(self, req: CompletionRequest, *, deadline: float) -> Completion: ...
    async def stream(self, req: CompletionRequest, *, deadline: float) -> AsyncIterator[Token]: ...
    async def embed(self, texts: Sequence[str]) -> list[Vector]: ...
    def count_tokens(self, messages: Sequence[dict], *, alias: str) -> int: ...
```

- Any OpenAI-wire endpoint. The runtime holds **no provider key** and names only gateway **aliases** (`fast`/`smart`/`embed`/`rerank`), never concrete model IDs — a model swap is a gateway config change, invisible here.
- `deadline` is the remaining run budget, passed down so the gateway can refuse rather than overrun.
- **`max_output_tokens` defaults to 8192 and escalates on demand.** Reserving a large output slot is not free: the reservation is subtracted from the usable input window on most providers, so a default of 32–64K spends a quarter of the context on headroom that a cited answer never uses. The rule is cap low, then react — on `finish_reason == "length"`, retry **once** at 4× the cap. Applied at `generate` only; `route`, `rewrite`, and `rerank` have bounded outputs by construction and keep the default.
- **A context-length error is a distinct, non-retryable outcome.** The gateway MUST surface a provider `413`-class refusal as a typed error rather than a generic failure — the same prompt does not fit on a second attempt, so retrying it wastes a call to reach the same place. It ends the run `failed('context_window_exceeded')` ([agent-graph.md](./agent-graph.md#conversation-context-budget--bounding-history-ar-015a)).
- **`count_tokens` exists so the context budget is measured, not guessed.** The entrypoint compactor calls it to decide whether `history` fits. An implementation with no authoritative counter MUST return a conservative over-estimate — biasing toward compacting early is recoverable, and discovering the real number from a provider rejection is not.

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
- **A memory is untrusted content, and re-filtering does not make it trusted.** Clearance answers *may this principal see this*; it says nothing about whether the text is trying to issue an instruction. A memory is the only prompt input that is both **persistent** and **cross-session**: it entered on some earlier turn, `guard` will never screen it again, and it arrives at `generate` looking like the agent's own knowledge. It MUST be delimited exactly as retrieved content is ([agent-graph.md](./agent-graph.md#untrusted-content--the-complete-list-because-guard-only-screens-this-turn-ar-002ar-003)).
- **A backend MUST NOT write memories on its own.** Several off-the-shelf memory services extract and persist facts from turn text by default. That is an autonomous write to a durable, cross-session, replayed-into-every-prompt surface — precisely what research §13 excludes from Phase 1. Bind such a backend with extraction **disabled**, or wrap it so every write is an explicit, audited `write` call the runtime made. `MemoryServiceContract` asserts it.
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

Each ships a **working default** and each is overridable:

- **`Meter`** — the default keeps a **real local usage ledger** (tokens, cost, per principal, idempotent by `idem_key`), so a standalone agent knows what it spent. A host with its own billing binds that instead and becomes the authority; the runtime then only *emits* and never writes.
- **`Recorder`** — the default writes a local append-only audit log. A host with a tamper-evident chain owns the chain head and the runtime is only a writer.
- **`ApprovalStore`** — the default persists gates locally with a resolve surface. A host with its own approvals UI binds that.

The pattern is the same in all three: **standalone, the runtime is the authority; embedded, it demotes itself to an emitter.** That demotion is a binding choice, never a silent one — see [host-integration.md](./host-integration.md).

### `Ingestor` — the corpus seam

```python
class Ingestor(Protocol):
    async def ingest(
        self, source: IngestSource, ctx: SecurityCtx, *, tags: dict | None = None
    ) -> IngestResult: ...
```

- **MUST stamp `tenant` and `principal`** on every item from `ctx`. Content whose ownership cannot be established is **rejected**, never ingested as unowned — an unowned row satisfies no visibility predicate cleanly, and "invisible to most queries" is not the same as "protected".
- **MUST treat the source as untrusted** for the whole path. A document is data at ingest time exactly as it is at retrieval time; parsing it must never execute it.
- **Idempotent by content hash** — re-ingesting a source updates rather than duplicates, or a re-run silently doubles a document's weight in every future retrieval.
- A **default implementation ships here** (files, URLs, raw text) so the product runs alone. A host with its own pipeline binds that instead; the default is not privileged and passes the same `IngestorContract`.

> This is the port that turns the runtime into a product. Without it a standalone deployment can *answer* over a corpus but cannot *build* one — precisely the difference between a library and something you can install and use.

### `Channel` and `IdentityBinder` — the chat-platform seam

```python
class Channel(Protocol):
    name: str
    capabilities: ChannelCapabilities     # declared, not detected
    def listen(self) -> AsyncIterator[InboundMessage]: ...
    def writer(self, msg: InboundMessage) -> StreamWriter: ...

class IdentityBinder(Protocol):           # HOST-supplied
    async def bind(self, msg: InboundMessage) -> SecurityCtx | None: ...
```

The runtime owns the **protocol plumbing** (connection, events, rate limits, chunking); the host owns the **identity mapping**, because that is obligation H1 and a wrong answer there is a privilege escalation.

`bind` returning `None` MUST refuse the message. It must never fall back to an anonymous or default identity — on a public channel, "unrecognized user" is the normal case.

Capabilities are **data, not subclassing**, because the platforms genuinely differ: WeChat cannot stream and must answer within ~5s, while Discord and Slack stream by editing a message in place. The runtime adapts to the declaration. Full contract, including the per-platform table: [channels.md](./channels.md).

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
| `ToolRegistryContract` | allowlist enforced; exactly one audit row per call incl. failures; in-process and MCP paths identical; **`max_result_bytes` clips with `truncated: true` and a marker, never silently**; **a bound secret echoed by a tool comes back `[REDACTED]`** |
| `PolicyContract` | purity (same input → same decision, no I/O); fail-closed on unknown action |
| `LLMGatewayClientContract` | aliases resolve without a provider key; `deadline` refuses rather than overruns; a context-length refusal is typed and **not** retried; `finish_reason == "length"` escalates `max_output_tokens` exactly once; `count_tokens` never under-reports |
| `MemoryServiceContract` | write-time ownership stamping; **read-time re-filtering against current clearance**; **no autonomous write** — turn text alone produces no memory |
| `MeterContract` | idempotency key honored; no spend on a refused/paused run |
| `ApprovalContract` | zero spend while pending; first decision wins; reject never mutates the subject |
| `IngestorContract` | ownership stamped from `ctx`; unowned content rejected; idempotent by content hash; source treated as untrusted |
| `ChannelContract` | declared capabilities are honest; unknown identity refuses; deadline clamping defers rather than truncates; chunking is lossless; no cross-adapter SDK leak |
| `AccessFloorContract` | **profile-invariant** — a cross-tenant / above-clearance row is `not_found` under both the RLS+vector-filter and RLS-only lowerings |

`AccessFloorContract` is the load-bearing one. It MUST pass **unchanged** under both profile wirings; if it needs profile-specific branches, the boundary is wrong, not the test.

---

## Contract test obligations

- **No concrete client at module scope**: a static import scan over `graph/` fails on any direct import of `qdrant_client`, `nats`, `redis`, or a provider SDK.
- **Fake-deps isolation**: every node runs green in a unit test with a fake `AgentDeps` and no running infra.
- **Streaming decoupling**: `astream_events` yields tokens with no Redis client bound.
- **Degradation is observable**: with `memory`, `emit`, and the OTel exporter all unbound, the graph still produces a cited answer and records `degraded` for each — it never reports a clean run.
- **Deterministic doubles**: a `FakeGateway` returns scripted responses covering a well-formed answer, a tool call, malformed output, a raised exception, a `429` with `Retry-After`, **a context-length refusal**, **a `finish_reason == "length"` truncation**, and a stream that disconnects mid-emit. No test in the suite reaches a provider; an offline CI run is itself the assertion.
- **No secret reaches a prompt or a debug fragment**: a value registered in the scrubber's dynamic registry, echoed verbatim by a tool, appears nowhere in the assembled prompt, in `debug`, in an emitted event, or in an audit entry.
- **Port tiers are declared and enforced**: every `Protocol` in `ports/` carries a tier marker, the table above matches it, and a CI check fails when a `Stable` port's signature changes without a minor-version bump ([host-integration.md](./host-integration.md#versioning-stability-tiers-and-breaking-changes)).
