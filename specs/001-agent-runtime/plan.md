<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/plan.md).
     Narrowed to the single Python runtime; the Go/React/deploy tiers of the
     source plan have no counterpart here. -->

# Implementation Plan: Self-Contained Agent Runtime

**Branch**: `001-agent-runtime` | **Extracted**: 2026-08-09 | **Spec**: [spec.md](./spec.md)

## Summary

One LangGraph `StateGraph`, compiled in two forms (interactive and durable), composed from an `AgentManifest` (config) plus a `DomainPlugin` (code), over thirteen declared ports. The runtime answers cited questions under a visibility floor it lowers but does not own, and runs identically as an embedded library in a full host (Profile A) or as a single self-contained container (Profile B).

The engineering thesis: **every reuse point is a named port with a conformance test**, so exercising a second profile can never regress the reference one, and "runs somewhere else" stays a checked capability rather than a claim.

## Technical Context

**Language**: Python 3.12 (single runtime — deliberately; adding a second requires a constitutional amendment)

**Primary dependencies**: LangGraph (graph + checkpointing), Pydantic (schemas), `openai` (OpenAI-wire client pointed at any gateway), structlog, tenacity. Everything a host can supply sits behind an extra — a standalone install must not be able to import a vector-DB or message-bus client.

**Storage**: driven entirely by the manifest's `retrieval.kind` —
- `pgvector`: Postgres with RLS as **both** the store and the access floor (single-store profile)
- `qdrant`: a vector store with payload pre-filters, paired with RLS (two-store profile)

Checkpointing is any LangGraph `BaseCheckpointSaver` (Redis, Postgres, SQLite).

**Testing**: `pytest` with three tiers — unit (fake `AgentDeps`, no infra), integration (testcontainers: Postgres+pgvector, Redis), and **conformance** (the suites this repo exports to hosts). Plus a Profile-B smoke asserted in both directions: that a cited answer is produced, *and* that no forbidden backend was bound.

**Performance**: the runtime owns per-node latency and run budgets. End-to-end API latency belongs to the host and is not specified here.

**Constraints**: 100% access-control correctness (SC-A01, release blocker); injection refused before retrieval or spend (SC-A04); zero spend on refused, paused, or rejected runs; no provider key held anywhere in this repo.

## Constitution Check

*GATE: must pass before Phase 0, re-checked after design.*

Constitution v1.0.0 — see [.specify/memory/constitution.md](../../.specify/memory/constitution.md).

| Principle | Assessment | Status |
|---|---|---|
| **I. Code Quality** | ruff/black/mypy in CI; ports are `Protocol`s and `disallow_untyped_defs` is on — an untyped port is a broken published contract | PASS |
| **II. Clean Architecture** | `ports/` holds protocols and imports no concrete backend; backends wired only at the composition root; nodes are pure functions of `(state, config)` | PASS |
| **III. API-First / Contract-First** | Seven contracts precede implementation; `agent-deps.md` and `host-integration.md` define the boundary before any node exists | PASS |
| **IV. Modular Design** | A domain is a manifest + plugin. Phase-2 nodes have fixed insertion points and declared state keys | PASS |
| **V. Testing Standards** | Unit / integration / contract / conformance tiers; 80% floor; the access-filter assertion is in the eval seed set | PASS |
| **VI. TDD** | Contracts precede nodes; tests precede implementation, verifiable in history | PASS |
| **VII. Host Boundary Discipline** | The thirteen ports are the entire boundary; a static import scan enforces that no node reaches around one | PASS |
| **VIII. Interface Consistency** | Canonical `{code,message,details}` errors; ISO-8601 UTC; integer credits; the event taxonomy is versioned | PASS |
| **IX. Performance** | Per-node timeouts, run-level deadline and step cap, prompt-prefix stability for cache economics | PASS |
| **X. Verification Before Completion** | Conformance suite and Profile-B smoke are Definition-of-Done items, not optional extras | PASS |

**Initial Constitution Check: PASS.** Complexity Tracking intentionally empty — the port count (thirteen) is the boundary the source system already had; consolidating it into one contract reduced ambiguity rather than adding structure.

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
│   ├── agent-deps.md        # ← the boundary: thirteen ports
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
├── events.py         # the emitted event vocabulary + SCHEMA_VERSION
├── testing/          # PUBLIC API — FakeAgentRuntime + golden/ fixtures for HOSTS
└── conformance/      # PUBLIC API — imported by host repos

prompts/  evals/  migrations/  tests/{unit,integration,conformance,smoke}/
deploy/compose.profile-b.yml
```

**Structure decision.** Ports are physically separated from implementations so the import ban is mechanically checkable, not a convention. `conformance/` sits inside the shipped package rather than in `tests/` **because it is public API** — a host imports it, so it must survive packaging. That is the single most consequential layout choice here: putting it under `tests/` would make the cross-repo drift check unshippable.

## Two profiles, one binary

| | Profile A — reference host | Profile B — self-contained |
|---|---|---|
| Composition | embedded in a full product | one container |
| Retrieval | vector store + RLS | Postgres + pgvector, RLS alone |
| Bus | JetStream | in-process |
| Auth / billing | host kernel | host concerns re-satisfied in-container |

A is B **plus** the host kernel and heavier backing services — a superset relation. Neither is a fork; both run the same binary and the same manifest schema.

## Phasing

- **Phase 0 — research.** Carried over; see [research.md](./research.md).
- **Phase 1 — contracts.** Complete. Seven contracts, two of them authored fresh to make the boundary explicit.
- **Phase 2 — ports and fakes.** Every `Protocol` plus a fake implementation and its conformance suite. TDD order: the suite exists before the real backend.
- **Phase 3 — graph.** Nodes against fake deps, no infra.
- **Phase 4 — backends.** pgvector and qdrant `RetrievalService`; Redis checkpointer; in-process and JetStream `Bus`.
- **Phase 5 — standalone profile.** Compose topology, entrypoint, smoke, and the isolation assertion.
- **Phase 6 — host integration.** Publish `v0.1.0`; the host pins it and runs the conformance suites.

## Complexity Tracking

> No constitutional violations. Table intentionally empty.

| Violation | Why needed | Simpler alternative rejected because |
|---|---|---|
