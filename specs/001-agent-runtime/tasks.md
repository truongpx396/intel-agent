<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/tasks.md).
     FRESH T001… series. The mapping table at the bottom is authoritative for
     tracing any task back to the aisat-intel ID it replaces; those IDs are
     retired in place upstream (never renumbered — dispatch-prompts.md and
     track-manifest.md reference them by number, as do the runs/ records). -->

# Tasks: Self-Contained Agent Runtime

**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Ports**: [contracts/agent-deps.md](./contracts/agent-deps.md)

## Format

`[ID] [P?] Description` — `[P]` means parallelizable (different files, no shared state).

**TDD is non-negotiable** (constitution VI): within every stage, the test tasks precede their implementation tasks and MUST fail first. A conformance suite is written **before** the backend it constrains — that ordering is what makes the suite a specification rather than a description of whatever got built.

---

## Stage 1: Setup

- [ ] **T001** Initialize the package skeleton: `src/intel_agent/{ports,graph,retrieval,memory,tools,gateway,bus,manifest,telemetry,channels,conformance}/__init__.py`, `tests/{unit,integration,conformance,smoke}/`.
- [ ] **T002** [P] Wire ruff + black + mypy to the settings already in `pyproject.toml`; confirm `make lint` and `make typecheck` are green on the empty tree.
- [ ] **T003** [P] Add `scripts/check-import-boundaries.py`: an AST scan asserting no module under `graph/` imports a concrete backend (`qdrant_client`, `nats`, `redis`, provider SDKs) and no module under `ports/` imports any implementation. Wire into `make lint`.
- [ ] **T003a** [P] Add `scripts/check-anchors.sh` and fold it into `make check-docs`. `check-links.sh` deliberately strips the `#fragment` and asserts only that the *file* exists, which leaves the likelier rot uncovered: a heading gets reworded (`FR-028a` → `AR-015`; "one MCP server" → "a `ToolRegistry` port"), every link still resolves to a real file, and the reader silently lands at the top of a 400-line contract instead of at the section that was promised. Five such anchors were already dead when this task was written — two of them predating the change that found them — which is the argument for the gate rather than another round of manual fixes.
- [ ] **T003b** [P] Fix the 108 pre-existing `ruff` findings in `src/intel_agent/{ports,conformance}/__init__.py` so `make ci` is green again. It is **currently red at `HEAD`**, which makes the README's "green on a specs-only checkout" claim stale and, worse, means the gate cannot distinguish a new break from the standing one.

## Stage 2: Ports and conformance (blocking — everything depends on these)

> The suites land **before** any real backend. A suite written after its implementation documents the implementation; a suite written before it constrains one.

- [ ] **T004** Define every `Protocol` in `src/intel_agent/ports/` per the port table in [agent-deps.md](./contracts/agent-deps.md) — that table is authoritative and this task does not restate it. Each carries its **stability tier** as a marker. Plus the shared types: `SecurityCtx`, `AgentDeps`, `Candidate`, `ToolSpec` (incl. `max_result_bytes`), `ToolResult` (incl. `truncated`), `CompletionRequest` (incl. `max_output_tokens`), `Completion` (incl. `finish_reason`), `Decision`, `ChannelCapabilities`, `InboundMessage`.
- [ ] **T004a** `scripts/check-port-tiers.py`: assert every `Protocol` in `ports/` declares a tier, that the tiers match the table in [agent-deps.md](./contracts/agent-deps.md), and that a signature change to a `Stable` port fails without a version bump. Wire into `make lint`.
- [ ] **T005** [P] `RetrievalServiceContract` in `conformance/retrieval.py` — asserts pre-filter not post-filter, empty result is not an error, `doc_ids` narrows only, and that a cross-tenant row is `not_found`.
- [ ] **T006** [P] `ToolRegistryContract` — allowlist enforced; **exactly one** audit entry per call including failures; in-process and MCP paths produce identical results and identical audit; `max_result_bytes` clips with `truncated: true` **and an in-band marker**, never a silently short list; a registered secret echoed by a tool comes back `[REDACTED]` in the result, the debug fragment, the event, and the audit entry.
- [ ] **T006a** [P] `LLMGatewayClientContract` — aliases resolve with no provider key; `deadline` refuses rather than overruns; a context-length refusal is a typed, **non-retried** outcome; `finish_reason == "length"` escalates `max_output_tokens` exactly once (8192 → 4×); `count_tokens` never under-reports.
- [ ] **T006b** [P] `MemoryServiceContract` — write-time ownership stamping; read-time re-filtering against **current** clearance; **no autonomous write** (turn text alone produces no memory — a self-extracting backend fails this and must be bound with extraction disabled).
- [ ] **T007** [P] `PolicyContract` — purity (same input, same decision; no I/O, no clock, no randomness); fail-closed on an unknown action.
- [ ] **T008** [P] `MeterContract` — `idem_key` honored; **zero** spend on refused, paused, and rejected runs.
- [ ] **T009** [P] `ApprovalContract` — zero spend while pending; first decision wins; reject mutates nothing; decision is never derived from model output.
- [ ] **T010** **`AccessFloorContract`** — the load-bearing one. A cross-tenant or above-clearance row is `not_found` under **both** the two-store and single-store lowerings, from one unmodified suite body. If this needs profile-specific branches, the boundary is wrong.
- [ ] **T011** [P] Fakes for every port in `conformance/fakes.py`, incl. `FakeGateway` with **scripted** responses covering: a well-formed answer, a tool call, malformed output, a raised exception, a `429` with `Retry-After`, and a stream that emits then disconnects. No test in the suite may reach a provider.
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
- [ ] **T021b** Implement the **entrypoint context compactor** — keep-first/keep-last/summarize-middle against `history_token_budget`, measured via `count_tokens`, run **once** before `guard` so `route`/`rewrite`/`generate` all observe the identical `history`. Emits `degraded{reason:'history_compacted'}`, the `compaction` debug fragment, and `agent_context_compaction_total`.
- [ ] **T021c** Test: compaction — first/last turns survive verbatim; the digest is **cumulative** (compact twice, assert the earliest turn's facts survive rather than degrading through a summary-of-summaries); the digest lands **after** the frozen prefix so T021 still passes; `history_digest` is never written to `MemoryService`.
- [ ] **T022** Test: streaming decoupling — `astream_events` yields tokens with **no** stream backend bound.
- [ ] **T023** Implement `graph/state.py` (`AgentState`, `SecurityCtx`) and `graph/build.py`.
- [ ] **T024** Implement nodes: `guard`, `route`, `rewrite`, `retrieve`, `rerank`, `assemble`, `memory`, `generate`, `suggest`.
- [ ] **T025** Implement the `clarify` terminal node and the ambiguity branch (`route` is the graph's single conditional entry into it).
- [ ] **T026** Implement `telemetry/` — the instrumentation wrapper applied to **every** node at assembly.
- [ ] **T027** Implement run budgets: wall-clock deadline and step cap, evaluated at node boundaries, with **paused time excluded**.

## Stage 5: Reliability and failure behavior

- [ ] **T028** Test: fail-closed guard — a moderation timeout blocks the query, spends zero, and never reaches `retrieve`.
- [ ] **T029** Test: failure-injection matrix — every declared reliability policy is exercised by an **injected fault**, not merely written down: gateway `429`/timeout at each call site, **a gateway context-length (`413`-class) refusal at each call site** (→ `failed('context_window_exceeded')`, never an unclassified `error`, never retried), **a `finish_reason == "length"` truncation** (→ one `max_output_tokens` escalation, then surfaced), retrieval unavailable, rerank unavailable, memory unavailable, a tool raising, a tool returning malformed data, **a tool exceeding `max_result_bytes`** (→ clipped and marked, never silently dropped), empty retrieval (**not** a failure), a vision call failing past cutoff, and the checkpointer unavailable mid-run. Each asserts the specified outcome **and** that the degradation was recorded.
- [ ] **T030** Test: budget boundaries — a deadline breach **before `assemble`** ends `failed('deadline_exceeded')` at a node boundary with spend settled; one **at or after `assemble`** finishes `outcome='degraded'` with `degraded{reason:'deadline_partial'}` and either an answer or citations with `answer_generated: false` — **never `ok`, never nothing, never a citations-only result dressed as an answer** — with `agent_budget_exhausted_total{boundary="deadline"}` incremented in both cases; a durable run past `max_steps` ends `step_cap_exceeded`; a gate held past the deadline still resumes cleanly.
- [ ] **T030a** Implement the deadline-degrade path: `generate` under the remaining budget past `assemble`, falling back to citations + the structural not-generated marker when the budget is already gone.
- [ ] **T031** Test: telemetry — exactly one start and one terminal record per executed node with the full correlation set; **leak assertion** (a sentinel planted in query, chunk, and memory appears in no log or metric label); **label assertion** (no metric label carries a tenant, principal, or id); **degradation assertion** (green with no exporter bound).
- [ ] **T032** Implement the per-node reliability policy and degradation recording.
- [ ] **T031a** `scripts/check-node-io.py`: **generate** the node read/write table from the `graph/nodes/` signatures and diff it against the table in [agent-graph.md](./contracts/agent-graph.md); fail on drift. That table already fell three keys behind (`doc_ids`, `attachment_text`, `image_refs`) and lost a reader entirely (`web_results`) while every prose section was correct — a hand-maintained authority is one that will drift again. Wire into `make lint`.

## Stage 6: Tools and human-in-the-loop

- [ ] **T033** Test: in-process and MCP tool parity — identical result and identical audit entry for the same call.
- [ ] **T034** Test: human gate — a run reaching a gate interrupts, spends **zero** while paused, resumes **exactly once** on approval (no settled node re-runs, no re-spend), and short-circuits on reject without mutating the subject.
- [ ] **T035** Test: action tools — the web-search tool performs **no fetch** until its gate is approved; the note-edit tool commits only after approval **and** a permit check, is denied above clearance or outside tenant, is denied if it would raise an access level above the source floor, and refuses creation outright.
- [ ] **T036** Implement `tools/` — the `ToolRegistry` port with `inprocess` and `mcp_client` bindings, sharing one policy wrapper. The wrapper enforces `max_result_bytes` (256 KB Categories A/B, 64 KB per `web_search` result) and runs the **credential scrubber** — static patterns plus a dynamic registry of the deployment's bound secrets — before any result reaches a prompt, a debug fragment, an event, or an audit entry. Always on, no config flag.
- [ ] **T037** Implement the read-only tool tier.
- [ ] **T038** Implement the `human_gate` node and the resume path.
- [ ] **T039** Implement the two HITL-gated action tools.

## Stage 7: Backends

- [ ] **T040** [P] Implement `retrieval/pgvector.py` — dense HNSW + a lexical companion + RRF. **Retrieval-quality parity is the work here**, not the authz floor. Must pass `RetrievalServiceContract` and `AccessFloorContract`.
- [ ] **T041** [P] Implement `retrieval/qdrant.py` — hybrid + payload pre-filter. Same two suites.
- [ ] **T042** [P] Implement `bus/` — `inprocess`, `redis_streams`, `jetstream` adapters, one suite.
- [ ] **T043** [P] Implement `gateway/` — the OpenAI-wire client with alias resolution, deadline propagation, one-hop fallback, `count_tokens`, `max_output_tokens` defaulting to 8192 with a single 4× escalation on `finish_reason == "length"`, and a **typed, non-retried** context-length refusal. Must pass `LLMGatewayClientContract`.
- [ ] **T044** [P] Implement `memory/` — Mem0 backend plus a no-op, with write-time stamping, **read-time re-filtering against current clearance**, and **auto-extraction disabled** (a backend that persists facts from turn text on its own is making the autonomous write research §13 excludes). Recalled memories are handed to `generate` already delimited as untrusted content. Must pass `MemoryServiceContract`.
- [ ] **T045** Implement checkpointing and resume, incl. explicit `checkpoint_lost` on a pointer whose checkpoint is gone.
- [ ] **T046** Implement `retrieval` doc-id scoping — conjoins a document term onto the predicate; narrows only.
- [ ] **T047** Implement the query-time vision path, treating image bytes as untrusted input.

## Stage 8: Second-domain and profile proofs

> These are the tasks that make the repo's central claims *checked* rather than asserted. If the schedule slips, these are the last things to cut, not the first.

- [ ] **T048** **Second-domain reuse test**: a test-only plugin (different tools, a `per_customer` policy) plus its manifest runs the **unmodified** graph green end-to-end.
- [ ] **T049** **Profile-B swap test**: the graph runs green with the **production** pgvector backend and an in-process bus — no vector-DB and no broker client bound.
- [ ] **T050** **Access floor is profile-invariant**: `AccessFloorContract` passes **unchanged** under the single-store wiring.
- [ ] **T051** **Config-only remote-tool-source test**: the unmodified graph consumes a remote MCP server as its tool source, with enforcement staying at that server's boundary.
- [ ] **T052** Channel-adapter swap: attaching a second transport adapter changes no node and no graph output on a golden query.
- [ ] **T053** Additivity: adding a no-op Phase-2 grading stub changes no existing node's output on a golden query.

## Stage 9: Standalone profile

- [ ] **T054** Write `deploy/compose.profile-b.yml` — postgres+pgvector, redis, an OpenAI-wire gateway. No vector DB, no broker.
- [ ] **T055** Implement the Profile-B entrypoint: sets the store's tenant context per request and runs the guard, tool-policy, and metering wrappers **inside the single container** — the obligations a full host's kernel would otherwise satisfy.
- [ ] **T056** `make smoke` — a cited answer end-to-end on the standalone topology.
- [ ] **T057** Wire `scripts/assert-profile-b-isolation.sh` into CI as a required gate.

### Profile C — the minimal shape

- [ ] **T057a** Implement `retrieval/sqlite.py` — dense + FTS5 + RRF. Must pass `RetrievalServiceContract` **and** `AccessFloorContract`.
- [ ] **T057b** Emit a **startup warning** whenever `retrieval.kind: sqlite` is bound, naming the reduced floor explicitly (predicate enforced by the query, not the engine; single-tenant only). A deployment must never arrive at Profile C by accident.
- [ ] **T057c** `NoOpMeter` plus a SQLite checkpointer binding; `make up-c && make smoke-c` runs the whole agent as **one container with one file** — no Postgres, no Redis, no bus.
- [ ] **T057d** Test: the `sqlite` backend refuses to start when the manifest declares more than one tenant, or when `AccessFloorContract` is run in multi-principal mode. **Fail closed rather than silently offering a weaker floor** to a deployment that needs the strong one.

## Stage 10: Evaluation

- [ ] **T058** Eval seed set: ≥20 prompt cases and ≥30 golden queries, including the **hard access-filter assertion** (a query that would match an above-clearance document returns nothing from it).
- [ ] **T059** Clarification-rate eval — asserts ≤10% on unambiguous golden queries.
- [ ] **T060** Retrieval-quality eval — recall and MRR thresholds, run against **both** retrieval backends so a backend swap cannot quietly regress quality.
- [ ] **T061** Implement the **incident→regression loop**: a `evals/regressions/` directory where every observed agent-behavior defect is added as a permanent case, reproduced from its recorded trace, **before** its fix counts as complete.

## Stage 9a: Standalone product defaults

> These are what make the repo a **product** rather than a library. Each is a *default implementation of a declared port* — never privileged code — and each is held to the same conformance suite an override must pass (AR-034).

- [ ] **T057e** Define the `Ingestor` port + `IngestorContract` per [contracts/agent-deps.md](./contracts/agent-deps.md): ownership stamped from `ctx`, unowned content **rejected**, idempotent by content hash, source treated as untrusted.
- [ ] **T057f** Default `Ingestor`: files, URLs, raw text → chunk → embed → store. Deliberately minimal; the reference host keeps its full pipeline and binds that instead.
- [ ] **T057g** Default `IdentityBinder`: single-user and explicit-user-list modes, **failing closed** on an unrecognized principal. Never a default that authenticates nobody and authorizes everybody.
- [ ] **T057h** `intel-agent ingest <path|url>` CLI plus an ingest view in the built-in UI, so a corpus can be built without writing code.
- [ ] **T057j** Default `Meter`: a **real local usage ledger** — tokens, cost, per principal, idempotent by `idem_key`, queryable from the CLI. Not a counter that discards.
- [ ] **T057k** Default moderation behind `guard`: a **real check** via the gateway's moderation endpoint, fail-closed on timeout or error. No stub that returns `allow`.
- [ ] **T057l** **No-hollow-defaults test** (AR-035): assert that no shipped default is a no-op — the `Meter` default records a spend that is then readable, the moderation default actually rejects a seeded disallowed input, and the audit default produces a readable entry. A default that silently passes must fail this test.
- [ ] **T057i** **Default-swap test**: replace each default (ingestor, identity, meter, UI) with a second implementation of the same port; the conformance suite passes and **no graph node changes**. This is the test that keeps a default from quietly becoming privileged.

## Stage 10a: Test doubles and dev harness (unblocks BOTH repos)

> Do this **early — right after Stage 4**, not late. Until `FakeAgentRuntime` exists, a host cannot build its transport, debug panel, chat UI, or billing path against anything real; and until a dev harness exists, nobody here can *watch* a run stream. These six tasks are what make the two repos independently developable, so their value is highest before either side has improvised a substitute it will have to unwind.

- [ ] **T062a** Define the event vocabulary in `src/intel_agent/events.py` per [contracts/stream-events.md](./contracts/stream-events.md), with a `SCHEMA_VERSION`.
- [ ] **T062b** `intel_agent.testing.FakeAgentRuntime` — scripted, deterministic, same call surface as `build_graph(...)`. Scenarios: `CITED_ANSWER`, `REFUSAL`, `CLARIFICATION`, `GATE_PAUSE_RESUME`, `DEGRADED_RERANK`, `DEADLINE_DEFERRAL`, `DEADLINE_PARTIAL`, `HISTORY_COMPACTED`, `TRUNCATED_TOOL_RESULT`, `CONTEXT_WINDOW_EXCEEDED`, `ERROR`. **Exported**, so a host never hand-rolls a second definition of the vocabulary.
- [ ] **T062c** `intel_agent.testing.golden/` — JSONL fixture per scenario. Assert the **real** graph (against `FakeGateway`) reproduces each, modulo nondeterministic ids. This is the check that keeps the double honest.
- [ ] **T062d** `StreamEventContract` — the eight ordering guarantees, out-of-order/interleaved arrival, forward compatibility with an unknown future event **and an unknown `degraded.reason` / `run_finished.outcome` value**, **pause is not completion**, **`answer_generated: false` is not an answered question**, and no body in any payload.
- [ ] **T062e** `make dev` — a streaming CLI REPL. The default development loop: fast, scriptable, diffable, CI-friendly.
- [ ] **T062f** `make dev-ui` — the built-in chat UI: one self-contained page over SSE. **This is a product surface now** (AR-033), so WCAG 2.1 AA applies — keyboard navigation, focus management, screen-reader labels. Still deliberately minimal and still a *reference consumer*: Renders **only** from the published vocabulary and calls no bespoke endpoint; run against every golden fixture in CI. If it ever needs a special case, the vocabulary is missing something — fix the vocabulary, not the page.

## Stage 11: Chat channels (Phase 2 — port fixed now, adapters later)

> The `Channel` port, its capability model, and the `IdentityBinder` split are settled in [contracts/channels.md](./contracts/channels.md), so these are **additive**: no node changes, no boundary change.
>
> **Do WeChat second, not last.** It is the platform that cannot stream and must answer in ~5s. Building Discord and Slack first and bolting WeChat on at the end produces a `ChannelRunner` shaped entirely around streaming — which is the failure this capability model exists to prevent. Discord proves the happy path; WeChat proves the model.

- [ ] **T065** [P] `ChannelContract` in `conformance/channels.py` — capabilities honest, unknown identity refuses, deadline defers rather than truncates, chunking lossless, scope isolation, channel-blind graph output, no SDK leak.
- [ ] **T066** Implement `ChannelRunner` — the generic glue: `listen` → `bind` → refuse-if-`None` → build `ctx` + namespaced `thread_id` → `astream_events` → platform writer. **All capability adaptation lives here**, so adapters stay thin protocol shims.
- [ ] **T067** [P] Discord adapter (`intel-agent[discord]`) — gateway WS, 2000-char chunking, streaming by message edit with rate-limit-aware interval, DM vs guild scope.
- [ ] **T068** [P] WeChat Official Account adapter (`intel-agent[wechat]`) — HTTP callback, AES-decrypt + signature verify, **no streaming**, ~5s deadline with the deferral path, and the customer-service late reply inside its 48h window. Document **which account type** is targeted; capabilities differ by type and verification status.
- [ ] **T069** [P] Slack adapter (`intel-agent[slack]`) — Socket Mode, `chat.update` streaming, `thread_ts` continuity, `(team_id, user_id)` identity key.
- [ ] **T070** Reference `IdentityBinder` implementations for the docs: a **single-user** binder (~5 lines, the personal-agent case) and a **directory-backed** multi-tenant one. Both are examples, never defaults — the runtime ships no binder.

## Stage 12: Release

- [ ] **T062** Package `conformance/` as public API; verify it survives a wheel build and is importable from a clean venv.
- [ ] **T063** Tag `v0.1.0`; verify a host can resolve it by git ref and subclass the suites.
- [ ] **T064** Document the upgrade contract in [host-integration.md](./contracts/host-integration.md) §Versioning: a port change lands **before** the host PR that consumes it.

---

## Dependencies

```
Stage 1 ─► Stage 2 (ports+conformance) ─► Stage 3 (manifest) ─► Stage 4 (graph)
                                                                    │
                        ┌───────────────────────────────────────────┤
                        ▼                     ▼                     ▼
                   Stage 5 (reliability)  Stage 6 (tools/HITL)  Stage 7 (backends)
                        └─────────────────────┴─────────────────────┘
                                              ▼
                                   Stage 8 (proofs) ─► Stage 9 (standalone)
                                              ▼
                                   Stage 10 (evals) ─► Stage 12 (release)

Stage 11 (channels, Phase 2) hangs off Stage 4 + Stage 9: it needs a runnable
graph and the standalone entrypoint, but nothing from evals or release.
```

Stage 2 blocks everything: the suites are the specification. Stages 5–7 parallelize once the graph exists. Stage 8 needs both a real backend (T040) and the graph.

**Minimum viable slice**: Stages 1–4 plus T040 and T054–T056 — a standalone runtime that answers a cited question. Everything after hardens or proves it.

---

## Traceability to aisat-intel

Each row maps a local task to the upstream ID it replaces. Those IDs are **retired in place** in aisat-intel — never renumbered, because `dispatch-prompts.md` (91 references), `track-manifest.md` (55), and the `runs/*.json` orchestration records all address tasks by number.

| Local | Retires (aisat-intel) | Note |
|---|---|---|
| T004 | — | new: ports were implicit across three contracts, now one surface |
| T004a | — | **new** — port-tier check; tiers introduced so Phase-2 ports are not frozen before an adapter argues with them |
| T005–T012 | T149 (approval conformance) | broadened from one port to every port on the read/run path (Channel + IdentityBinder are Phase 2, T065) |
| T006a, T006b | — | **new** — gateway and memory had ports but no suites; the memory suite carries the no-autonomous-write rule |
| T013–T016 | T060c | manifest determinism + second-domain seam |
| T017 | T113 (partial) | only `agent_policies` + `agent_run`; upstream keeps the kernel tables |
| T018–T027 | T073, T073a–T073d, T060b | graph, ToolRegistry port, clarify, telemetry, budgets |
| T021a | — | **new** — untrusted framing was specified for retrieved content only; memory and the history digest were uncovered |
| T021b, T021c | — | **new** — `history` was the one unbounded input; upstream bounded it in a chat-session layer that stayed there |
| T028–T032 | T060i | failure matrix, budgets, telemetry assertions |
| T030a | — | **new** — deadline degrade past `assemble`, so a breach one node short of an answer does not discard four settled gateway calls |
| T031a | — | **new** — generate the node I/O table; the hand-maintained one had already drifted four keys |
| T033–T039 | T028(mcp bootstrap), T070–T072a, T120a, T120b | tools + HITL + action tools |
| T040 | T034a, T065a, T065b | pgvector backend + doc-id scoping |
| T041 | T065a (qdrant half) | |
| T042 | T029a | Bus port |
| T043 | — | gateway client (upstream's lived in the shared Python tier) |
| T044 | T068 | Mem0 + clearance re-filter |
| T045 | T111, T120 | checkpoint/resume + long-horizon worker |
| T046 | T065b | |
| T047 | T066a | query-time vision |
| T048 | T060c | second-domain reuse |
| T049 | T060d | Profile-B swap |
| T050 | T060d (floor half) | profile-invariant access |
| T051 | T060g | config-only MCP client |
| T053 | — | additivity regression |
| T054–T057 | T060e, T060f | Profile-B entrypoint + smoke |
| T058–T061 | T125, T125a | eval seed + incident→regression loop |
| T062–T064 | — | new: cross-repo release contract |

> **Reading the numbers.** Local IDs (`T001`+) and aisat-intel IDs share a numeric space and **do overlap** — local `T069` is the Slack adapter, upstream `T069` is the semantic cache. Upstream IDs are always written `aisat-intel Txxx` outside this table; inside it, the left column is local and the middle column is upstream.

**Upstream tasks that stay upstream** (host surface, no counterpart here): `aisat-intel T069` (semantic cache — a host-side hot path), `aisat-intel T074` (prompt assets ship here but are authored against the host's response format), `aisat-intel T075` (query router + Redis stream adapter — transport), `aisat-intel T077a/T077b` (suggestion SSE event + UI), `aisat-intel T101/T101b` (debug-panel assembly and streaming — the runtime emits fragments, the host renders), `aisat-intel T062a–T062d` and `T076a/T076b` (chat sessions — host), `aisat-intel T030` (BAML/observability bootstrap — split).

> **T069, T074, T075, T101 are the four worth a second look at integration time.** Each is genuinely split: the runtime owns the emission and the host owns the surface, so both repos carry half a task. They are the most likely place for a gap to hide.
