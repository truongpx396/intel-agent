<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/plan.md).
     Narrowed to the single Python runtime; the Go/React/deploy tiers of the
     source plan have no counterpart here. -->

# Implementation Plan: Self-Contained Agent Runtime

**Branch**: `001-agent-runtime` | **Extracted**: 2026-08-09 | **Spec**: [spec.md](./spec.md)

## Summary

One LangGraph `StateGraph`, compiled in two forms (interactive and durable), composed from an `AgentManifest` (config) plus a `DomainPlugin` (code), over the declared port surface. The runtime answers cited questions under a visibility floor it lowers but does not own, and runs identically as an embedded library in a full host (Profile A) or as a single self-contained container (Profile B).

The engineering thesis: **every reuse point is a named port with a conformance test**, so exercising a second profile can never regress the reference one, and "runs somewhere else" stays a checked capability rather than a claim.

## Technical Context

**Language**: Python 3.13 (single runtime — deliberately; adding a second requires a constitutional amendment)

**Primary dependencies**: LangGraph (graph + checkpointing), Pydantic (schemas), `openai` (OpenAI-wire client pointed at any gateway), structlog, tenacity. Everything a host can supply sits behind an extra — a standalone install must not be able to import a vector-DB or message-bus client.

**Storage**: driven entirely by the manifest's `retrieval.kind` —
- `pgvector`: Postgres with RLS as **both** the store and the access floor (single-store profile)
- `qdrant`: a vector store with payload pre-filters, paired with RLS (two-store profile)
- `sqlite`: an embedded file store, dense + FTS5 + RRF, with the predicate enforced **by the query rather than the engine** (Profile C). A weaker floor and single-tenant only, so binding it emits a startup warning naming the reduction and fails closed on a multi-tenant manifest (AR-024a).

Checkpointing is any LangGraph `BaseCheckpointSaver` (Redis, Postgres, SQLite).

**Testing**: `pytest` with three tiers — unit (fake `AgentDeps`, no infra), integration (testcontainers: Postgres+pgvector, Redis), and **conformance** (the suites this repo exports to hosts). Plus a Profile-B smoke asserted in both directions: that a cited answer is produced, *and* that no forbidden backend was bound.

**Performance**: the runtime owns per-node latency and run budgets. End-to-end API latency belongs to the host and is not specified here — that is the documented exception constitution IX requires, and it covers the *embedded* case only. The **built-in web UI is this repo's own product surface** (AR-033), so constitution IX's default applies to it unchanged: interactive in **< 2.5s**, asserted in CI against the golden fixtures (T071f) rather than assumed. A budget nobody measures is a budget nobody has.

**Constraints**: 100% access-control correctness (SC-A01, release blocker); injection refused before retrieval or spend (SC-A04); zero spend on refused, paused, or rejected runs; no provider key held anywhere in this repo.

## Constitution Check

*GATE: must pass before Phase 0, re-checked after design.*

Constitution v1.0.1 — see [.specify/memory/constitution.md](../../.specify/memory/constitution.md).

| Principle | Assessment | Status |
|---|---|---|
| **I. Code Quality** | ruff/black/mypy in CI; ports are `Protocol`s and `disallow_untyped_defs` is on — an untyped port is a broken published contract | PASS |
| **II. Clean Architecture** | `ports/` holds protocols and imports no concrete backend; backends wired only at the composition root; nodes are pure functions of `(state, config)` | PASS |
| **III. API-First / Contract-First** | The contracts in [contracts/](./contracts/) precede implementation; `agent-deps.md` and `host-integration.md` define the boundary before any node exists | PASS |
| **IV. Modular Design & Feature Flags** | A domain is a manifest + plugin; Phase-2 nodes have fixed insertion points and declared state keys. **The manifest is the centralized flag source** the principle requires: `can_write`, `write_ops`, `channels`, `mcp_servers`, and `hooks_enabled` are runtime toggles read per run from one row, so a capability is enabled, rolled back, or kill-switched without a deploy | PASS |
| **V. Testing Standards** | Unit / integration / contract / conformance tiers; the **80% floor and the no-decrease rule are enforced in CI by T002a**, not merely targeted; the access-filter assertion is in the eval seed set | PASS |
| **VI. TDD** | Contracts precede nodes; **every implementation task in [tasks.md](./tasks.md) is immediately preceded by the test that constrains it**, verifiable in history | PASS |
| **VII. Host Boundary Discipline** | The ports enumerated in [agent-deps.md](./contracts/agent-deps.md) are the entire boundary; a static import scan enforces that no node reaches around one; **every one of those ports ships a conformance suite** (AR-025, T005–T009f) and declares a stability tier (AR-025a, T004a) | PASS |
| **VIII. Interface Consistency** | Canonical `{code,message,details}` errors with one code registry — **specified as AR-036, constrained by `ErrorEnvelopeContract` (T009f), implemented by T032a**; ISO-8601 UTC; integer credits; the event taxonomy is versioned (T071a) | PASS |
| **IX. Performance** | Per-node timeouts, run-level deadline, step cap, and per-run cost ceiling; prompt-prefix stability for cache economics; **the built-in UI carries the < 2.5s interactive budget and is measured in CI** (T071f), while host-side end-to-end latency is the documented exception | PASS |
| **X. Verification Before Completion** | Conformance suite and Profile-B smoke are Definition-of-Done items, not optional extras | PASS |

**Initial Constitution Check: PASS.** Complexity Tracking intentionally empty — the port surface is the boundary the source system already had; consolidating it into one contract reduced ambiguity rather than adding structure.

> **These rows were re-checked and four of them were wrong.** IV, V, VIII, and IX previously read PASS on evidence that addressed something adjacent to the principle rather than the principle's actual MUST — IV cited modularity and never mentioned flags; V named the 80% floor with no gate enforcing it; VIII claimed an error envelope that no requirement stated and no test checked; IX claimed an exception that covered the host's latency but not this repo's own UI. Each is now backed by a named requirement or task, or it is not marked PASS. A Constitution Check that restates the principle's topic instead of citing the artifact that satisfies it will pass every time, which makes it worth nothing.

> **One count, one place.** Earlier revisions of this plan and of [agent-deps.md](./contracts/agent-deps.md) carried a hard-coded port count that disagreed with the table (thirteen vs. fourteen) after `Ingestor` was added. Prose no longer states a number: [agent-deps.md](./contracts/agent-deps.md) is the enumeration, everything else points at it. Restating a fact is how it goes stale.
>
> **And it went stale again, twice, in this very file.** This plan then said "seven contracts" in two places while `contracts/` held eight and this file's own tree listed all eight — the note above was written about ports and the same author immediately hard-coded a count of contracts a dozen lines later. Both are now unnumbered. The lesson is not "be careful": it is that any count in prose is a defect waiting for someone to add the ninth thing.

## Project Structure

### Documentation

```text
specs/001-agent-runtime/
├── spec.md                  # renumbered AR-xxx requirements + traceability table
├── plan.md                  # this file
├── research.md              # the agent-relevant decisions, carried over
├── data-model.md            # AgentManifest backing row, AgentRun, port-facing views
├── quickstart.md            # stand up the standalone profile
├── tasks.md                 # T001… with a mapping back to retired aisat-intel IDs
├── contracts/
│   ├── README.md
│   ├── agent-deps.md        # ← the boundary: the port surface (authoritative)
│   ├── host-integration.md  # ← the boundary: five host obligations
│   ├── stream-events.md     # event vocabulary + test doubles (unblocks both repos)
│   ├── channels.md          # Discord / Slack / WeChat (port now, adapters Phase 2)
│   ├── agent-graph.md       # moved, history preserved
│   ├── agent-runtime.md     # moved, history preserved
│   ├── mcp-tools.md         # moved, history preserved
│   └── approval-ports.md    # moved, history preserved
└── diagrams/
```

### Source

```text
src/intel_agent/
├── ports/            # Protocols ONLY. Imports no concrete backend, ever.
├── graph/
│   ├── build.py      # StateGraph assembly; the only place manifests are read
│   ├── state.py      # AgentState, SecurityCtx
│   └── nodes/        # guard route rewrite retrieve rerank assemble memory
│                     #   generate suggest clarify human_gate
├── retrieval/        # RetrievalService: pgvector + qdrant backends
├── memory/           # MemoryService (+ no-op)
├── tools/            # ToolRegistry: inprocess + mcp_client bindings
├── gateway/          # LLMGatewayClient (OpenAI-wire) + FakeGateway for tests
├── bus/              # Bus: inprocess | redis_streams | jetstream
├── manifest/         # AgentManifest load + validation (fails CLOSED)
├── telemetry/        # node instrumentation wrapper
├── channels/         # Phase 2: runner.py + discord.py | slack.py | wechat.py
│                     #   sits ABOVE the graph, never in AgentDeps — that is what
│                     #   keeps the graph channel-blind (contracts/channels.md)
├── ingest/           # Ingestor port default: files | urls | text (AR-029)
├── identity/         # IdentityBinder default for the CLI/UI surface ONLY (AR-032);
│                     #   deliberately not reachable from channels/ (AR-026)
├── ui/               # the built-in chat + ingest UI (AR-033) — a reference
│                     #   consumer of events.py, never a second product surface
├── events.py         # the emitted event vocabulary + SCHEMA_VERSION
├── errors.py         # the {code,message,details} envelope + code registry (AR-036)
├── testing/          # PUBLIC API — FakeAgentRuntime + golden/ fixtures for HOSTS
└── conformance/      # PUBLIC API — imported by host repos

prompts/  evals/  migrations/  tests/{unit,integration,conformance,smoke}/
deploy/compose.profile-b.yml
```

**Structure decision.** Ports are physically separated from implementations so the import ban is mechanically checkable, not a convention. `conformance/` sits inside the shipped package rather than in `tests/` **because it is public API** — a host imports it, so it must survive packaging. That is the single most consequential layout choice here: putting it under `tests/` would make the cross-repo drift check unshippable.

## Three profiles, one binary

| | Profile A — reference host | Profile B — self-contained | Profile C — minimal single-tenant |
|---|---|---|---|
| Composition | embedded in a full product | one container | one container, one file |
| Retrieval | vector store + RLS | Postgres + pgvector, RLS alone | SQLite, dense + FTS5 + RRF |
| Access floor | RLS **+** vector payload pre-filter | RLS alone | **the query, not the engine** — weaker; single-tenant only, warned at startup, fails closed on a multi-tenant manifest |
| Bus | JetStream | in-process | in-process |
| Checkpointer | Redis / Postgres | Redis | SQLite (same file) |
| Metering | host's ledger | default local ledger | default local ledger, **same file** — never unmetered (AR-035) |
| Auth / billing | host kernel | host concerns re-satisfied in-container | single-user or explicit user list |

A is B **plus** the host kernel and heavier backing services — a superset relation. C is B **minus** every external service, at the cost of a weaker floor it is required to announce. None is a fork; all three run the same binary and the same manifest schema, and `AccessFloorContract` passes unchanged across all three.

> **Profile C was missing from this file entirely** while AR-024a mandated it, `agent-deps.md` specced the `sqlite` backend, and tasks.md built it. A plan that documents two of three deployment shapes is one an implementer will follow into building two.

## Phasing

Plan phases and [tasks.md](./tasks.md) stages are the same schedule at two resolutions; the mapping is here so neither drifts silently.

| Phase | Tasks stage(s) | Content |
|---|---|---|
| **0 — research** | — | Carried over; see [research.md](./research.md) |
| **1 — contracts** | — | Complete. The contracts in [contracts/](./contracts/), two authored fresh to make the boundary explicit |
| **2 — ports and fakes** | Stages 1–3 | Every `Protocol` plus a fake and its conformance suite. TDD order: the suite exists before the real backend |
| **3 — graph** | Stage 4 | Nodes against fake deps, no infra |
| **3a — test doubles** | Stage 5 | `FakeAgentRuntime`, golden fixtures, the event vocabulary, and the dev harnesses — **early**, because until they exist the host repo cannot build against anything real |
| **4 — hardening and backends** | Stages 6–8 | Reliability matrix, tools + HITL, pgvector / qdrant / sqlite retrieval, Redis checkpointer, in-process and JetStream `Bus` |
| **5 — standalone profile** | Stages 9–11 | Proofs, compose topology, entrypoint, smoke, the isolation assertion, and the product defaults that make a first answer reachable from nothing |
| **6 — evaluation** | Stage 12 | Seed set, retrieval and answer-grounding gates, the incident→regression loop |
| **7 — host integration** | Stage 14 | Publish `v0.1.0`; the host pins it and runs the conformance suites |
| **Phase 2 (product)** | Stage 13 | Chat-platform adapters. The `Channel` port and runner land in Phase 1 so the port cannot drift; the three adapters do not |

## Complexity Tracking

> No constitutional violations. Table intentionally empty.

| Violation | Why needed | Simpler alternative rejected because |
|---|---|---|
