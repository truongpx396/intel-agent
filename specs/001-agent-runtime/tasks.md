<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/tasks.md).
     FRESH T001… series. The mapping table at the bottom is authoritative for
     tracing any task back to the aisat-intel ID it replaces; those IDs are
     retired in place upstream (never renumbered — dispatch-prompts.md and
     track-manifest.md reference them by number, as do the runs/ records). -->

# Tasks: Self-Contained Agent Runtime

**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Ports**: [contracts/agent-deps.md](./contracts/agent-deps.md)

## Format

`[ID] [P?] Description` — `[P]` means parallelizable (different files, no shared state).

**Stage order is execution order; task IDs are stable labels.** IDs are monotonic *within* a stage and are never recycled, so a stage that moves in the schedule carries its IDs with it rather than renumbering every task downstream. Read the stage headings for sequence, not the numbers.

**TDD is non-negotiable** (constitution VI): **every implementation task is immediately preceded by the test or conformance task that constrains it**, and that test MUST fail first. A conformance suite is written **before** the backend it constrains — that ordering is what makes the suite a specification rather than a description of whatever got built. Where an implementation's test lives in an earlier stage (a port's conformance suite, say), the stage note says so.

---

## Stage 1: Setup

- [ ] **T001** Initialize the package skeleton: `src/intel_agent/{ports,graph,retrieval,memory,tools,gateway,bus,manifest,telemetry,channels,ingest,identity,ui,conformance}/__init__.py`, `tests/{unit,integration,conformance,smoke}/`.
- [ ] **T002** [P] Wire ruff + black + mypy to the settings already in `pyproject.toml`; confirm `make lint` and `make typecheck` are green on the empty tree.
- [ ] **T002a** Encode the constitution's **full CI gate order** in `.github/workflows/ci.yml` and `make ci`: lint/format → unit → integration → contract → conformance → Profile-B smoke → build → security scan, plus the **80% coverage floor** (`pytest --cov`, failing under the threshold *and* on any decrease) and the eval gate (T060c). Constitution V and the Development Workflow section both require this ordering; until it exists, "green CI" and "the gates the constitution names" are different claims. The quickstart's `make ci` is the local subset and MUST say which gates it skips.
- [ ] **T003** [P] Add `scripts/check-import-boundaries.py`: an AST scan asserting no module under `graph/` imports a concrete backend (`qdrant_client`, `nats`, `redis`, provider SDKs) and no module under `ports/` imports any implementation. Wire into `make lint`.
- [ ] **T003a** [P] Add `scripts/check-anchors.sh` and fold it into `make check-docs`. `check-links.sh` deliberately strips the `#fragment` and asserts only that the *file* exists, which leaves the likelier rot uncovered: a heading gets reworded (`FR-028a` → `AR-015`; "one MCP server" → "a `ToolRegistry` port"), every link still resolves to a real file, and the reader silently lands at the top of a 400-line contract instead of at the section that was promised. Five such anchors were already dead when this task was written — two of them predating the change that found them — which is the argument for the gate rather than another round of manual fixes.
- [ ] **T003b** [P] Clear the standing `ruff` findings in `src/intel_agent/{ports,conformance}/__init__.py` so `make ci` is green at `HEAD`. **State no count here** — the number was `108` when this task was first written and is a single `RUF022` today, and a stale count is worse than none because it makes the task look undone when it is nearly finished. The requirement is the exit code, not the tally: while `make ci` is red at `HEAD`, the gate cannot distinguish a new break from the standing one, which is the whole reason this is a Stage 1 task.

## Stage 2: Ports and conformance (blocking — everything depends on these)

> The suites land **before** any real backend. A suite written after its implementation documents the implementation; a suite written before it constrains one.
>
> **Every port gets a suite** (AR-025, constitution VII). The port table in [agent-deps.md](./contracts/agent-deps.md) is the enumeration; if a row there has no suite in this stage, one of the two is wrong.

- [ ] **T004** Define every `Protocol` in `src/intel_agent/ports/` per the port table in [agent-deps.md](./contracts/agent-deps.md) — that table is authoritative and this task does not restate it. Each carries its **stability tier** as a marker (AR-025a). Plus the shared types: `SecurityCtx`, `AgentDeps`, `Candidate`, `ToolSpec` (incl. `max_result_bytes`), `ToolResult` (incl. `truncated`), `CompletionRequest` (incl. `max_output_tokens`), `Completion` (incl. `finish_reason`), `Decision`, `ChannelCapabilities`, `InboundMessage`, `ErrorEnvelope`.
- [ ] **T004a** `scripts/check-port-tiers.py` (AR-025a): assert every `Protocol` in `ports/` declares a tier, that the tiers match the table in [agent-deps.md](./contracts/agent-deps.md), and that a signature change to a `Stable` port fails without a version bump. Wire into `make lint`.
- [ ] **T005** [P] `RetrievalServiceContract` in `conformance/retrieval.py` — asserts pre-filter not post-filter, empty result is not an error, `doc_ids` narrows only, and that a cross-tenant row is `not_found`.
- [ ] **T006** [P] `ToolRegistryContract` — allowlist enforced; **exactly one** audit entry per call including failures; **a call whose audit write fails does not run at all** (AR-019 — the audit is a precondition, not a side effect, so a `Recorder` outage refuses the dispatch rather than proceeding unaudited); in-process and MCP paths produce identical results and identical audit; `max_result_bytes` clips with `truncated: true` **and an in-band marker**, never a silently short list; a registered secret echoed by a tool comes back `[REDACTED]` in the result, the debug fragment, the event, and the audit entry; **capability gating** (AR-004b) — a `mutating`/`outward` tool is refused in the interactive form and refused in the durable form without a gate in its path, a tool whose `ToolSpec` **omits** `capability` is treated as `outward` and refused identically, and a `read_only` tool is unaffected in both forms.
- [ ] **T006a** [P] `LLMGatewayClientContract` — aliases resolve with no provider key; `deadline` refuses rather than overruns; a context-length refusal is a typed, **non-retried** outcome; `finish_reason == "length"` escalates `max_output_tokens` exactly once (8192 → 4×); `count_tokens` never under-reports; **every `Completion` carries the resolved concrete model** (AR-017a) and an implementation that omits it fails the suite; **no prompt or response body leaves the client unscrubbed** (AR-020) — a seeded PII sentinel in a prompt and in a response appears in no trace, eval record, or telemetry payload.
- [ ] **T006b** [P] `MemoryServiceContract` — write-time ownership stamping; read-time re-filtering against **current** clearance; **no autonomous write** (turn text alone produces no memory — a self-extracting backend fails this and must be bound with extraction disabled); **`delete` is scoped, audited, and complete** — a deleted memory never recalls again, a selector naming another tenant or another principal is **refused** rather than silently narrowed, the returned count matches what was removed, and a memory past `memory.retention_days` is not recalled **even before a sweep removes it** (the horizon is enforced at recall, so the guarantee holds between sweeps rather than after them).
- [ ] **T007** [P] `PolicyContract` — purity (same input, same decision; no I/O, no clock, no randomness); fail-closed on an unknown action.
- [ ] **T008** [P] `MeterContract` — `idem_key` honored; **zero** spend on refused, paused, and rejected runs; a ledger write is **readable back** (AR-035 — a `Meter` that accepts a spend and discards it passes an emit-only assertion and is exactly the hollow default the rule bans).
- [ ] **T009** [P] `ApprovalContract` — zero spend while pending; first decision wins; reject mutates nothing; decision is never derived from model output.
- [ ] **T009a** [P] `RecorderContract` — append-only; one entry per `record` call; **entries carry a `result_hash` and no body**; a failed write surfaces to the caller rather than being swallowed (T006 depends on this to refuse an unauditable dispatch).
- [ ] **T009b** [P] `StreamWriterContract` — events emit in the published vocabulary and schema version; an unbound writer degrades the run **observably** (`outcome="degraded"`) rather than completing clean; emission never blocks a node past its deadline.
- [ ] **T009c** [P] `CheckpointerContract` — write-then-read round-trips a checkpoint; a missing checkpoint is distinguishable from an empty one (the `checkpoint_lost` precondition); the `graph_version`/`state_schema_version` stamps survive the round trip.
- [ ] **T009d** [P] `BusContract` — `publish`/`subscribe` round-trip; queue-group fan-out delivers once per group; redelivery is at-least-once; `inprocess` satisfies the same suite as the brokered adapters.
- [ ] **T009e** [P] `IdentityBinderContract` — `bind` returning `None` **refuses** and never yields an anonymous or default identity; an unrecognized principal fails closed; a bound `SecurityCtx` carries the domain-agnostic core fully populated.
- [ ] **T009f** [P] `ErrorEnvelopeContract` (AR-036) — every error surface returns `{code, message, details}`; codes come from one registry; `refused`, `degraded`, and `failed` are machine-distinguishable **without parsing prose**; timestamps are ISO-8601 UTC and credits are integers.
- [ ] **T010** **`AccessFloorContract`** — the load-bearing one. A cross-tenant or above-clearance row is `not_found` under **all three** lowerings (two-store, single-store, and the Profile-C query-level floor), from one unmodified suite body. If this needs profile-specific branches, the boundary is wrong.
- [ ] **T011** [P] Fakes for every port in `conformance/fakes.py`, incl. `FakeGateway` with **scripted** responses covering: a well-formed answer, a tool call, malformed output, a raised exception, a `429` with `Retry-After`, a context-length refusal, a `finish_reason == "length"` truncation, and a stream that emits then disconnects. No test in the suite may reach a provider.
- [ ] **T012** Assert the fakes pass their own suites — proves the suites are satisfiable before any real backend exists.

## Stage 3: Manifest and composition

- [ ] **T013** Test: manifest load is deterministic (same row → same wiring) and **fails closed** on a missing or invalid field — no partial-permission agent.
- [ ] **T014** Test: two concurrent runs for different tenants on one worker share no manifest-derived state (no worker-global cache keyed off the first run).
- [ ] **T015** Implement `manifest/` — schema, validation, and resolution to `AgentDeps`.
- [ ] **T016** Implement `DomainPlugin` registration and the composition root. Wiring happens **only** here.
- [ ] **T017** Migrations for `agent_policies` and `agent_run` per [data-model.md](./data-model.md).

## Stage 4: Graph (against fakes, no infra)

- [ ] **T018** Test: node isolation — every node runs green with fake `AgentDeps` and no infra.
- [ ] **T019** Test: state immutability — no node other than `route` writes `intent`/`model_alias`; a run's `intent` is identical at `route` and at `generate`.
- [ ] **T020** Test: domain-agnostic `ctx` — AST scan proves no node dereferences `ctx["claims"]`; and the graph runs green end-to-end on a `claims` bag holding an opaque test-only key.
- [ ] **T021** Test: stable instruction prefix on **both** axes — (a) byte-identical across turns of a durable run, and (b) byte-identical **across two different principals on the same manifest** and across two wall-clock times. (b) is the one that catches the real cache-buster: a prefix embedding `principal`, `trace_id`, `stream_id`, or `datetime.now()` passes (a) perfectly while sharing no cache across runs. The prefix is keyed by `(manifest version, agent_role, allowed_tools)` and nothing else. Clearance-filtered memory, context, and `history_digest` are appended **after** it and re-evaluated every turn.
- [ ] **T021a** Test: **untrusted framing is exhaustive** — an injection sentinel planted separately in a retrieved chunk, an `attachment_text`, a `web_results` entry, a **memory**, and a `history_digest` reaches `generate` inside the delimiters in every case, and in no case causes a tool call, an allowlist change, or a citation outside `context`. The memory case asserts the cross-session shape: a sentinel written on turn 1 is still framed as data on turn 5, four turns after `guard` last saw it.
- [ ] **T021b** Test: compaction — first/last turns survive verbatim; the digest is **cumulative** (compact twice, assert the earliest turn's facts survive rather than degrading through a summary-of-summaries); the digest lands **after** the frozen prefix so T021 still passes; `history_digest` is never written to `MemoryService`.
- [ ] **T021c** Implement the **entrypoint context compactor** — keep-first/keep-last/summarize-middle against `history_token_budget`, measured via `count_tokens`, run **once** before `guard` so `route`/`rewrite`/`generate` all observe the identical `history`. Emits `degraded{reason:'history_compacted'}`, the `compaction` debug fragment, and `agent_context_compaction_total`.
- [ ] **T022** Test: streaming decoupling — `astream_events` yields tokens with **no** stream backend bound.
- [ ] **T022a** Test: **follow-up suggestions** (AR-012) — a successful answer yields 2–3 suggestions derived from the answer context; every suggestion is scoped to the caller's clearance (a suggestion never names a document the caller cannot read); and suggestions are **suppressed entirely** when the answer was refused or `source_count == 0`. The suppression case is the security-relevant half: a suggestion generated from a refused turn leaks what the refusal was about.
- [ ] **T022b** Test: **clarification shape** (AR-011) — a materially ambiguous question ends the turn in a clarification offering **2–4 concrete options plus an always-available free-text reply**, and the turn **ends there**: no retrieval, no generation, no spend past the branch. A clarification with one option, with five, or with no free-text escape fails. T059 measures how *often* clarification fires; this measures whether the thing that fires is usable.
- [ ] **T023** Implement `graph/state.py` (`AgentState`, `SecurityCtx`) and `graph/build.py`.
- [ ] **T024** Implement nodes: `guard`, `route`, `rewrite`, `retrieve`, `rerank`, `assemble`, `memory`, `generate`, `suggest`.
- [ ] **T025** Implement the `clarify` terminal node and the ambiguity branch (`route` is the graph's single conditional entry into it).
- [ ] **T025a** Test: **claim grounding is computed and reported** (AR-017b) — an answer whose every claim traces to a chunk in `context` reports `ungrounded_claims: 0` **present as a structural field** on `run_finished`, never absent (absent and zero must not be conflated, or an unmeasured run renders as a clean one); an answer carrying a claim absent from every cited chunk increments the count; the field survives a run with no debug fragment rendered, because a host that never opens a debug panel must still see it.
- [ ] **T025b** Implement **claim→source attribution** after `generate` (AR-017b): compute the count of answer claims not traceable to a retrieved source and emit it as `run_finished.ungrounded_claims`. Phase 1 **reports** the count; acting on it is a later phase, and reporting it is what gives that phase a baseline. This is the producer T060a and T071d both consume — until it exists, both are asserting against a field nothing writes.
- [ ] **T025c** Test: telemetry — exactly one start and one terminal record per executed node with the full correlation set; **leak assertion** (a sentinel planted in query, chunk, and memory appears in no log or metric label); **label assertion** (no metric label carries a tenant, principal, or id); **degradation assertion** (green with no exporter bound). Every one of these runs against fake deps with no infra, which is why it belongs here rather than three stages later — it used to sit in the reliability stage, constraining a wrapper that had already been built.
- [ ] **T026** Implement `telemetry/` — the instrumentation wrapper applied to **every** node at assembly. Constrained by T025c.
- [ ] **T026a** Test: **observability fragments are complete** (AR-017, SC-A05) — every executed node contributes its declared fragment per the table in [agent-graph.md](./contracts/agent-graph.md), and one answer's assembled trace carries intent, tool, index tier, access-filter result, scores, injected memory, resolved model, and token cost. A missing fragment fails the suite; rendering stays the host's concern.
- [ ] **T026b** Implement the per-node **observability fragments** (AR-017): each node emits its declared fragment into the run's `debug` payload. Distinct from T026, which emits logs and metrics (AR-018) — the debug panel is not telemetry and the two have different consumers, different cardinality rules, and different scrubbing paths.
- [ ] **T027** Implement run budgets: wall-clock deadline and step cap, evaluated at node boundaries, with **paused time excluded**.
- [ ] **T027a** Implement the **per-run cost ceiling** (AR-015b): `run_credits_cap` for the interactive form, `credits_cap` for the durable one, evaluated at the same node boundaries as the deadline against the `Meter`'s settled figure, propagated into the remaining-budget deadline handed to the gateway and `ToolRegistry`. Degrades past `assemble` under the deadline's rule (`degraded{reason:'budget_partial'}`), fails before it (`credits_exhausted`). Until this exists the interactive path's only spend bound is the daily budget — a 120s deadline bounds latency, and how much a run can buy inside it is a property of provider throughput, not of the run.
- [ ] **T027b** Implement **no-forward-progress detection** (AR-016b): fingerprint each durable step as a hash of `(node, rewritten_query, tool_calls added this step)`, write `step_fingerprint`/`no_progress_count` to state, and end the run `failed('no_progress')` after `max_no_progress_steps` consecutive identical fingerprints. Computed from state the step already wrote — **no extra model call**. The counter resets on any differing fingerprint; `max_steps` remains the bound for a run that oscillates between distinct states.

## Stage 5: Test doubles and dev harness (unblocks BOTH repos)

> **Moved to its execution position.** This stage used to sit near the end of the file while its own preamble said "do this early". Until `FakeAgentRuntime` exists, a host cannot build its transport, debug panel, chat UI, or billing path against anything real; and until a dev harness exists, nobody here can *watch* a run stream. These tasks are what make the two repos independently developable, so their value is highest **now** — before either side has improvised a substitute it will have to unwind.

- [ ] **T071a** Define the event vocabulary in `src/intel_agent/events.py` per [contracts/stream-events.md](./contracts/stream-events.md), with a `SCHEMA_VERSION`.
- [ ] **T071b** `intel_agent.testing.FakeAgentRuntime` — scripted, deterministic, same call surface as `build_graph(...)`. Scenarios: `CITED_ANSWER`, `REFUSAL`, `CLARIFICATION`, `GATE_PAUSE_RESUME`, `DEGRADED_RERANK`, `DEADLINE_DEFERRAL`, `DEADLINE_PARTIAL`, `HISTORY_COMPACTED`, `TRUNCATED_TOOL_RESULT`, `CONTEXT_WINDOW_EXCEEDED`, `CANCELLED`, `ERROR`. **Exported**, so a host never hand-rolls a second definition of the vocabulary.
- [ ] **T071c** `intel_agent.testing.golden/` — JSONL fixture per scenario. Assert the **real** graph (against `FakeGateway`) reproduces each, modulo nondeterministic ids. This is the check that keeps the double honest.
- [ ] **T071d** `StreamEventContract` — the nine ordering guarantees, **`ungrounded_claims` present and `0` rather than absent on a fully-grounded run** (produced by T025b), out-of-order/interleaved arrival, forward compatibility with an unknown future event **and an unknown `degraded.reason` / `run_finished.outcome` value**, **pause is not completion**, **`answer_generated: false` is not an answered question**, and no body in any payload.
- [ ] **T071e** `make dev` — a streaming CLI REPL. The default development loop: fast, scriptable, diffable, CI-friendly.
- [ ] **T071f** `make dev-ui` — the built-in chat UI: one self-contained page over SSE. **This is a product surface now** (AR-033), so constitution VIII and IX both apply: WCAG 2.1 AA (keyboard navigation, focus management, screen-reader labels) **and** the interactive-in-under-2.5s budget, asserted in CI against the golden fixtures rather than assumed. Still deliberately minimal and still a *reference consumer*: renders **only** from the published vocabulary and calls no bespoke endpoint. If it ever needs a special case, the vocabulary is missing something — fix the vocabulary, not the page.

## Stage 6: Reliability and failure behavior

- [ ] **T028** Test: fail-closed guard — a moderation timeout blocks the query, spends zero, and never reaches `retrieve`.
- [ ] **T029** Test: failure-injection matrix — every declared reliability policy is exercised by an **injected fault**, not merely written down: gateway `429`/timeout at each call site, **a gateway context-length (`413`-class) refusal at each call site** (→ `failed('context_window_exceeded')`, never an unclassified `error`, never retried), **a `finish_reason == "length"` truncation** (→ one `max_output_tokens` escalation, then surfaced), retrieval unavailable, rerank unavailable, memory unavailable, a tool raising, a tool returning malformed data, **a tool exceeding `max_result_bytes`** (→ clipped and marked, never silently dropped), empty retrieval (**not** a failure), a vision call failing past cutoff, and the checkpointer unavailable mid-run. Each asserts the specified outcome **and** that the degradation was recorded.
- [ ] **T030** Test: budget boundaries — a deadline breach **before `assemble`** ends `failed('deadline_exceeded')` at a node boundary with spend settled; one **at or after `assemble`** finishes `outcome='degraded'` with `degraded{reason:'deadline_partial'}` and either an answer or citations with `answer_generated: false` — **never `ok`, never nothing, never a citations-only result dressed as an answer** — with `agent_budget_exhausted_total{boundary="deadline"}` incremented in both cases; a durable run past `max_steps` ends `step_cap_exceeded`; a gate held past the deadline still resumes cleanly.
- [ ] **T030a** Test: **per-run cost ceiling** — a scripted `FakeGateway` returns a usage figure that crosses `run_credits_cap` at a chosen call site, exercised at **each** of `route`, `rewrite`, `rerank`, and `generate` rather than only the cheapest. Before `assemble` → `failed('credits_exhausted')`; at or after → `outcome='degraded'` with `degraded{reason:'budget_partial'}`, never `ok`, never a citations-only result dressed as an answer; `agent_budget_exhausted_total{boundary="credits_cap"}` increments in both cases. A run under the cap is unaffected; a manifest omitting the cap fails validation closed rather than running uncapped.
- [ ] **T030b** Test: **no forward progress** — a durable run scripted to re-enter with an identical fingerprint ends `failed('no_progress')` **before** `max_steps` would have fired, spend settled, `agent_budget_exhausted_total{boundary="no_progress"}` incremented. Both negative cases carry equal weight: a differing fingerprint on any step **resets** the counter and the run continues to `max_steps` or completion, and two re-entries with `source_count == 0` but a **changed** `rewritten_query` are **not** flagged — empty retrieval is a valid answer state, and repetition rather than emptiness is the signal.
- [ ] **T030c** Implement the deadline-degrade path: `generate` under the remaining budget past `assemble`, falling back to citations + the structural not-generated marker when the budget is already gone. The cost-ceiling breach (T027a) shares this path — one degrade implementation, two boundaries feeding it, both tested above before either is built.
> **T031's telemetry assertions moved to T025c**, in Stage 4, so they precede the wrapper they constrain (T026). The ID is retired in place rather than reused — `T031a` below is referenced by [agent-graph.md](./contracts/agent-graph.md) and by T045c, and recycling `T031` for something else is how a cross-file reference starts pointing at the wrong task.

- [ ] **T031a** `scripts/check-node-io.py`: **generate** the node read/write table from the `graph/nodes/` signatures and diff it against the table in [agent-graph.md](./contracts/agent-graph.md); fail on drift. That table already fell three keys behind (`doc_ids`, `attachment_text`, `image_refs`) and lost a reader entirely (`web_results`) while every prose section was correct — a hand-maintained authority is one that will drift again. Wire into `make lint`.
- [ ] **T031b** Test: **the terminal-state vocabulary is closed** (SC-A06a) — enumerate every way a run can end and assert each maps to a **named** boundary (completion, refusal, clarification, `deadline_exceeded`, `credits_exhausted`, `step_cap_exceeded`, `no_progress`, `context_window_exceeded`, `checkpoint_lost`, `checkpoint_incompatible`, `cancelled`, explicit failure). A run that terminates outside the enum fails the test, and **no interactive run may end bounded only by the daily budget**. Individually each boundary is covered by T029/T030/T030a/T030b; this is the assertion that none was forgotten, which is the property SC-A06a actually states.
- [ ] **T032** Implement the per-node reliability policy and degradation recording.
- [ ] **T032a** Implement the **canonical error envelope** (AR-036, constitution VIII): one `{code, message, details}` shape and one error-code registry across every surface — port errors, terminal run states, CLI exit payloads, and the SSE error event — with `refused` / `degraded` / `failed` machine-distinguishable without parsing prose. Constrained by `ErrorEnvelopeContract` (T009f).

## Stage 7: Tools and human-in-the-loop

- [ ] **T033** Test: in-process and MCP tool parity — identical result and identical audit entry for the same call.
- [ ] **T034** Test: human gate — a run reaching a gate interrupts, spends **zero** while paused, resumes **exactly once** on approval (no settled node re-runs, no re-spend), and short-circuits on reject without mutating the subject.
- [ ] **T035** Test: action tools — the web-search tool performs **no fetch** until its gate is approved; the note-edit tool commits only after approval **and** a permit check, is denied above clearance or outside tenant, is denied if it would raise an access level above the source floor, and refuses creation outright.
- [ ] **T036** Implement `tools/` — the `ToolRegistry` port with `inprocess` and `mcp_client` bindings, sharing one policy wrapper. The wrapper enforces `max_result_bytes` (256 KB Categories A/B, 64 KB per `web_search` result) and runs the **credential scrubber** — static patterns plus a dynamic registry of the deployment's bound secrets — before any result reaches a prompt, a debug fragment, an event, or an audit entry. Always on, no config flag. Constrained by `ToolRegistryContract` (T006).
- [ ] **T036a** Test: the **capability budget** end-to-end — a fixture remote MCP catalog advertising a `send_message`-shaped tool is mounted by manifest alone; the graph refuses to dispatch it in the interactive form and routes it through `human_gate` in the durable form, and a rejected gate performs no send. Second case: the same catalog with the `capability` field **stripped** produces the identical refusal, proving the fail-closed default rather than assuming a well-behaved third party. This test is the reason AR-004b exists — assert it against a catalog the repo does not control.
- [ ] **T036b** Implement **capability gating** in that same wrapper (AR-004b): every `ToolSpec` carries `capability: read_only | mutating | outward`; a `mutating`/`outward` dispatch is refused outside the durable form and refused without a `human_gate` in its path; an **absent** declaration resolves to `outward`. Applies to the remote catalog a `mcp_client` binding mounts, not only to the ten first-party tools — which is the point, since that is the path where a config-only change can otherwise hand an ungated outward reach to a run already holding private data and untrusted content (research §14).
- [ ] **T037** Implement the read-only tool tier.
- [ ] **T038** Implement the `human_gate` node and the resume path.
- [ ] **T039** Implement the two HITL-gated action tools.

## Stage 8: Backends

- [ ] **T040** [P] Implement `retrieval/pgvector.py` — dense HNSW + a lexical companion + RRF. **Retrieval-quality parity is the work here**, not the authz floor. Must pass `RetrievalServiceContract` and `AccessFloorContract`.
- [ ] **T041** [P] Implement `retrieval/qdrant.py` — hybrid + payload pre-filter. Same two suites.
- [ ] **T042** [P] Implement `bus/` — `inprocess`, `redis_streams`, `jetstream` adapters. All three must pass `BusContract` (T009d).
- [ ] **T043** [P] Implement `gateway/` — the OpenAI-wire client with alias resolution, deadline propagation, one-hop fallback, `count_tokens`, `max_output_tokens` defaulting to 8192 with a single 4× escalation on `finish_reason == "length"`, and a **typed, non-retried** context-length refusal. Must pass `LLMGatewayClientContract`.
- [ ] **T043a** Record the **resolved model** per call (AR-017a): `Completion.model` flows into the Langfuse trace and the `cost.calls[]` debug fragment. Two negative assertions, both mechanical: an AST scan proves **no node reads it** (routing stays alias-only, or the port's portability is gone), and the metric-label assertion in T025c already fails if it reaches an instrument — a provider's dated snapshot ids are exactly the unbounded label that melts a metrics backend. Without this, a gateway remap changes answers while `graph_version`, the prompt prefix, the manifest, and every fixture stay byte-identical, and the regression has nothing to diff.
- [ ] **T043b** Implement the **PII scrubber on the model-call path** (AR-020): prompts and responses are scrubbed before they reach a trace, a Langfuse span, or an evaluation store, and **no raw body is written to telemetry** — logs and metrics carry refs and hashes only, and no metric label carries a tenant, principal, or id. This is the model-call chokepoint and it is distinct from T036's credential scrubber, which covers tool output: **tool results never traverse this path**, which is exactly why AR-020a exists as a separate requirement. Constrained by `LLMGatewayClientContract` (T006a) and the leak/label assertions in T025c.
- [ ] **T044** [P] Implement `memory/` — Mem0 backend plus a no-op, with write-time stamping, **read-time re-filtering against current clearance**, and **auto-extraction disabled** (a backend that persists facts from turn text on its own is making the autonomous write research §13 excludes). Recalled memories are handed to `generate` already delimited as untrusted content. Must pass `MemoryServiceContract`. The no-op is an explicit `memory.kind: none` binding that records `degraded`, **not** a shipped default that silently passes (AR-035).
- [ ] **T044a** Implement `MemoryService.delete` (AR-003b) across both backends: selectors by `memory_ids`, `principal`, and `written_before`; scoped by `ctx` so a selector cannot reach outside the caller's tenant; audited through `Recorder` with the selector and the returned count; refuses a selector it cannot honor in full rather than silently narrowing it. This is the removal half of the untrusted-memory argument — until it exists, a memory found to carry an injection stays on the replay path for the life of the account.
- [ ] **T044b** Implement the **retention horizon** at recall: `memory.retention_days` filters at read time, not only in a sweep, so a memory past the horizon is never recalled between cleanup runs. `null` is unbounded and must be a manifest value a deployment set deliberately, not an omission that defaults to forever.
- [ ] **T044c** `intel-agent memory forget --principal <p> [--before <ts>] [--id <id>]` CLI over the same port call, so erasure is operable on the standalone profile without writing code — the counterpart to `T057l`'s ingest CLI. A capability reachable only from Python is one a running deployment does not have.
- [ ] **T045** Implement checkpointing and resume, incl. explicit `checkpoint_lost` on a pointer whose checkpoint is gone. Must pass `CheckpointerContract` (T009c).
- [ ] **T045a** Implement **checkpoint version compatibility** (AR-016a): stamp `graph_version` (build SHA) and `state_schema_version` (an integer bumped by any change to the `AgentState` keys or the node set) into the `agent_run.state` pointer at write time, and compare on resume — differing schema version → `failed('checkpoint_incompatible')` with both versions in `debug`; differing SHA alone → recorded, resumes. A pointer that predates the stamps cannot be compared and fails **closed**, not open.
- [ ] **T045b** Test: **resume across a deploy** — a run paused at `human_gate` under schema version N and resumed by a worker declaring N+1 ends `checkpoint_incompatible` and does **not** execute a further node; the same run resumed under N with a different SHA resumes normally and completes. This second assertion is what keeps the rule from making every ordinary deploy a run-killer, so it is not optional. Third case: the approver's decision survives on the `approval_request` when the run behind it fails, so resolving a gate is never lost work.
- [ ] **T045c** `scripts/check-state-schema-version.py`: assert `state_schema_version` is bumped in the same commit as any change to the `AgentState` keys or the node set (diffed against the generated node I/O table from T031a). Wire into `make lint`. The version is only load-bearing if forgetting to bump it fails a gate — and forgetting is the default, since the change that requires the bump lives in a different file from the constant.
- [ ] **T045d** Test: **cancellation** (AR-014, SC-A06) — a `queued` or `running` durable run marked `cancelling` reaches `cancelled` at the **next node boundary** with spend settled and no partial side effect; a run `cancelling` while **paused at a human gate** cancels without executing the gated action and without waiting on the approver; a cancelled run is **not** resumable and reports `cancelled` rather than a generic failure; and cancelling an already-terminal run is a no-op, not an error. Mid-node cancellation is explicitly not offered — it would leave spend unreconciled, which is the same reason deadlines are evaluated at boundaries.
- [ ] **T045e** Implement cancellation: the `cancelling` → `cancelled` transition on `agent_run`, the boundary check alongside the deadline and cost-ceiling checks (T027/T027a — one boundary evaluation, now three reasons feeding it), and the terminal event. SC-A06 reads "resumes and completes — **or cancels cleanly**", and until this exists only the first half is built.
- [ ] **T046** Implement `retrieval` doc-id scoping — conjoins a document term onto the predicate; narrows only.
- [ ] **T047** Implement the query-time vision path, treating image bytes as untrusted input.

## Stage 9: Second-domain and profile proofs

> These are the tasks that make the repo's central claims *checked* rather than asserted. If the schedule slips, these are the last things to cut, not the first.

- [ ] **T048** **Second-domain reuse test**: a test-only plugin (different tools, a `per_customer` policy) plus its manifest runs the **unmodified** graph green end-to-end.
- [ ] **T049** **Profile-B swap test**: the graph runs green with the **production** pgvector backend and an in-process bus — no vector-DB and no broker client bound.
- [ ] **T050** **Access floor is profile-invariant**: `AccessFloorContract` passes **unchanged** under the single-store wiring.
- [ ] **T051** **Config-only remote-tool-source test**: the unmodified graph consumes a remote MCP server as its tool source, with enforcement staying at that server's boundary.
- [ ] **T052** Channel-adapter swap: attaching a second transport adapter changes no node and no graph output on a golden query.
- [ ] **T053** Additivity: adding a no-op **corrective-retrieval / answer-faithfulness grading stub** at the insertion points reserved in [research.md §6](./research.md) — after `memory` before `generate`, and after `generate` before `suggest` — changes no existing node's output on a golden query. The stub is the test that proves the seam is additive; the graders themselves are deliberately deferred (research §6), and this task builds no grading logic.

## Stage 10: Standalone profile

- [ ] **T054** Write `deploy/compose.profile-b.yml` — postgres+pgvector, redis, an OpenAI-wire gateway. No vector DB, no broker.
- [ ] **T055** Implement the Profile-B entrypoint: sets the store's tenant context per request and runs the guard, tool-policy, and metering wrappers **inside the single container** — the obligations a full host's kernel would otherwise satisfy.
- [ ] **T056** `make smoke` — a cited answer end-to-end on the standalone topology, seeded through the built-in ingestor (T057h) so the smoke exercises the path a first-time user actually walks.
- [ ] **T057** Wire `scripts/assert-profile-b-isolation.sh` into CI as a required gate.

### Profile C — the minimal shape

- [ ] **T057a** Implement `retrieval/sqlite.py` — dense + FTS5 + RRF. Must pass `RetrievalServiceContract` **and** `AccessFloorContract`.
- [ ] **T057b** Emit a **startup warning** whenever `retrieval.kind: sqlite` is bound, naming the reduced floor explicitly (predicate enforced by the query, not the engine; single-tenant only). A deployment must never arrive at Profile C by accident.
- [ ] **T057c** SQLite bindings for the whole one-file shape: the `Checkpointer`, **and the default `Meter`'s local ledger writing to that same file** — Profile C is one container with one file, not an unmetered one. `make up-c && make smoke-c` runs the whole agent with no Postgres, no Redis, no bus. **There is no `NoOpMeter`**: AR-035 names the `Meter` specifically, `agent-deps.md` marks it *required — never silently unmetered*, and T008/T057f both fail against a meter that discards. A shape this minimal is exactly where an unmetered run would go unnoticed.
- [ ] **T057d** Test: the `sqlite` backend refuses to start when the manifest declares more than one tenant, or when `AccessFloorContract` is run in multi-principal mode. **Fail closed rather than silently offering a weaker floor** to a deployment that needs the strong one.

## Stage 11: Standalone product defaults

> These are what make the repo a **product** rather than a library. Each is a *default implementation of a declared port* — never privileged code — and each is held to the same conformance suite an override must pass (AR-034).
>
> **The two tests come first**, before any default exists. A no-hollow-defaults test written after the defaults documents whatever got built; written before, it constrains them — which is the whole argument of AR-035, applied to its own stage.

- [ ] **T057e** Define the `Ingestor` port + `IngestorContract` per [contracts/agent-deps.md](./contracts/agent-deps.md): ownership stamped from `ctx`, unowned content **rejected**, idempotent by content hash, source treated as untrusted.
- [ ] **T057f** **No-hollow-defaults test** (AR-035): assert that no shipped default is a no-op — the `Meter` default records a spend that is then **readable back**, the moderation default actually rejects a seeded disallowed input, the `Recorder` default produces a readable entry, and the `IdentityBinder` default refuses an unrecognized principal. A default that silently passes must fail this test. Runs against **every** profile binding, including Profile C (T057c).
- [ ] **T057g** **Default-swap test** (AR-034): replace each default (ingestor, identity, meter, recorder, UI) with a second implementation of the same port; the conformance suite passes and **no graph node changes**. This is the test that keeps a default from quietly becoming privileged.
- [ ] **T057h** [P] Default `Ingestor`: files, URLs, raw text → chunk → embed → store. Deliberately minimal; the reference host keeps its full pipeline and binds that instead.
- [ ] **T057i** [P] Default `IdentityBinder`: single-user and explicit-user-list modes, **failing closed** on an unrecognized principal. Never a default that authenticates nobody and authorizes everybody. **Scope**: this is the standalone CLI/UI binder (AR-032). It is deliberately **not** wired to any `Channel` — a platform identity (a Discord snowflake, a Slack `(team_id, user_id)`) maps to a principal in a way only the deployment knows, so a channel deployment supplies its own binder (AR-026, T070) and an unmapped platform user is refused. Defaulting a chat platform to the single-user binder would hand every stranger in a public server the owner's clearance.
- [ ] **T057j** [P] Default `Meter`: a **real local usage ledger** — tokens, cost, per principal, idempotent by `idem_key`, queryable from the CLI. Not a counter that discards. Backed by Postgres on Profile B and by the one SQLite file on Profile C (T057c).
- [ ] **T057k** [P] Default moderation behind `guard`: a **real check** via the gateway's moderation endpoint, fail-closed on timeout or error. No stub that returns `allow`.
- [ ] **T057l** `intel-agent ingest <path|url>` CLI plus an ingest view in the built-in UI, so a corpus can be built without writing code — the counterpart to `T044c`'s forget CLI, and the step `make smoke` (T056) and the quickstart both depend on.

## Stage 12: Evaluation

- [ ] **T058** Eval seed set: ≥20 prompt cases and ≥30 golden queries, including the **hard access-filter assertion** (a query that would match an above-clearance document returns nothing from it).
- [ ] **T059** Clarification-rate eval — asserts ≤10% on unambiguous golden queries.
- [ ] **T060** Retrieval-quality eval — recall and MRR thresholds per SC-A03, run against **all three** retrieval backends so a backend swap cannot quietly regress quality.
- [ ] **T060a** **Answer-grounding eval** (AR-021a): assert **≥ 95% grounded claims** across the golden set, read from `run_finished.ungrounded_claims` — the runtime's own computed grounding (produced by T025b), from the **published vocabulary**, so the eval measures what a host measures and needs no LLM judge to be calibrated or defended. Retrieval recall says the right chunk was *found*; nothing until now said the answer was *built from it*.
- [ ] **T060b** Run the eval suite **N = 5 times with a ≥ 80% (4-of-5) pass-rate threshold** rather than once pass/fail, and record **tokens and cost per case** in its report. A stochastic system graded once reports a coin flip, and a flaky gate is a gate someone disables; a prompt change that halves latency while doubling spend must be visible in the same run that shows it was harmless. The three numbers here (95% grounded, N=5, 4-of-5) are stated in AR-021a and are release-gating — change them there, not here.
- [ ] **T060c** Gate the suite on **prompt, manifest, and model-alias changes** in CI, not only on code. Prompts are production config: they live in `prompts/` assets a manifest names, so today they can change without a single Python line changing and without the eval suite running. Pair the gate with T043a's resolved-model record so a regression can be attributed to a *gateway remap* rather than only to a repo commit — a change this repo can otherwise neither see nor blame. Wired into the gate order from T002a.
- [ ] **T061** Implement the **incident→regression loop**: a `evals/regressions/` directory where every observed agent-behavior defect is added as a permanent case, reproduced from its recorded trace, **before** its fix counts as complete.

## Stage 13: Chat channels (Phase 2 — port fixed now, adapters later)

> The `Channel` port, its capability model, and the `IdentityBinder` split are settled in [contracts/channels.md](./contracts/channels.md), so these are **additive**: no node changes, no boundary change.
>
> **Scope**: `T065` and `T066` — the contract and the generic runner — land in Phase 1 so the port cannot drift before an adapter argues with it. **`T067`–`T069` are Phase 2 deliverables** and are out of the Phase-1 slice; they are listed here so the capability model is designed against three real platforms rather than one.
>
> **Do WeChat second, not last.** It is the platform that cannot stream and must answer in ~5s. Building Discord and Slack first and bolting WeChat on at the end produces a `ChannelRunner` shaped entirely around streaming — which is the failure this capability model exists to prevent. Discord proves the happy path; WeChat proves the model.

- [ ] **T065** [P] `ChannelContract` in `conformance/channels.py` — capabilities honest, unknown identity refuses, deadline defers rather than truncates, chunking lossless, scope isolation, channel-blind graph output, no SDK leak.
- [ ] **T066** Implement `ChannelRunner` — the generic glue: `listen` → `bind` → refuse-if-`None` → build `ctx` + namespaced `thread_id` → `astream_events` → platform writer. **All capability adaptation lives here**, so adapters stay thin protocol shims.
- [ ] **T067** [P] *(Phase 2)* Discord adapter (`intel-agent[discord]`) — gateway WS, 2000-char chunking, streaming by message edit with rate-limit-aware interval, DM vs guild scope.
- [ ] **T068** [P] *(Phase 2)* WeChat Official Account adapter (`intel-agent[wechat]`) — HTTP callback, AES-decrypt + signature verify, **no streaming**, ~5s deadline with the deferral path, and the customer-service late reply inside its 48h window. Document **which account type** is targeted; capabilities differ by type and verification status.
- [ ] **T069** [P] *(Phase 2)* Slack adapter (`intel-agent[slack]`) — Socket Mode, `chat.update` streaming, `thread_ts` continuity, `(team_id, user_id)` identity key.
- [ ] **T070** Reference **channel** `IdentityBinder` implementations for the docs: a **single-user** binder (~5 lines, the personal-agent case) and a **directory-backed** multi-tenant one. Both are examples for the *platform-identity* mapping, which is host-supplied by AR-026 — the runtime ships **no channel binder**, because mapping a platform account to a principal is knowledge only the deployment has and a wrong answer there is a privilege escalation. This does not contradict AR-032: the runtime *does* ship a default binder for the standalone CLI/UI surface (T057i), and that default is deliberately not reachable from a `Channel`.

## Stage 14: Release

- [ ] **T062** Package `conformance/` as public API; verify it survives a wheel build and is importable from a clean venv.
- [ ] **T063** Tag `v0.1.0`; verify a host can resolve it by git ref and subclass the suites.
- [ ] **T064** Document the upgrade contract in [host-integration.md](./contracts/host-integration.md) §Versioning: a port change lands **before** the host PR that consumes it.

---

## Dependencies

```
Stage 1 ─► Stage 2 (ports+conformance) ─► Stage 3 (manifest) ─► Stage 4 (graph)
                                                                    │
                                                                    ▼
                                                     Stage 5 (test doubles + harness)
                                                                    │
                        ┌───────────────────────────────────────────┤
                        ▼                     ▼                     ▼
                   Stage 6 (reliability)  Stage 7 (tools/HITL)  Stage 8 (backends)
                        └─────────────────────┴─────────────────────┘
                                              ▼
                                   Stage 9 (proofs) ─► Stage 10 (standalone)
                                              ▼
                                   Stage 11 (product defaults)
                                              ▼
                                   Stage 12 (evals) ─► Stage 14 (release)

Stage 13 (channels, Phase 2) hangs off Stage 4 + Stage 10: it needs a runnable
graph and the standalone entrypoint, but nothing from evals or release.
```

Stage 2 blocks everything: the suites are the specification. **Stage 5 sits directly after the graph on purpose** — it is what lets a host build against something real while Stages 6–8 proceed here, and it is the one stage whose value decays if it slips. Stages 6–8 parallelize once the graph exists. Stage 9 needs both a real backend (T040) and the graph. **Stage 11 precedes Stage 12** because an eval set needs a corpus, and the built-in ingestor (T057h) is how a standalone deployment builds one.

**Minimum viable slice**: Stages 1–4, plus T040 (a real retrieval backend), T057e/T057h/T057l (an ingestor and a way to feed it), T057i (a binder that refuses strangers), T057j (a meter that records), and T054–T056 — a standalone runtime that ingests a folder and answers a cited question about it. Everything after hardens or proves it.

> **Why the slice includes four Stage-11 tasks.** An earlier revision listed only Stages 1–4 + T040 + T054–T056 and called that "a standalone runtime that answers a cited question". It is not: with no `Ingestor` there is no corpus to answer *from*, and AR-035 makes the runtime **fail to start** without a real `Meter` binding rather than run unmetered. The slice has to include the parts that make a first answer reachable from nothing, or "standalone" is a claim the smoke test cannot make.

---

## Traceability to aisat-intel

Each row maps a local task to the upstream ID it replaces. Those IDs are **retired in place** in aisat-intel — never renumbered, because `dispatch-prompts.md` (91 references), `track-manifest.md` (55), and the `runs/*.json` orchestration records all address tasks by number.

**Every local task appears in this table.** A task with no upstream counterpart carries `—` and a reason; an absent row used to mean "we forgot", which is indistinguishable from "nothing upstream" exactly where it matters most — the tasks this repo added.

| Local | Retires (aisat-intel) | Note |
|---|---|---|
| T001, T002, T003 | — | new: package skeleton, toolchain, and the import-boundary scan; upstream had no port layer to police |
| T002a | — | **new** — the constitution's CI gate order, the 80% coverage floor, and the security scan, encoded rather than described |
| T003a, T003b | — | **new** — doc-anchor gate and the standing lint debt; both are gates on a specs-only checkout |
| T004 | — | new: ports were implicit across three contracts, now one surface |
| T004a | — | **new** — port-tier check; tiers introduced so Phase-2 ports are not frozen before an adapter argues with them |
| T005–T012 | T149 (approval conformance) | broadened from one port to every port on the read/run path |
| T006a, T006b | — | **new** — gateway and memory had ports but no suites; the memory suite carries the no-autonomous-write rule |
| T009a–T009e | — | **new** — suites for `Recorder`, `StreamWriter`, `Checkpointer`, `Bus`, and `IdentityBinder`. AR-025 says *every* port ships one; these five were the gap between that sentence and the stage |
| T009f | — | **new** — the canonical error envelope (AR-036) had a constitution principle and no contract test |
| T013–T016 | T060c | manifest determinism + second-domain seam |
| T017 | T113 (partial) | only `agent_policies` + `agent_run`; upstream keeps the kernel tables |
| T018–T027 | T073, T073a–T073d, T060b | graph, ToolRegistry port, clarify, telemetry, budgets |
| T021a | — | **new** — untrusted framing was specified for retrieved content only; memory and the history digest were uncovered |
| T021b, T021c | — | **new** — `history` was the one unbounded input; upstream bounded it in a chat-session layer that stayed there |
| T022a | — | **new** — AR-012's suggestion rules (count, clearance scope, suppression on refusal) had an implementation and no test |
| T025a, T025b | — | **new** — the producer for `ungrounded_claims`. Grounding was computed for a debug panel upstream; here it is a structural field, and two consumers were asserting against a field nothing wrote |
| T026a, T026b | — | **new** — the per-node debug fragments (AR-017) as distinct from telemetry (AR-018); different consumers, different cardinality rules, different scrubbing |
| T027a, T030a | — | **new** — per-run cost ceiling. The interactive form had a latency bound and no cost bound; its ceiling was whatever the daily budget still held |
| T027b, T030b | — | **new** — no-forward-progress detection. `max_steps` bounded repetition without detecting it, so a run looping on one action exhausted its cap and settled |
| T028–T032 | T060i | failure matrix, budgets, telemetry assertions |
| T030c | — | **new** — deadline degrade past `assemble`, so a breach one node short of an answer does not discard four settled gateway calls |
| T031a | — | **new** — generate the node I/O table; the hand-maintained one had already drifted four keys |
| T031b | — | **new** — SC-A06a's *exhaustiveness*. Each boundary was tested; nothing asserted the vocabulary was closed |
| T032a | — | **new** — the `{code,message,details}` envelope and its code registry (AR-036, constitution VIII) |
| T033–T039 | T028 (mcp bootstrap), T070–T072a, T120a, T120b | tools + HITL + action tools |
| T036a, T036b | — | **new** — capability gating. Every rule about a remote tool source governed the access floor; none governed what those tools do |
| T040 | T034a, T065a, T065b | pgvector backend + doc-id scoping |
| T041 | T065a (qdrant half) | |
| T042 | T029a | Bus port |
| T043 | — | gateway client (upstream's lived in the shared Python tier) |
| T043a | — | **new** — resolved-model record. Alias indirection made model choice invisible to the runtime's own forensics, not only to its routing |
| T043b | — | **new** — AR-020's PII scrubbing had test assertions (T025c) and no implementation; upstream's lived in the host's gateway tier |
| T044 | T068 | Mem0 + clearance re-filter |
| T044a–T044c | — | **new** — memory deletion + retention. The upstream port carried `recall` and `write` and no way to end a memory's life, on the one surface that replays into every future prompt |
| T045 | T111, T120 | checkpoint/resume + long-horizon worker |
| T045a–T045c | — | **new** — checkpoint version compatibility. The upstream rule covered the *missing* checkpoint; a gate that pauses for days makes the *stale* one ordinary, and that resume fails silently |
| T045d, T045e | — | **new** — cancellation. AR-014 and SC-A06 both require it and no task built it; `agent_run` already carried `cancelling`/`cancelled` with nothing to write them |
| T046 | T065b | |
| T047 | T066a | query-time vision |
| T048 | T060c | second-domain reuse |
| T049 | T060d | Profile-B swap |
| T050 | T060d (floor half) | profile-invariant access |
| T051 | T060g | config-only MCP client |
| T052 | — | **new** — channel-adapter swap; no upstream counterpart, chat platforms were never in its scope |
| T053 | — | additivity regression against research §6's reserved grading seams |
| T054–T057 | T060e, T060f | Profile-B entrypoint + smoke |
| T057a–T057d | — | **new** — Profile C. No upstream counterpart: the reference host is multi-tenant by construction and could never have offered this shape |
| T057e–T057l | FR-001–FR-006, FR-008 (ingestion); FR-025–FR-027 (identity) | **product defaults** — a *minimal* ingestor, binder, meter, and moderation live here so the agent is standalone; the reference host keeps its full pipeline and overrides. T057f/T057g (the no-hollow and swap tests) are **new** — the rules that keep a default from becoming privileged code |
| T058–T061 | T125, T125a | eval seed + incident→regression loop |
| T060a–T060c | — | **new** — answer-grounding eval, pass-rate over N runs, and an eval gate on prompt/manifest/alias changes. The stage measured retrieval and ran once |
| T062–T064 | — | new: cross-repo release contract |
| T065, T066, T070 | — | **new** — the `Channel` port, the generic runner, and the host-supplied platform-identity binders |
| T067–T069 | — | **new, Phase 2** — Discord / WeChat / Slack adapters; no upstream counterpart, the reference host reaches users over its own web SSE transport |
| T071a–T071f | — | **new** — the event vocabulary, `FakeAgentRuntime`, golden fixtures, `StreamEventContract`, and the two dev harnesses. Upstream's host and runtime were one repo, so neither needed a double of the other |

> **Reading the numbers.** Local IDs (`T001`+) and aisat-intel IDs share a numeric space and **do overlap** — local `T069` is the Slack adapter, upstream `T069` is the semantic cache. Upstream IDs are always written `aisat-intel Txxx` outside this table; inside it, the left column is local and the middle column is upstream.

**Upstream tasks that stay upstream** (host surface, no counterpart here): `aisat-intel T069` (semantic cache — a host-side hot path), `aisat-intel T074` (prompt assets ship here but are authored against the host's response format), `aisat-intel T075` (query router + Redis stream adapter — transport), `aisat-intel T077a/T077b` (suggestion SSE event + UI), `aisat-intel T101/T101b` (debug-panel assembly and streaming — the runtime emits fragments, the host renders), `aisat-intel T062a–T062d` and `T076a/T076b` (chat sessions — host), `aisat-intel T030` (BAML/observability bootstrap — split).

> **T069, T074, T075, T101 are the four worth a second look at integration time.** Each is genuinely split: the runtime owns the emission and the host owns the surface, so both repos carry half a task. They are the most likely place for a gap to hide.
