<!-- Extracted from aisat-intel@369756e (specs/001-contextengine-mvp/spec.md).
     Requirements are RENUMBERED to a local series; the mapping table at the
     bottom is authoritative for tracing any requirement back to its origin.
     Reframed for the audience this repo actually has: an integrating host. -->

# Feature Specification: Self-Contained Agent Runtime

**Branch**: `001-agent-runtime` | **Extracted**: 2026-08-09 | **Source**: [aisat-intel@369756e](https://github.com/truongpx396/aisat-intel/blob/main/specs/001-contextengine-mvp/spec.md)

## Overview

A stateful RAG agent runtime that a host system embeds to answer natural-language questions with citations, strictly scoped to what the requester is cleared to see. It adapts to a new domain by swapping a **manifest** (config) plus a thin **domain plugin** (code) — never by forking the graph.

**Who this is for.** The direct consumer is an *integrating engineer* wiring the runtime into a product; the indirect consumer is that product's end user. Requirements below are written from whichever of those two the requirement actually serves — a distinction the source spec did not need to make, because there the runtime and the product were the same codebase.

**What this is not.** Not a product. It has no UI, no auth, no billing, no ingestion pipeline. Those are host concerns, enumerated in [contracts/host-integration.md](./contracts/host-integration.md).

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Answer a question under a visibility floor (Priority: P1)

A member asks a question. The runtime routes it, retrieves candidate context **already filtered** by the caller's visibility predicate, reranks, assembles, and generates a cited answer.

**Why P1**: This is the runtime's reason to exist. Everything else is a qualifier on this sentence.

**Acceptance**:
1. **Given** a corpus containing documents above the caller's clearance, **When** the caller asks a question those documents would answer, **Then** the answer never cites, quotes, or is influenced by them, and they are `not_found` — not "filtered out of the response".
2. **Given** retrieval returns nothing, **When** the run completes, **Then** the answer says so and `source_count == 0` is reported as a valid state, not an error.
3. **Given** a golden query set, **When** run offline against scripted model responses, **Then** no test reaches a real provider.

### User Story 2 — Embed the runtime in a second, unrelated domain (Priority: P1)

An engineer integrates the runtime into a product with a different access model, different tools, and different backing services — writing only a manifest and a `DomainPlugin`.

**Why P1**: This is the property that distinguishes this repo from the code it was extracted from. Untested, it decays within one release.

**Acceptance**:
1. **Given** a test-only `DomainPlugin` (different tools, a `per_customer` policy), **When** the *unmodified* graph runs, **Then** it produces a cited answer end-to-end.
2. **Given** a `ctx` whose `claims` bag holds an opaque, product-unknown key, **When** the graph runs, **Then** it completes without any node dereferencing that bag.
3. **Given** a manifest naming a broader `allowed_tools` than the principal's clearance permits, **When** a run executes, **Then** no row above clearance is surfaced — the manifest narrowed nothing and widened nothing.

### User Story 3 — Run standalone, with no host kernel (Priority: P1)

An engineer stands the runtime up alone — one container, one Postgres, Redis, an OpenAI-wire endpoint — and gets a cited answer with no Qdrant, no NATS, and no Go kernel.

**Why P1**: "Self-contained" is a checked capability or it is marketing.

**Acceptance**:
1. **Given** the Profile-B compose topology, **When** `make up && make smoke` runs, **Then** a cited answer is produced.
2. **Given** the same run, **When** isolation is asserted, **Then** no forbidden client is importable, no forbidden service is in the topology, and no `QDRANT_*`/`NATS_*` config is present.
3. **Given** the access-correctness suite, **When** run under the RLS-only lowering, **Then** it passes **unchanged** from the two-store profile.

### User Story 4 — Survive interruption without re-spending (Priority: P2)

A long-horizon run is interrupted mid-flight and resumes from its last completed step.

**Acceptance**:
1. **Given** a worker killed mid-run, **When** a new worker claims it, **Then** it resumes at the last completed node boundary and re-spends nothing already settled.
2. **Given** a checkpoint pointer whose stored checkpoint is gone, **When** resume is attempted, **Then** the run fails explicitly as `checkpoint_lost` — never a silent restart.
3. **Given** a run past its wall-clock deadline, **When** the next node boundary is reached, **Then** it ends `deadline_exceeded` with spend settled.

### User Story 5 — Stop and ask a human before acting (Priority: P2)

An action that reaches outside the corpus or mutates stored content pauses for explicit human approval.

**Acceptance**:
1. **Given** a run reaching an action gate, **When** it pauses, **Then** it spends **zero** credits while pending and performs no side effect on its subject.
2. **Given** an approval, **When** the run resumes, **Then** it continues **exactly once** from the gate — no settled node re-runs and nothing is re-spent.
3. **Given** a rejection, **When** the run short-circuits, **Then** the action never executes and nothing is mutated.
4. **Given** time spent paused, **When** the deadline is evaluated, **Then** paused time does not count against it.

### User Story 6 — Ask instead of guessing (Priority: P3)

When a question is ambiguous in a way that would materially change the answer, the runtime asks which reading was meant.

**Acceptance**:
1. **Given** a materially ambiguous question, **When** routed, **Then** the turn ends in a clarification offering 2–4 concrete options plus free text — never a fixed menu with no escape.
2. **Given** the golden query set, **When** measured, **Then** clarification fires on ≤ 10% of unambiguous queries.

### Edge Cases

- A moderation provider timeout **blocks** the query, spends nothing, and never reaches retrieval.
- A rerank outage degrades to fusion order and still produces a cited answer; a retrieval outage fails the run.
- A memory outage produces an answer with `memories == []`, recorded as degraded.
- A tool returning malformed data is a handled outcome, not an exception that escapes the node.
- Every degradation is **recorded**; none is smoothed over into a clean-looking run.

---

## Requirements *(mandatory)*

### Functional Requirements

**Safety and untrusted input**

- **AR-001**: The runtime MUST screen each input and short-circuit disallowed content or prompt-injection attempts **before** retrieval or spend, recording the event.
- **AR-002**: The runtime MUST treat all retrieved content and tool output as **untrusted data, never as instructions**, and MUST NOT let injected text trigger additional tool calls or escalate tool access.
- **AR-003**: Retrieved and external content MUST be structurally delimited when placed in a prompt, so instruction text inside a document cannot be read as an instruction to the model.

**Tools and actions**

- **AR-004**: The runtime MUST expose read-only tools as the default tier, plus a small set of **HITL-gated action tools** that are the only agent actions permitted to reach outside the corpus or mutate stored content.
- **AR-005**: The runtime MUST gate every action that mutates the index, applies a model-suggested security attribute, or reaches outside the corpus on an **explicit human approval recorded durably before the action runs and before any spend**.
- **AR-006**: A gated action pending approval MUST consume **zero** credits and perform no side effect on its subject.
- **AR-007**: An approval decision MUST be human-authored and MUST NEVER be derived from model, tool, or document output.

**Retrieval and answering**

- **AR-008**: Every retrieval MUST apply the caller's visibility predicate **inside the store as a pre-filter**. Post-filtering results in application code is prohibited.
- **AR-009**: The runtime MUST support scoping a question to specific documents the caller may read. Scoping **narrows** the retrieval set; it never widens authorization.
- **AR-010**: The runtime MUST answer questions about image content with a multimodal call at query time, treating image bytes as untrusted input.
- **AR-011**: When a question is ambiguous in a way that materially changes the answer, the runtime MUST ask which reading was meant — 2–4 concrete options plus an always-available free-text reply — and MUST end that turn there.
- **AR-012**: After an answer, the runtime MUST generate 2–3 follow-up suggestions derived from the answer context, scoped to the caller's clearance, and MUST suppress them when the answer was refused or had no sources.
- **AR-013**: The runtime MUST retain conversational session context so follow-ups are answered coherently, re-filtering recalled memory against **current** clearance every turn.

**Budgets and durability**

- **AR-014**: The runtime MUST persist long-horizon runs durably so they resume after interruption, support cancellation, and enforce a hard per-run cost cap independent of any daily budget.
- **AR-015**: Every run MUST be bounded in **time and work**, not only money: a wall-clock deadline on all runs and a step cap on long-horizon runs, evaluated at a resumable boundary. **Time spent awaiting human approval MUST NOT count against the deadline.**
- **AR-016**: A lost checkpoint MUST fail the run explicitly, never restart it silently — a restart would re-spend settled credits.

**Observability and audit**

- **AR-017**: The runtime MUST emit, per answer, an observable trace of every retrieval and generation step — intent, tool, index tier, access-filter result, scores, injected memory, model, token cost — sufficient for a host to render a debug view. Rendering is the host's concern.
- **AR-018**: The runtime MUST emit operational telemetry for every step: exactly one lifecycle start and one terminal record per executed node, carrying a full correlation set, plus aggregate metrics for duration, outcome, degradation, and budget exhaustion.
- **AR-019**: The runtime MUST emit an audit entry for every tool call — tool, role, cost, result fingerprint, trace reference — **including failures**. A tool call that cannot be audited MUST NOT run.
- **AR-020**: The runtime MUST scrub personally identifiable information from prompts and responses before they reach trace or evaluation stores, and MUST NOT write raw bodies to telemetry. No metric label may carry a tenant, principal, or id.

**Evaluation**

- **AR-021**: The runtime MUST ship an evaluation seed set — prompt cases plus a golden retrieval set — used as a regression tripwire, including a hard assertion that a query never returns a document above the caller's clearance.
- **AR-022**: The evaluation set MUST **grow from observed failures**: every agent-behavior defect MUST be added as a permanent case, reproduced from its recorded trace, before its fix is considered complete.

**Portability**

- **AR-023**: No node may read the manifest or dereference a host-specific claim. A new domain MUST be a manifest plus a plugin, never a node edit.
- **AR-024**: The runtime MUST run with no vector-database client and no message-bus client bound, retrieving through a single relational store and executing worker roles in-process.
- **AR-025**: Every port MUST ship a conformance suite importable by host repositories, so contract drift fails a build rather than a review.

### Key Entities

- **AgentManifest** — the complete, portable description of one agent: prompts, allowed tools, model aliases, retrieval binding, bus binding, channels, budgets, policy selector, write scope. Data the runtime reads; never behavior.
- **DomainPlugin** — the only code a new domain writes: tool bodies and an authorization `Policy`.
- **AgentState** — the graph's state schema; `intent` and `model_alias` are written by exactly one node.
- **SecurityCtx** — a domain-agnostic core (`tenant`, `principal`, `agent_role`, `allowed_tools`, `trace_id`, `stream_id`) plus an **opaque** `claims` bag the runtime never dereferences.
- **AgentRun** — durable record of a long-horizon run; its `state` is a checkpoint **pointer**, never the payload.
- **ApprovalRequest** — durable, approver-scoped record of a human gate.

---

## Success Criteria *(mandatory)*

- **SC-A01**: **100% access-control correctness.** Across all queries, a caller never receives, cites, or is influenced by a document above their clearance or outside their tenant. Release blocker at anything below 100%.
- **SC-A02**: The access-correctness suite passes **unchanged** under both the two-store (RLS + vector pre-filter) and single-store (RLS-only) lowerings.
- **SC-A03**: For the golden set, ≥ 85% of questions surface the correct source pre-rerank; ≥ 80% post-rerank; MRR ≥ 0.70.
- **SC-A04**: Disallowed and injection inputs are refused **before** any retrieval or spend in 100% of seeded canary cases.
- **SC-A05**: Every answer carries an observable trace of all retrieval and generation steps, including cost.
- **SC-A06**: An interrupted long-horizon run resumes and completes — or cancels cleanly — without loss, and never exceeds its per-run cap.
- **SC-A07**: 100% of gated actions record a human decision before proceeding. A pending or rejected gate spends zero credits and mutates nothing.
- **SC-A08**: 100% agent-write correctness — an agent edit never modifies content outside its `min(agent, owner)` clearance or tenant, and never raises an access level above its source floor.
- **SC-A09**: Clarification is rare and useful — fires on ≤ 10% of unambiguous golden queries.
- **SC-A10**: A second-domain `DomainPlugin` runs the unmodified graph green end-to-end.
- **SC-A11**: The standalone profile produces a cited answer with no vector-DB and no message-bus client bound, asserted positively **and** negatively.

---

## Traceability to aisat-intel

Authoritative mapping back to [the source spec](https://github.com/truongpx396/aisat-intel/blob/main/specs/001-contextengine-mvp/spec.md). Requirements marked **shared** remain binding in both repos: the runtime owns the emission or enforcement point, the host owns the surface.

| Local | Source | Ownership |
|---|---|---|
| AR-001 | FR-010 | runtime |
| AR-002, AR-003 | FR-011 | runtime |
| AR-004 | FR-012 | runtime |
| AR-005, AR-006 | FR-040 | **shared** — runtime pauses; host persists and resolves |
| AR-007 | FR-040 | runtime |
| AR-008 | FR-007 (data-layer floor) | **shared** — runtime lowers; host sets store context |
| AR-009 | FR-042 | runtime |
| AR-010 | FR-044 | runtime |
| AR-011 | FR-045 | runtime |
| AR-012 | FR-031 | **shared** — runtime generates; host renders chips |
| AR-013 | FR-009 | runtime |
| AR-014 | FR-028 | runtime |
| AR-015 | FR-028a | runtime |
| AR-016 | FR-028 (checkpoint rule) | runtime |
| AR-017 | FR-021 | **shared** — runtime emits fragments; host renders the panel |
| AR-018 | FR-021a | runtime |
| AR-019 | FR-023 | **shared** — runtime emits; host owns the durable chain |
| AR-020 | FR-024 | runtime |
| AR-021 | FR-030 | runtime |
| AR-022 | FR-030a | runtime |
| AR-023, AR-024, AR-025 | agent-runtime.md invariants 4–6 | runtime (new: previously contract-only, now spec-level) |
| SC-A01 | SC-001 | **shared** — release blocker in both |
| SC-A02 | agent-runtime.md, "access floor is profile-invariant" | runtime |
| SC-A03 | SC-002, SC-003 | runtime |
| SC-A04 | SC-007 | runtime |
| SC-A05 | SC-005 | shared |
| SC-A06 | SC-009 | runtime |
| SC-A07 | SC-014 | shared |
| SC-A08 | SC-015 | runtime |
| SC-A09 | SC-017 | runtime |
| SC-A10, SC-A11 | agent-runtime.md contract obligations | runtime |

**Deliberately left in aisat-intel** (host product surface, no counterpart here): FR-001–FR-006 and FR-008 (ingestion, tagging, indexing), FR-013–FR-020 (workspace, invites, credits, budgets), FR-022 (admin dashboard), FR-025–FR-027 (local agent registration and device PATs), FR-029 (credit purchase), FR-032–FR-039 (notifications), FR-043 (chat attachment ingestion), and SC-004, SC-006, SC-008, SC-010–SC-013, SC-016.

---

## Assumptions

- The host stamps `ctx` in a trusted layer. The runtime cannot verify this and does not try.
- The host is the single writer of any credit ledger; the runtime only emits spend events with an idempotency key.
- An OpenAI-wire endpoint is reachable and holds the provider keys; the runtime holds none.
- Postgres supports row-level security. The single-store profile depends on it as the sole access floor.

## Out of Scope

Multi-domain **hosting** — a manifest registry, per-manifest routing, a plugin loader — is Phase 2. Phase 1 builds and CI-smokes the standalone capability so it cannot silently rot, but operates exactly one manifest and one plugin.

Also out of scope, permanently: transport, UI, auth, billing, ingestion, and the sandbox tier. These are the host's, by [contracts/host-integration.md](./contracts/host-integration.md).
