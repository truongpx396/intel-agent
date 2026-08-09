<!--
SYNC IMPACT REPORT
==================
Version change: 2.0.0 → 2.1.0
Bump rationale: MINOR. Adds one new principle — X. Verification Before
  Completion (NON-NEGOTIABLE) — requiring evidence (commands + actual output)
  before any human or AI agent claims work complete/fixed/passing. Additive,
  backward-compatible with v2.0.0; Definition of Done extended to reference it.

Prior change (1.0.0 → 2.0.0):
Bump rationale: MAJOR. Materially expands the governance set from 4 to 9
  principles and adds binding architectural mandates (Clean Architecture with a
  layered kernel/product + feature-based structure, API-first/contract-first,
  modular design & feature flags, BFF response shaping). These add new
  NON-NEGOTIABLE constraints and redefine how the Go/Python/React code is
  organized, which is backward-incompatible with the prior, looser v1.0.0.

Modified principles:
  - I. Code Quality (NON-NEGOTIABLE) → retained, expanded (complexity ceiling,
    constants over magic values)
  - II. Testing Standards (NON-NEGOTIABLE) → split into V. Testing Standards
    (layers, table-driven, build tags) + VI. Test-Driven Development
    (NON-NEGOTIABLE)
  - III. User Experience Consistency → renumbered to VIII; canonical error
    schema and response-consistency rules folded in
  - IV. Performance Requirements → renumbered to IX (substance retained)

Added principles:
  - II. Clean Architecture (layered: high-level kernel/product split, lower-level
    feature-based modules; SOLID; consumer-defined interfaces)
  - III. API-First / Contract-First Design
  - IV. Modular Design & Feature Flags
  - VII. Backend for Frontend (BFF) + UI-driven response shaping

Added sections:
  - Technology & Quality Constraints (expanded: per-runtime layout expectations)
  - Development Workflow & Quality Gates (expanded gate ordering)

Templates requiring updates:
  - ✅ .specify/templates/plan-template.md (Constitution Check gate is generic; no change needed)
  - ✅ .specify/templates/spec-template.md (no constitution-specific tokens; no change needed)
  - ✅ .specify/templates/tasks-template.md (task categories align with principles; no change needed)
  - ✅ .specify/templates/checklist-template.md (generic; no change needed)

Consistency notes:
  - specs/001-contextengine-mvp/plan.md keeps the high-level kernel/product split;
    the new feature-based layout applies to the LOWER level inside `internal/`
    (Go), `src/` (Python), and `src/` (React). plan.md's current layer-first
    `internal/{handler,service,repo}` tree SHOULD migrate to feature-first
    `internal/<feature>/{model,dto,service,infra}` during implementation (tasks
    phase); flagged, not auto-edited.

Follow-up TODOs: None.

==================================================================
FORK NOTE — intel-agent 1.0.0 (derived from AISAT Intel 2.1.0)
==================================================================
Extracted from aisat-intel@369756e as the self-contained agent runtime
(Profile B, specs/001-agent-runtime/contracts/agent-runtime.md).

Principles I-VI, IX, and X are carried over BYTE-IDENTICAL and MUST stay
that way: both repos build the same system across a port boundary, so a
divergence in the shared engineering rules is a defect, not a local choice.
Amend them in aisat-intel first, then sync here in one commit.

Changed for a single-runtime (Python 3.12) repo:
  - VII. Backend for Frontend -> NOT APPLICABLE (no Go BFF, no SPA here).
    Replaced by VII. Host Boundary Discipline, which governs what this repo
    actually owns: the AgentDeps port surface and the host contract.
  - VIII. User Experience Consistency -> RESTORED in part. This repo is a
    standalone product with its own CLI and minimal web UI, so the
    accessibility and consistency clauses apply to those surfaces. What stays
    out of scope is a design system: the built-in UI is deliberately minimal
    and renders only from the published event vocabulary.
  - Technology & Quality Constraints -> Python-only toolchain; Go/React
    tooling and the kernel/product depguard rule dropped.
  - Development Workflow -> CI gate ordering drops the frontend/bundle
    checks and adds the cross-repo conformance gate.
-->

# Intel Agent Constitution

> **Scope.** A **standalone AI agent product** that a host can also embed, extracted from
> [aisat-intel](https://github.com/truongpx396/aisat-intel) at `369756e`. It owns the agent
> graph, the `AgentManifest`/`DomainPlugin` composition, and the `AgentDeps` port surface —
> and ships a **minimal default** for ingestion, identity, metering, and a chat interface so
> the product runs alone.
>
> **A default is never privileged code.** It is one implementation of a declared port, held
> to the same conformance suite an override must pass. That rule is what keeps "standalone"
> from becoming "monolith with seams painted on", and it is why multi-tenant billing, org
> management, and the sandbox tier remain host concerns
> (`contracts/host-integration.md`).

## Core Principles

### I. Code Quality (NON-NEGOTIABLE)

All code MUST meet a consistent, enforceable quality bar before it is merged.

- Every change MUST pass the project's automated linters and formatters with zero
  errors: `gofmt`/`golangci-lint` for Go, `ruff`/`black` for Python, and
  `eslint`/`prettier` for React/TypeScript. `//nolint` (and equivalent
  suppressions in Python/TS) require a code-review-approved justification comment.
- Public functions, exported types, and module entry points MUST be documented;
  code MUST be self-explanatory through clear naming over inline commentary.
- Functions MUST have a single responsibility; cyclomatic complexity per function
  MUST NOT exceed the agreed lint ceiling (default 15). Functions and files that
  exceed agreed thresholds MUST be refactored, not suppressed.
- Magic numbers and hard-coded strings on meaningful paths MUST be extracted to
  named constants or configuration values.
- No commented-out code, dead code, or `TODO` without an associated tracked issue
  may be merged.
- Every change MUST be reviewed and approved by at least one other engineer.

**Rationale**: A uniform quality bar across three language ecosystems prevents
divergence, lowers onboarding cost, and keeps the codebase maintainable as it
scales.

### II. Clean Architecture (Layered: Kernel/Product + Feature-Based)

The codebase MUST follow Clean Architecture with two layers of organization,
applying **SOLID** principles adapted per runtime.

**High level — kernel/product split (Go template tier)**: Reusable,
template-level capabilities live in `kernel/` and MUST NEVER import product
code; product/business logic depends on the kernel through interfaces. This
boundary MUST be enforced mechanically (e.g., `golangci-lint depguard`).

**Lower level — feature-based modules**: Within the product/application tier of
each runtime, code MUST be organized **by business capability (feature)**, not
by technical layer. Inside a feature, the dependency direction MUST be
**Transport → Service → Repository → Model**, and each use case SHOULD have its
own file.

- **Go feature layout** (`backend-go/internal/<feature>/`):

  ```
  internal/<feature>/
  ├── module.go      # DI wiring entrypoint: SetupModule(appCtx)
  ├── model/         # domain entities & value objects (zero infra imports)
  ├── dto/           # request/response DTOs (one file per use case)
  ├── errors/        # feature-scoped error definitions
  ├── service/       # business logic (one file per use case, + _test.go)
  └── infra/         # all I/O adapters (external boundary)
      ├── repo/db/   # repositories (database.go + one file per use case)
      └── transport/ # http/ (controller.go + <use_case>_api.go), grpc/
  ```

- **Python feature layout** (`backend-python/src/<feature>/`): mirror the same
  separation — `models/` (or `schemas/`), `service/` (use-case modules),
  `infra/` (repositories, external clients, transport routers). Cross-cutting
  LLM and tool access remain centralized chokepoints (`llm_gateway.py`, the MCP
  server) consumed through interfaces — these are shared platform services, not
  per-feature duplications.
- **React feature layout** (`frontend/src/features/<feature>/`): group by
  feature — `components/`, `hooks/`, `api/`, `types/` per feature — with a
  shared design-system layer for cross-cutting UI. Avoid a global dumping-ground
  of unrelated components.

Rules (all runtimes):

- **SOLID**: Single Responsibility (one use case per file, one concern per
  layer); Open/Closed (extend via new modules, see Principle IV); Liskov (any
  implementation MUST be substitutable without altering correctness — e.g.,
  swapping a real repo for an in-memory one in tests); Interface Segregation
  (small, role-specific interfaces — no "god interfaces"); Dependency Inversion
  (services depend on abstractions, infra satisfies them; wiring at the app
  root only).
- **Consumer-defined interfaces**: Interfaces MUST be declared by the package
  that *uses* them, not the one that implements them ("accept interfaces, return
  structs").
- **Pure inner layers**: `model`/`service` MUST have no infrastructure
  dependencies; transport handlers MUST map DTOs ⇄ domain entities before
  calling services. Domain models MUST NOT carry transport concerns.
- **External-service abstraction**: Every external dependency (payment, email,
  third-party APIs, cloud storage, auth provider) MUST sit behind an interface
  defined in the consuming module; concrete implementations live in that
  feature's `infra/`. (This is why kernel swappable interfaces — Auth, Bus,
  Storage, etc. — exist.)
- **Cross-feature isolation**: A feature MUST NOT import another feature's
  unexported types; inter-feature dependencies go through exported interfaces or
  the shared layer.
- **Dependency injection only**: No global mutable state; wiring happens at the
  application root.

**Rationale**: A reusable kernel keeps template-level concerns swappable and
testable, while feature-based product modules keep each capability cohesive,
independently testable, and removable — preventing the layer-first sprawl that
makes large services hard to change.

### III. API-First / Contract-First Design

Every service boundary MUST be designed and documented as a contract before
implementation begins.

- A machine-readable contract MUST exist and be the single source of truth for
  every external boundary: OpenAPI 3.x for HTTP APIs, and the equivalent
  declared contracts for the NATS subjects, MCP tool surface, SSE event
  taxonomy, and LLM gateway used in this project (see `specs/.../contracts/`).
- HTTP APIs MUST be versioned via a URL path prefix (`/api/v1/`, …) and follow
  semantic-versioning discipline; breaking changes to a published version are
  FORBIDDEN — introduce a new version instead.
- All endpoints MUST return the unified structured JSON error envelope defined in
  Principle VIII.
- Contracts MUST be reviewed and approved before handler/worker code is written
  (this aligns with TDD in Principle VI).

**Rationale**: Designing the contract first lets the three runtimes and external
agents integrate against a stable, reviewable surface and enables code
generation and contract testing.

### IV. Modular Design & Feature Flags

The system MUST be built as composable modules that can be toggled at runtime;
Principle II provides the structural foundation.

- **Registration**: Each feature module MUST expose a single wiring entrypoint
  (Go: `SetupModule(appCtx)` in `module.go`) that builds its repo → service →
  transport graph and registers routes. Only the application root
  (`cmd/api/main.go` and equivalents) performs wiring — no other package may.
- **Feature flags**: Every new user-facing behavior MUST be gated behind a flag
  managed via a centralized source (the kernel `Flags` interface / env / remote
  config). Flag checks MUST be the seam for progressive rollout and kill-switch.
- **Open/Closed**: Adding a feature MUST NOT require modifying another module's
  internals — only the bootstrap registers the new module.
- **Removability**: Disabling or removing a feature module MUST NOT break the
  compilation or runtime behavior of any other module.

**Rationale**: Runtime-toggleable, independently wired modules make rollout,
experimentation, and rollback safe, and keep the system open for extension but
closed for modification.

### V. Testing Standards

The project MUST maintain a comprehensive, multi-layered test suite.

- **Unit tests**: Every service and repository function MUST have unit tests
  covering happy path, edge cases, and error paths. Minimum line coverage target
  is 80% per runtime, and coverage MUST NOT decrease on any change (`go test
  -cover`, `pytest --cov`, `vitest`/`jest --coverage`).
  - **Table-driven (Go)**: Go unit tests MUST use the table-driven pattern
    (`[]struct{ name, input, expected }`) with a descriptive `name` passed to
    `t.Run`. Python SHOULD use parametrized tests (`pytest.mark.parametrize`) for
    the equivalent effect.
  - **Parallel (Go)**: Each `t.Run` sub-test MUST call `t.Parallel()` first
    unless it shares state that is explicitly unsafe for concurrency (which MUST
    be avoided).
- **Integration tests**: Every repository/adapter implementation MUST have
  integration tests against a real (containerized) dependency. Go integration
  tests MUST use the `//go:build integration` build tag and run via
  `go test -tags=integration ./...`, kept separate from the default unit run.
- **Contract tests**: Every API endpoint and service boundary MUST have contract
  tests validating request/response schemas against the declared contract
  (OpenAPI / NATS subjects / MCP tools / SSE / LLM gateway).
- **End-to-end tests**: Critical user journeys MUST have E2E tests exercising the
  full stack. Contract and E2E tests live in a top-level `tests/` directory.
- **Bug fixes**: Every bug fix MUST include a regression test that fails without
  the fix.
- **Determinism**: No flaky tests in `main`; flaky tests MUST be quarantined with
  a tracked issue and fixed promptly, never ignored.

**Rationale**: Layered tests with explicit build-tag separation keep the fast
unit loop clean while still proving behavior against real dependencies and the
published contracts across all three runtimes.

### VI. Test-Driven Development (NON-NEGOTIABLE)

All feature implementation MUST follow a strict TDD workflow.

- **Red**: Write a failing test describing the expected behavior BEFORE writing
  production code; see it fail.
- **Green**: Write the minimum production code to make it pass.
- **Refactor**: Improve the code while keeping all tests green.
- No production code change is permitted without a corresponding test change or
  addition. Pull requests MUST show test commits preceding or accompanying the
  implementation (verifiable in git history).

**Rationale**: Tests written first define intended behavior, catch regressions
early, and make refactoring safe across the Go, Python, and React layers.

### VII. Host Boundary Discipline (NON-NEGOTIABLE)

> Replaces the parent constitution's *VII. Backend for Frontend*, which does not
> apply here — this repo has no BFF and no UI. What it does have is a boundary that
> another system integrates against, so that is what this principle governs.

This runtime is embedded by a host. The boundary is `AgentDeps` plus the security
contract, and nothing else.

- **The port is the boundary.** Everything the runtime needs from a host MUST arrive
  through a declared port (`RetrievalService`, `MemoryService`, `LLMGatewayClient`,
  `ToolRegistry`, `StreamWriter`, checkpointer, `Bus`, `Meter`, `Recorder`,
  `ApprovalStore`, `Policy`). Reaching around a port to a concrete backend — a direct
  Qdrant client, a NATS connection, a provider SDK — is prohibited.
- **Config selects, code enforces.** An `AgentManifest` MAY name an implementation; it
  MUST NEVER *be* one. A manifest can only narrow what an agent may do within the
  principal's existing clearance — no manifest field may widen what a principal sees.
- **The access floor lives below the agent.** Visibility MUST be enforced at row
  granularity beneath the graph (RLS, and a vector pre-filter where one exists), never
  around the tool and never by prompt. This holds identically on every deployment
  profile; fewer lowerings is fewer copies to keep in parity, not fewer guarantees.
- **The graph is manifest-blind and host-agnostic.** No node may read the manifest or
  dereference a host-specific claim key; nodes see `deps.*` and the domain-agnostic
  core of `ctx` only. A new domain is a manifest plus a plugin, never a node edit.
- **What does not travel MUST be declared, not assumed.** Credit metering, RLS GUC
  plumbing, and the moderation provider behind `guard` are host obligations. The
  runtime declares *that* they run; it never implements *how* the host bills or
  authenticates. Every such obligation MUST appear in `contracts/host-integration.md`.
- **Reuse is proven, not asserted.** Every port ships a conformance suite that any
  implementation MUST pass, and the suite MUST be importable by the host repo so
  drift fails a build rather than a review.

**Rationale**: The value of this repo is that it runs somewhere else without a fork.
That property decays silently the moment a node learns a host's shape — so the
boundary is stated as a principle and checked by conformance tests, not left to care.

### VIII. Interface Consistency

The runtime's surfaces are consumed by machines, not people, so consistency is
enforced on the wire format rather than on visual language.

- **Canonical error schema**: All error responses MUST use the structure
  `{ "code", "message", "details" }` with consistent status codes and a shared
  error-code registry, so a host can map them without special-casing.
- **Uniform list semantics**: Pagination MUST use one scheme (cursor or
  offset/limit) with identical parameter names across all list surfaces;
  sorting/filtering/search follow one documented convention.
- **Canonical formats**: Timestamps MUST be ISO 8601 / RFC 3339 in UTC; monetary
  values MUST use the smallest currency unit (integer credits).
- **Stable event taxonomy**: Streamed event names and payload shapes are a versioned
  contract. Adding an event is additive; renaming or re-shaping one is a breaking
  change and MUST be versioned as such.
- **Enum consistency**: A constrained field MUST carry the same enum everywhere it
  appears, so a host generates one shared type.
- Error states MUST be actionable and machine-distinguishable — a caller must be able
  to tell "refused", "degraded", and "failed" apart without parsing prose.

> **Applies to the built-in surfaces.** This repo ships a CLI and a minimal web UI, so
> WCAG 2.1 AA applies to the latter: keyboard navigation, focus management, and
> screen-reader labels. What does *not* apply is a design system — the built-in UI is
> deliberately minimal, renders only from the published event vocabulary, and must not
> grow into a second product surface competing with an embedding host's front end.

**Rationale**: A host integrates against shapes, not screens. Stable, uniformly named
shapes are what make the swap matrix in `contracts/agent-runtime.md` a config change
instead of a porting exercise.

### IX. Performance Requirements

Performance is a feature and MUST be specified, measured, and defended.

- Every feature with user-facing latency MUST define measurable performance
  budgets before implementation. Default targets unless a feature documents an
  exception: API p95 latency < 200ms, initial web page interactive < 2.5s.
- Performance-sensitive paths MUST have benchmarks or load tests; regressions
  beyond the agreed budget MUST block the merge.
- Resource usage (CPU, memory, payload size, bundle size) MUST be bounded and
  monitored; React production bundles MUST track size budgets and fail CI on
  unexplained growth.
- Database and external calls on hot paths MUST avoid N+1 patterns and MUST use
  pagination, indexing, and caching where appropriate.
- Observability (structured logs, metrics, traces) MUST be in place to measure
  the budgets above in production.

**Rationale**: Defining and continuously measuring performance budgets prevents
slow degradation, protects user experience, and keeps infrastructure costs
predictable as usage grows.

### X. Verification Before Completion (NON-NEGOTIABLE)

No work may be claimed as complete, fixed, passing, or done — by a human or an
AI coding agent — without verifiable evidence. Assertions are not evidence.

- **Evidence before assertions**: Any claim that code works, a bug is fixed,
  tests pass, a build succeeds, or a task is complete MUST be accompanied by the
  concrete command(s) run and their actual output (e.g., the `go test`/`pytest`/
  `vitest` summary, the lint/build exit, the failing-then-passing run for a bug
  fix). "It should work" / "this is complete" without output is prohibited.
- **Run it, do not predict it**: The agent MUST actually execute the relevant
  verification (tests, linters, type-checks, the affected code path) rather than
  reasoning that it would pass. Predicted results MUST NOT be reported as facts.
- **Scope honesty**: If only part of the work was verified, the agent MUST state
  exactly what was and was not run, and MUST NOT generalize a narrow check into a
  blanket "everything works." Unverified items are reported as unverified.
- **TDD evidence**: For new behavior, the agent MUST show the test failing before
  the implementation and passing after (Principle VI), not merely assert the
  cycle was followed.
- **Failure transparency**: If verification cannot be run (missing dependency,
  environment limitation), the agent MUST say so explicitly and MUST NOT claim
  completion; it surfaces the blocker instead.
- **No premature success signals**: Do not commit, open a PR, or mark a task done
  until the required evidence has been produced and shown.

**Rationale**: Confident-sounding but unverified completion claims are the most
expensive class of error — they hide regressions, erode trust, and push failures
downstream. Requiring evidence makes "done" mean the same thing for every
contributor, human or agent.

## Technology & Quality Constraints

- **Languages & stacks**: Python 3.12+ only. This repo is deliberately
  single-runtime; adding a second language requires an amendment, not a PR.
- **Tooling baseline**: `ruff`, `black`, `mypy`, `pytest`, `uv` for dependency
  resolution and locking. (The parent repo's Go and React toolchains, and the
  `depguard` kernel/product rule, have no counterpart here.)
- **Project layout**: Feature-based modules under `src/intel_agent/` per Principle
  II — `graph/`, `tools/`, `retrieval/`, `memory/`, `ports/`, `conformance/`.
  Port protocols live in `ports/` and MUST NOT import a concrete backend; concrete
  backends are wired only at the composition root. `conformance/` is public API —
  it is imported by host repos and is versioned as such.
- **Data store**: PostgreSQL (15+) is the primary relational store with RLS for
  tenant isolation; schema changes MUST go through versioned migrations. Every
  hot-path SQL query MUST be validated with `EXPLAIN` and use appropriate
  indexes; no full table scans on large tables.
- **Containerization**: The runtime MUST ship as a Docker image with a multi-stage
  build; `deploy/compose.profile-b.yml` MUST stand the whole thing up standalone,
  and a top-level `Makefile` is the canonical task runner.
- **Standalone-runnable (NON-NEGOTIABLE)**: `make up && make smoke` MUST produce a
  cited answer with no Qdrant, no NATS, and no Go kernel bound. This is the
  repo's reason to exist; a change that breaks it is a release blocker, not a
  regression to triage later.
- **Observability**: Structured JSON logging (`structlog`), OpenTelemetry traces,
  Langfuse LLM tracing, and metrics MUST be wired from day one — and MUST all
  degrade cleanly when unset, since a host may bind none of them.
- **Dependencies**: New third-party dependencies MUST be justified, actively
  maintained, license-compatible, and security-scanned before adoption.
- **Security**: Code MUST be free of the OWASP Top 10 vulnerability classes;
  secrets MUST never be committed and MUST be loaded from the environment.

## Development Workflow & Quality Gates

- **Branching & review**: Trunk-based development; short-lived feature branches
  off `main` with descriptive names (`feat/`, `fix/`, `chore/`). Merges to `main`
  require at least one approving review and a green CI run.
- **Commit messages**: Conventional Commits (`feat:`, `fix:`, `docs:`, `test:`,
  `chore:`).
- **CI gate ordering (all MUST pass before merge)**: lint/format → unit tests →
  integration tests → contract tests → **conformance suite** → **Profile-B smoke**
  → build → security scan, plus the coverage threshold and the eval gate.
- **Cross-repo contract changes**: A change to a port protocol or to
  `contracts/host-integration.md` is a breaking change for every host. It MUST bump
  the minor version at least, name the affected hosts in the PR body, and land
  before the host PR that consumes it — never in the same merge window.
- **Constitution Check**: Plans and specs MUST verify alignment with these
  principles. Any violation MUST be documented with explicit justification or the
  work MUST be revised to comply.
- **Definition of Done**: Contract defined and approved, code reviewed, tests
  passing (TDD order verifiable), coverage maintained, performance budgets met,
  the conformance suite green, the Profile-B smoke green, documentation updated,
  and — per Principle X — the verifying commands and their actual output shown
  before "done" is claimed.

## Governance

This constitution supersedes all other development practices. Where another
document conflicts with it, this constitution prevails.

- **Amendments**: Proposed changes MUST be submitted as a pull request that
  describes the change, its rationale, and migration impact. Amendments require
  approval from project maintainers before they take effect.
- **Versioning policy**: This constitution follows semantic versioning.
  MAJOR for backward-incompatible governance or principle removals/redefinitions,
  MINOR for newly added or materially expanded principles/sections, and PATCH for
  clarifications and non-semantic refinements.
- **Compliance review**: All pull requests and design reviews MUST verify
  compliance with these principles. Reviewers MUST reject changes that violate a
  NON-NEGOTIABLE principle without a documented, approved exception.
- **Runtime guidance**: Use `.github/copilot-instructions.md` and the active
  plan for day-to-day development guidance consistent with this constitution.
- **Shared-principle sync**: Principles I-VI, IX, and X are shared verbatim with
  [aisat-intel](https://github.com/truongpx396/aisat-intel). They are amended
  **there first**, then synced here in a single `chore(constitution):` commit that
  changes nothing else. A local-only edit to a shared principle is a defect.

**Version**: 1.0.0 | **Ratified**: 2026-08-09 | **Last Amended**: 2026-08-09
**Derived from**: AISAT Intel Constitution 2.1.0 @ `aisat-intel@369756e`
