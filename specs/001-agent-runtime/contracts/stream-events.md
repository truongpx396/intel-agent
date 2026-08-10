# Contract: Stream Events — what the runtime emits, and how both sides test it

**Ports**: [agent-deps.md](./agent-deps.md) | **Channels**: [channels.md](./channels.md) | **Host obligations**: [host-integration.md](./host-integration.md) | **Status**: the **event vocabulary** and the **test doubles** that let each repo be developed and tested without the other.

This contract exists because the split created a testing hole in both directions:

- **The host** has a UI, a transport, and a billing path — and, after the extraction, no agent to drive them.
- **The runtime** has an agent — and no UI to watch it stream.

Both are solved by the same thing: a **versioned event vocabulary**, plus **doubles and fixtures shipped by the runtime** so neither side has to invent the other.

---

## Ownership: vocabulary vs. framing

| | Owner | What it covers |
|---|---|---|
| **Event vocabulary** (this contract) | **intel-agent** | *What* events exist, their payload shape, their ordering guarantees |
| **Wire framing** | **host** | *How* they reach a client — SSE event names, retry, heartbeat, reconnect, HTTP status |

Same rule as everywhere: the runtime owns the port, the host owns the transport. A host may rename `token` to whatever its SSE taxonomy calls it; it may not invent a semantic event the runtime never emits, or silently drop one it does.

> **Why this must be versioned.** Two repos now consume this vocabulary — the host's transport and the runtime's own dev harness. An unversioned event shape is the fastest way for them to drift while both look green.

---

## The vocabulary

| Event | Emitted by | Payload | Ordering |
|---|---|---|---|
| `run_started` | runtime | `{run_id, thread_id, intent?}` | exactly once, first |
| `node_started` | telemetry wrapper | `{node, step}` | once per executed node |
| `token` | `generate` | `{delta}` | zero or more, monotonic |
| `tool_use` | `retrieve` / tools | `{tool, args_digest}` | before its `tool_result` |
| `tool_result` | tools | `{tool, ok, result_hash}` | after its `tool_use` |
| `citations` | `generate` | `{sources[]}` | after the last `token` |
| `debug_fragment` | owning node | `{section, data}` | any time; **one writer per section** |
| `suggestions` | `suggest` | `{questions[]}` | after `citations` |
| `clarification` | `clarify` | `{question, options[]}` | **terminal** for that turn |
| `gate_opened` | `human_gate` | `{gate_id, prompt, subject}` | run pauses here |
| `gate_resolved` | runtime | `{gate_id, verdict}` | on resume |
| `degraded` | any node | `{node, reason}` | any time |
| `error` | runtime | `{code, message}` | **terminal** |
| `run_finished` | runtime | `{run_id, outcome, usage, answer_generated, ungrounded_claims}` | exactly once, last |

`degraded.reason` is a **closed vocabulary**, so a consumer can branch on it rather than parse prose: `rerank_fallback` \| `memory_unavailable` \| `rewrite_passthrough` \| `vision_failed` \| `history_compacted` \| `deadline_partial` \| `stream_unavailable`.

`run_finished.outcome` is likewise closed: `ok` \| `degraded` \| `blocked` \| `clarified` \| `failed` \| `paused`.

**`answer_generated: false` is the not-generated marker, and it is structural on purpose.** A run that breached its deadline after `assemble` may finish with `citations` and no answer ([agent-graph.md](./agent-graph.md#a-deadline-breach-past-assemble-degrades-it-does-not-discard-ar-015)). A consumer MUST be able to tell that from a normal answer **without reading the prose** — a sentence the model was asked to write is not a protocol, it is a hope. Same reasoning as the `vision` fallback stating the image was not examined.

**`ungrounded_claims` is structural for the same reason, and it is the one that decides whether an answer should be trusted.** `generate` already maps each claim to the chunks supporting it and records the unsupported ones ([agent-graph.md](./agent-graph.md#observability-fragments--what-each-node-owes-the-debug-panel-ar-017-sc-a05)); until this field existed, that count reached only the `debug_fragment` — which a host renders on request, into a panel most members never open. An answer with three unsupported claims otherwise streams **byte-identically** to a fully-grounded one. The integer count travels with every finished run: `0` means every claim traced to a retrieved chunk, and any positive value is the hallucination signal the run already computed and was throwing away. It is **reported, not enforced** in Phase 1 — a consumer decides what to do with it, and the Phase-2 `grade_answer` seam is what will act on it inside the graph.

**Guarantees a consumer may rely on**

1. `run_started` first, exactly one terminal (`run_finished` or `error`) last.
2. `node_started` has exactly one matching terminal record per executed node.
3. `tool_use` precedes its `tool_result`; both carry the same `tool`.
4. `citations` never precedes the final `token` of the answer it cites.
5. `clarification` and `error` are **terminal for the turn** — nothing meaningful follows.
6. A paused run emits `gate_opened` and then **nothing** until resumed. It is *paused*, not finished — a consumer that treats silence as completion is wrong, and this is the single most common integration bug.
7. `degraded` may appear at any point and **never** replaces a terminal event. A degraded run still finishes — with `run_finished{outcome:'degraded'}`, never `ok`.
8. `citations` may arrive with **no** preceding `token` when `answer_generated` is `false`. A consumer that assumes citations imply an answer renders an empty bubble under a source list; this is the second most common integration bug after treating a pause as completion.
9. `ungrounded_claims` is present on every `run_finished` that generated an answer, and is `0` — not absent — when every claim is supported. Absent and zero must not be conflated: a consumer that reads a missing field as "nothing ungrounded" would render an unmeasured run as a clean one, which is the same smoothing-over the `degraded` vocabulary exists to prevent.

**No payload carries a body.** No prompt text, no chunk text, no memory content in `debug_fragment` or telemetry — refs and hashes only, matching AR-020.

---

## What the runtime ships for testing

Both problems above are solved by exports, not by each repo inventing its own.

### `intel_agent.testing.FakeAgentRuntime`

A scripted, deterministic stand-in that satisfies the **same call surface** a host uses (`build_graph(...)` → `astream_events(...)`), emitting a chosen scenario without a model, a store, or a network.

```python
from intel_agent.testing import FakeAgentRuntime, scenarios

graph = FakeAgentRuntime(scenarios.CITED_ANSWER)      # or REFUSAL, CLARIFICATION,
                                                       # GATE_PAUSE_RESUME, DEGRADED_RERANK,
                                                       # DEADLINE_DEFERRAL, DEADLINE_PARTIAL,
                                                       # HISTORY_COMPACTED, TRUNCATED_TOOL_RESULT,
                                                       # CONTEXT_WINDOW_EXCEEDED, ERROR
async for ev in graph.astream_events({"query": q, "ctx": ctx}):
    ...
```

This is what lets a host build and test its **transport, debug panel, chat UI, billing, and notifications** with the agent extracted. It is shipped **by the runtime** precisely so it cannot drift from the real thing — a hand-rolled mock in the host repo would be a second, unversioned definition of the vocabulary, which is the drift this contract exists to prevent.

### `intel_agent.testing.golden/`

Recorded event streams for each scenario, as JSONL. Both repos assert against **the same files**:

- the runtime asserts its real graph reproduces them (modulo nondeterministic ids)
- a host asserts its transport relays them without loss or reordering

A vocabulary change that breaks a host now breaks a **fixture diff** in the runtime's own PR — before it ships.

### `StreamEventContract`

The conformance suite any consumer runs. It asserts the nine guarantees above, plus:

- **out-of-order and interleaved arrival** is handled (a transport may batch or coalesce)
- an **unknown future event type** is ignored, not fatal — forward compatibility is what lets the runtime add an event without a synchronized host release
- an **unknown `degraded.reason` or `run_finished.outcome`** is handled as degraded/unfinished rather than crashing or silently mapping to `ok` — the vocabularies are closed *today*, and forward compatibility has to cover the values too, not only the event names
- a **paused** run is not rendered as finished
- a run with `answer_generated: false` is **not** rendered as an answered question
- no event payload contains a body

---

## How each side develops without the other

### A host, with no agent

```python
# transport / UI / billing tests
from intel_agent.testing import FakeAgentRuntime, scenarios, golden

class TestSSERelay(StreamEventContract):
    stream = FakeAgentRuntime(scenarios.GATE_PAUSE_RESUME)
```

No model, no vector store, no network. Deterministic, fast, and — because the fixtures are the runtime's — *actually representative*.

### The runtime, with no product UI

Two dev harnesses, both **dev-only and never packaged**:

| Harness | For |
|---|---|
| `make dev` — a streaming CLI REPL | the default loop: fast, scriptable, diffable, works in CI |
| `make dev-ui` — one self-contained HTML page over SSE | what a CLI shows badly: token streaming feel, the debug panel, a human gate with real approve/reject buttons |

> **The dev UI is a reference consumer, not a product.** It renders **only** from the published vocabulary and calls **no** bespoke endpoint. That constraint is what makes it useful as a check: if the dev UI can render a run, any conforming host can. If it ever needs a special case, the vocabulary is missing something — fix the vocabulary, not the page.
>
> It must never grow auth, persistence, multi-user, or styling ambitions. A dev harness that becomes a second product surface re-creates the coupling this whole extraction removed.

Once channel adapters land ([channels.md](./channels.md)), Discord and Slack become dev surfaces too — a real chat client is a better manual test than any page we would write.

---

## Contract test obligations

- **Doubles match reality**: every scenario the `FakeAgentRuntime` can emit is reproduced by the real graph against `FakeGateway`, asserted against the same golden file.
- **Golden fixtures are versioned**: changing an event shape changes a fixture, and that diff is reviewable.
- **Forward compatibility**: a consumer built against version *N* survives a stream containing an event added in *N+1*.
- **Pause is not completion**: a `gate_opened` stream with no further events is asserted **not** to satisfy "run finished" in any consumer.
- **No body leak**: a sentinel planted in the query, a chunk, and a memory appears in **no** emitted event payload.
- **Dev UI conformance**: the dev page is run against every golden fixture in CI; it must render each without a special case. This is the cheapest available proof that the vocabulary is sufficient for a real consumer.
