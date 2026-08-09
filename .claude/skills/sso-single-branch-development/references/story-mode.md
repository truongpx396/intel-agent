# Story Mode (Optional) — Story-Scoped Phased TDD

Story mode is an **alternate execution core** for this skill, tuned to the way spec-driven plans
(e.g. Spec Kit `tasks.md`) lay out a **behavioral user story**: not as a stream of self-contained
test+impl units, but as **two task groups with distinct IDs** —

```
### Tests for User Story N ⚠️ (write first, must fail)   → contract/integration tests, all [P]
### Implementation for User Story N                       → models/services/endpoints/UI
```

The test group is written **first and must fail (Red)**; the implementation group then makes it pass
(Green). That is *story-scoped, outside-in TDD (ATDD)* — and it does **not** fit SDD's per-task loop,
which assumes *a task = one behavioral unit you test-drive*. Here a test task (e.g. `T035`) and its
implementing task (e.g. `T043`) are **separate IDs in different files/runtimes**; you cannot run
per-task red→green on a *test-only* task, because its green arrives later from one or more impl tasks.

Story mode realigns the core to that layout: **batch the RED**, review it, then **green
incrementally**. Everything around the core — preflight, isolation, run-log/`RUN_ID`, hooks, the
evidence gate, the draft-PR finish — is unchanged.

## Why it exists

- **The task file already prescribes it.** Spec Kit groups tasks *tests → models → services →
  endpoints → integration* and states outright: *"tests are written first (Red), must fail, then
  implementation makes them pass (Green)."* The plan's own unit of test-first discipline is the
  **story**, not the task.
- **Per-task TDD literally cannot run here.** A contract-test task produces a failing test and
  nothing to green *within that task*; its green is spread across several later impl tasks (often in
  a different runtime). Forcing SDD's "write a failing test *inside* the task, then green it" onto a
  Spec Kit stage double-authors tests or skips the red step.

## The inverse of scaffold mode

Story mode is the **mirror image** of [scaffold mode](scaffold-mode.md): scaffold mode is for the
*non-behavioral* edges of a plan and **refuses** anything with a test obligation or trust boundary;
story mode is for the *behavioral, security-critical heart* and **requires** exactly those. Its own
mirror is [refactor mode](refactor-mode.md), the *keep-green* sibling: story mode starts RED (new
failing tests) and drives to green, whereas refactor mode starts GREEN and stays green because it adds
no behavior. Any work that **changes or adds** behavior (including a bugfix) is story mode;
behavior-**preserving** restructuring is refactor mode.

| | Scaffold mode | **Story mode** |
|---|---|---|
| Eligibility guard | refuse if any task is behavioral / trust-boundary | **require** a story stage with a `### Tests` + `### Implementation` split |
| Tests | dropped (nothing to test) | **batched up front (RED), then reviewed and frozen** |
| Review | quality **+ governance** (constitution — hard gate) | quality **+ governance + security** (`security-and-owasp.instructions.md`) — mandatory |
| Green phase | n/a | **incremental** — each impl task/cluster flips an identifiable subset green |
| TDD | dropped | **kept, at story scope** (RED batch = the story's failing acceptance suite) |

### Eligibility

Use story mode for **all behavioral work**. The canonical case is a spec-driven **user-story stage**
whose tasks split into a write-first `### Tests` group (carrying the story's contract/acceptance/
**security** criteria — access scope, injection resistance, clearance) and a separate
`### Implementation` group. A **lone feature or bugfix is just story mode with N=1** — a one-test RED
batch → freeze → one green — so there is **no** separate per-task core to fall back to. Only pure
non-behavioral bootstrap routes elsewhere → [scaffold mode](scaffold-mode.md). A self-contained
behavioral task that owns its own micro red-green is simply an N=1 story run.

## Pipeline (story core)

The preflight/isolate/governance entry and the draft-PR boundary are identical to the universal
bracket. The core is a **RED batch → review → incremental GREEN → converge** sequence. **Gates are
named, not numbered** — the SKILL body numbers its bracket 1–8, so a bare number means different
things in the two documents:

```
[bracket]     Preflight & isolate branch                  [reuse: track-preflight.sh, using-git-worktrees]
[bracket]     GOVERNANCE GATE — discover, distil, persist
              runs/<RUN_ID>.governance.md                 [reuse: references/governance.md]
MODE GUARD    confirm the batch is behavioral (a ### Tests
              + ### Impl split, or an N=1 task with its
              own test)                                   [non-behavioral? → scaffold mode]
RED BATCH     fan-out generate the ### Tests group ([P]
              disjoint), apply serially, RUN, assert the
              WHOLE group fails correctly                 [parallel gen ✅ dispatching-parallel-agents]
RED REVIEW    review + FREEZE the failing test suite      [serial → requesting-code-review + security]
   GATE
GREEN         implement ### Impl in dependency order; each
(incremental) task/cluster flips an identifiable subset
              green, reviewed per increment               [serial → subagent-driven-development]
CONVERGENCE   freeze, run the whole story suite + every
   GATE       evidence kind against ONE fingerprint       [serial → verification-before-completion]
[bracket]     Draft-PR finish                             [overrides finishing-a-development-branch]
```

### Which superpowers skill runs at which step

Every step's owning skill is **explicit**. Unlike scaffold mode, the SDD core skills are **present**:
this stage is behavioral, so `test-driven-development` (via the RED batch) and
`subagent-driven-development` (the green loop) both apply.

| Step | Action | Skill (`—` = no skill) | Why this skill |
|---|---|---|---|
| 0 | Preflight & isolate | `track-preflight.sh` + `using-git-worktrees` | Durable run identity; one branch, one worktree |
| 1 | Story-stage guard | — (local eligibility guard) | Confirm the batch is behavioral; route pure non-behavioral bootstrap to scaffold mode |
| 2 | RED batch authoring | `dispatching-parallel-agents` (+ `test-driven-development`) | `[P]` tests are disjoint → generate in parallel; the batch **is** the story's failing acceptance suite |
| 3 | RED review + freeze | `requesting-code-review` + `security-and-owasp` | A wrong test = false confidence; these encode clearance/injection criteria, so security review is mandatory |
| 4 | Incremental green | `subagent-driven-development` | Per-task implement→review loop, but the "test" is the pre-authored red test each task must green |
| 5 | Converge & verify-all | `verification-before-completion` | Whole story suite green + all evidence kinds on one fingerprint |
| 6 | Draft-PR finish | **overrides** `finishing-a-development-branch` | Worker stops at a draft PR; merge owned by repo/CI |

### RED BATCH — generate in parallel, but it must actually fail

The `### Tests` group is `[P]` (disjoint files), so its **generation** fans out exactly like scaffold
mode: N read-only subagents each *return one test file body as text*; the controller (single writer)
applies them all. The crucial difference from scaffold mode: these files are **run**, and the batch is
accepted only when the **whole group fails for the right reason** — a compile error, a skipped-then-red
assertion, or a genuine unmet expectation, **not** a typo or a missing import. "Red for the wrong
reason" is a silent hole; assert real red before proceeding.

**Each RED-author subagent's brief carries the governance bundle** (see
[`governance.md`](governance.md) — re-read it from `runs/<RUN_ID>.governance.md`, never from memory): the relevant **constitution** principles, the `.github/instructions/*` matching
the files under test, and — because story-scope tests encode security behavior (access-scope, injection
resistance, clearance) — `security-and-owasp.instructions.md`. For **frontend test clusters** (files
testing `.tsx`/`.ts`/`.jsx` components), also include the relevant design artefacts collected during
governance discovery (`.stitch/designs/<page>.html` and/or `design-system/` page spec, if they
exist) — so the tests assert the correct design intent, not an inferred one. Pass silently if absent.
The tests a maker writes must *assert* the governance criteria, not just happy-path behavior, so the
frozen suite already pins them down before any implementation exists. This complements the RED review
gate, which re-applies the same governance as the checker backstop.

### RED REVIEW GATE — review and FREEZE the tests before greening

A batch of unreviewed tests is worse than no tests: it manufactures false confidence, and here the
tests define **security** behavior (access-scope, injection resistance, memory clearance). So the RED
suite gets a full `requesting-code-review` pass **plus** the governance gate — the project
constitution (hard) and any `.github/instructions/*` matching the changed files — **plus**
`security-and-owasp.instructions.md` *before* any implementation. After this gate the tests are **frozen**: the green phase may add production code
only. **Greening by weakening a test — deleting an assertion, loosening a matcher, `skip`-ing a
case — is forbidden.** If a test is genuinely wrong, route the fix back through this RED review gate;
never edit it silently mid-green.

### GREEN — incrementally, not big-bang

This is the deliberate rejection of "implement everything, then check the whole suite green at the
end." Implement the `### Implementation` group in **dependency order** and drive the frozen red suite
toward green in **reviewable increments** — each impl task (or a small `[P]` cluster) flips an
*identifiable subset* of the suite green. This is just SDD's normal loop, with one twist: the
implementer does **not** author a new test (the RED batch already did) — its contract is *"make these
specific red tests green without weakening them."* You keep SDD's per-increment stage-1 (spec) +
stage-2 (quality, + security on trust-boundary tasks) review.

**When invoking `subagent-driven-development`, explicitly carry the governance bundle** (constitution
excerpts + matched `instructions/*` content, re-read from `runs/<RUN_ID>.governance.md`) into
SDD's per-task maker subagent briefs. Subagents have isolated context — they will not see VS Code's
injected instructions unless the brief includes the content. A brief that names a file without its
content is an empty reference. Each per-task maker must satisfy the governance constraints *while
implementing*, so the reviewer's role is a backstop, not the first application.

Why not big-bang green (the literal "green as a whole" form):

- **Long red period discards TDD's feedback loop** — the whole point of red→green is the *tight*
  cycle; a story-long red suite gives no signal until the end.
- **Big-bang integration → big-bang debugging** — if fifteen impl tasks land and the suite is still
  red, you cannot localize which task broke which test.
- **One giant diff makes maker/checker review mushy** — coherent per-increment diffs review far
  better than a 20-file dump.

Batching the *test authoring* up front is what aligns with the file layout; batching the
*green* is what throws away the loop. Story mode keeps the first and refuses the second.

### CONVERGENCE GATE — converge on one fingerprint

Identical to the universal bracket's freeze & verify-all: once the last impl increment
greens its subset, make **no further edits**, then run the whole story test suite plus every required
evidence kind
(`go-test`, `pg`, `redis`, browser E2E, …) back-to-back so all captures share one whole-tree
fingerprint. The story's Definition of Done is its **Checkpoint** line (e.g. *"US1 fully functional —
ingest … browsable library"*) realized as green output you paste, not assert.

## What story mode changes vs. keeps

| Aspect | Per-task SDD (inside green) | Story core (whole story) |
|---|---|---|
| Test authoring | Per task, interleaved with impl | **Batched up front** as the story's RED suite (generation fans out) |
| Test review | Folded into per-task review | **Dedicated RED review + freeze gate** before any green (quality + security) |
| Green | Per task | **Incremental** — each impl task/cluster greens a subset of the frozen suite |
| TDD | Per task, if the task says so | **At story scope** — the RED batch is the failing acceptance suite |
| Security review | Per trust-boundary task | **On the RED suite up front** *and* per trust-boundary impl task |
| Evidence | Per task, converged at freeze & verify-all | Whole story suite + all kinds on one fingerprint (convergence gate) |
| Preflight / isolation / run-log / hooks / draft-PR | — | **Identical (reused)** |

## When to use / when to refuse

**Use** for behavioral **user-story stages** laid out as a write-first `### Tests` group + a separate
`### Implementation` group — the bulk of a spec-driven plan (US1…USN).

**Refuse** (→ [scaffold mode](scaffold-mode.md)) only when the batch is pure non-behavioral bootstrap.
A self-contained behavioral task does **not** route elsewhere — it runs here as an N=1 story (one-test
RED batch → freeze → one green). The Foundational stage is a mix — its chokepoints (LLM gateway, MCP
server, access filter) are security-critical and *do* follow tests-first, so they suit story mode; its
pure platform-client wiring runs as small N=1 story tasks (or scaffold mode, where a given file is
genuinely non-behavioral config).

## Composition

Story mode is still **one branch, one worktree**. Its parallelism is confined to the read-only RED
*generation* phase; RED review, green, and convergence are serial. It is **not** a substitute for
`sso-executing-parallel-tracks` (worktree-per-track): a parallel orchestrator may dispatch one story-mode
run per user-story track, each greening its own frozen RED suite in its own worktree.
