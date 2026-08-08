# Refactor Mode (Optional) — Behavior-Preserving Keep-Green

Refactor mode is the **third execution core** for this skill (the other two are
[scaffold mode](scaffold-mode.md) and [story mode](story-mode.md)). It handles a shape neither of the
others fits: **behavior-preserving change to existing behavioral code** — rename, extract, inline,
de-duplicate, restructure, move a module, split a function, change an internal data structure, or
retype an interface — where the observable behavior and the public contract stay **exactly the same**.

Everything **around** the core is unchanged — the same preflight, isolation, run-log/`RUN_ID`, hooks
bundle, evidence gate, and draft-PR finish. Only the core discipline swaps: instead of driving a RED
suite to green (story) or generating non-behavioral files (scaffold), refactor mode **pins the existing
suite green and holds it green through every step.**

## Why it exists

The mode guard used to be binary — *behavioral* → story mode (author **new failing** tests first);
*non-behavioral bootstrap* → scaffold mode. A refactor fits neither:

- It **touches behavioral code**, so scaffold mode (which refuses anything behavioral or
  trust-boundary) correctly rejects it.
- It **adds no behavior**, so story mode's "supply a failing RED suite up front, then green it" is the
  wrong discipline: there is nothing to make fail. The correct safety net is the *opposite* — the
  existing tests are already green and must **stay** green, and where they under-cover the surface
  you're about to move, you add **characterization tests that pass immediately**.

Without a dedicated core, a refactor either gets mis-framed as story work (inventing artificial red) or
sneaks through with no discipline at all. Refactor mode names the keep-green invariant so the change is
provably behavior-preserving.

## The inverse of story mode

Refactor mode is the **mirror image** of [story mode](story-mode.md), and both are distinct from
scaffold mode:

| | Scaffold mode | Story mode | **Refactor mode** |
|---|---|---|---|
| Eligibility guard | non-behavioral bootstrap only | **adds/changes** behavior | **preserves** behavior on existing code |
| Starting test state | none (nothing to test) | **RED** (new failing suite) | **GREEN** (existing suite already passes) |
| Test authoring | dropped | RED batch **must fail** first | characterization tests **must pass** first |
| Invariant | build + bring-up | drive red → green | **stay green every step** |
| Frozen artifact | — | the RED suite (green adds prod code only) | the characterization/behavioral suite (transform preserves it) |
| A red test means | n/a | expected, then fixed | **failure — behavior changed → route to story mode** |
| TDD | dropped | kept (story-scoped RED) | replaced by **keep-green** |
| Review | quality-only | RED review + per-increment (+ security) | characterization review + per-step (+ security) |

### Eligibility

Use refactor mode when **all** of these hold:

1. The change touches **existing behavioral code** (so scaffold mode is out), **and**
2. It **preserves observable behavior** — same inputs produce same outputs, same request/response
   shape, same persistence contract, same error semantics, **and**
3. It **introduces no new behavior** and **no new trust-boundary surface**.

Route away if:

- **Behavior or contract changes** → [story mode](story-mode.md). This includes any new feature, a
  changed API shape, a new validation rule, or a different error.
- **It is a bugfix** → story mode **N=1**, prefixed with `systematic-debugging`. A bugfix *changes
  wrong behavior into right behavior* — that is a behavior change, the opposite of a refactor. Do not
  smuggle a fix inside a refactor; land the fix as its own red→green story, then refactor separately.
- **It is pure non-behavioral bootstrap** (new skeletons, configs, manifests) → [scaffold
  mode](scaffold-mode.md).

> **Refactor + behavior change in one PR is the classic trap.** If a step both restructures *and*
> alters behavior, split it: land the behavior change as a story (red→green), then refactor under
> keep-green. Mixing them means neither the green suite nor the RED suite can prove which half is
> correct.

## Pipeline (refactor core)

The preflight/isolate/governance entry and the draft-PR boundary are identical to the universal
bracket. The core is a **pin-green → characterize → incremental keep-green transform → converge**
sequence. **Gates are named, not numbered** — the SKILL body numbers its bracket 1–8, so a bare
number means different things in the two documents:

```
[bracket]     Preflight & isolate branch                  [reuse: track-preflight.sh, using-git-worktrees]
[bracket]     GOVERNANCE GATE — discover, distil, persist
              runs/<RUN_ID>.governance.md                 [reuse: references/governance.md]
MODE GUARD    confirm the change is behavior-preserving
              (no new/changed behavior, no contract
              change, no new trust boundary)              [adds behavior? → story; bootstrap? → scaffold]
PIN-GREEN     run the existing suite over the surface,
   GATE       confirm GREEN; where coverage is thin author
              characterization tests that MUST PASS
              immediately, then review + FREEZE the net   [gen fans out ✅ dispatching-parallel-agents + requesting-code-review]
TRANSFORM     apply the refactor in small reviewable
(incremental) steps; the WHOLE suite stays green after
              EVERY step; per-step stage-1/2 (+ security) [serial → subagent-driven-development]
CONVERGENCE   freeze, run the whole suite + every evidence
   GATE       kind on ONE fingerprint; contract unchanged [serial → verification-before-completion]
[bracket]     Draft-PR finish                             [overrides finishing-a-development-branch]
```

### Which superpowers skill runs at which step

| Step | Action | Skill (`—` = no skill) | Why this skill |
|---|---|---|---|
| 0 | Preflight & isolate | `track-preflight.sh` + `using-git-worktrees` | Durable run identity; one branch, one worktree |
| 1 | Behavior-preserving guard | — (local eligibility guard) | Confirm no behavior/contract change; route feature/bugfix to story, bootstrap to scaffold |
| 2 | Pin green + characterize | `dispatching-parallel-agents` (gen) + `requesting-code-review` | Thin-coverage characterization tests are disjoint → generate in parallel; a wrong safety net is worse than none |
| 3 | Incremental transform | `subagent-driven-development` (+ `security-and-owasp` on trust boundaries) | Per-step implement→review loop, but the contract is *"restructure without turning any test red"* |
| 4 | Converge & verify-all | `verification-before-completion` | Whole suite green + all evidence kinds on one fingerprint; contract diff confirmed empty |
| 5 | Draft-PR finish | **overrides** `finishing-a-development-branch` | Worker stops at a draft PR; merge owned by repo/CI |

### PIN-GREEN GATE — pin green, then characterize (the mirror of the RED batch)

Two sub-steps, in order:

1. **Pin.** Run the existing suite over the surface you're about to touch and confirm it is **green
   now**. If it is already red, stop — you cannot refactor under a broken baseline; fix the failure as
   its own story first.
2. **Characterize the gaps.** Wherever the code you're about to move is thinly covered, author
   **characterization tests** that capture its *current* observable behavior. These are the exact
   inverse of story mode's RED batch: they must **pass immediately**. A characterization test that
   fails at baseline is a **wrong test** — it does not reflect current behavior — *not* a bug you just
   found. Route it back and correct it; never change production behavior to make it green. (If you
   genuinely discovered a bug, that is story-mode work — land the fix separately.)

Generation fans out exactly like scaffold/story RED: N read-only subagents each return one test file
body as text; the controller (single writer) applies them. **Each characterization-author subagent's
brief carries the governance bundle** (see [`governance.md`](governance.md); re-read it from
`runs/<RUN_ID>.governance.md`, never from memory) — the
relevant constitution principles, the matching `.github/instructions/*`, and
`security-and-owasp.instructions.md` for any trust-boundary surface being restructured — so the frozen
safety net pins down the governed behavior, not just the happy path. Then the safety net gets a full
`requesting-code-review` pass (re-applying the same governance as the checker) and is **frozen**.

### TRANSFORM — incrementally, and never go red

Apply the refactor in **small reviewable steps**, and after **every** step the whole suite is green.
The keep-green invariant is the entire safety mechanism:

- **A red test mid-transform is a signal, not a chore.** It means the step changed observable
  behavior. Either the step is wrong (fix the step, not the test), or the "refactor" was actually a
  behavior change in disguise (stop and route to story mode). You never green it by editing a
  behavioral/contract test — that is a false green that erases the proof of preservation.
- **Only implementation-coupled unit tests may move with the code.** A test that asserts an internal
  detail you just renamed/extracted (e.g. a private helper's signature) legitimately updates in
  lockstep. That update goes through **maker/checker review** to confirm it is coupling churn, not a
  smuggled behavior edit. Contract, integration, and acceptance tests are **frozen** — they must never
  need to change for a true refactor.

This is SDD's normal per-increment loop with the "test" replaced by the frozen green suite: each step's
contract is *"restructure this slice without turning any test red,"* reviewed stage-1 (is it the
intended structural change?) + stage-2 (quality + governance — the project constitution (hard) and
matching `.github/instructions/*` — plus security on trust-boundary code: moving auth or
access-filter code can silently change enforcement even when tests pass, so re-apply
`security-and-owasp.instructions.md`).

**When invoking `subagent-driven-development`, explicitly carry the governance bundle** (constitution
excerpts + matched `instructions/*` content, re-read from `runs/<RUN_ID>.governance.md`) into
SDD's per-task maker subagent briefs. Subagents have isolated context — they will not see VS Code's
injected instructions unless the brief includes the content. Each per-task maker must satisfy the
constitution + matched instructions *while restructuring*, not just satisfy them at review.

Why incremental rather than one big transform:

- **Localization.** If step 7 turns a test red, you know exactly which structural move broke it. A
  big-bang refactor that ends red gives no such signal.
- **Reviewability.** Coherent per-step diffs (extract this, then rename that) review far better than a
  200-line restructure dump.
- **Reversibility.** A green-between-every-step history means any step can be reverted cleanly.

### CONVERGENCE GATE — converge on one fingerprint + confirm the contract is unchanged

Identical to the universal bracket's convergence: after the last transform step, make **no further
edits**, then run the whole suite plus every required evidence kind (`go-test`, `pg`, `redis`, browser
E2E, …) back-to-back so all captures share one whole-tree fingerprint. Refactor mode adds one
assertion the other modes don't need: **the public contract diff is empty** — no OpenAPI/proto/schema
change, no changed exported signature that callers depend on (unless the caller update is itself part
of the reviewed refactor). Definition of Done: **same behavior, clearer structure** — the suite that
was green at the pin-green gate is still green, untouched.

## What refactor mode changes vs. keeps

| Aspect | Story core | **Refactor core** |
|---|---|---|
| Starting state | RED (author failing tests) | **GREEN (existing suite passes)** |
| Test authoring | RED batch, must fail first | **Characterization tests, must pass first** (only where coverage is thin) |
| Invariant | drive red → green | **stay green every step** |
| Frozen artifact | the RED suite | **the characterization/behavioral suite** |
| Green phase | incremental (flip subsets green) | **incremental (keep subsets green)** |
| TDD | kept, story-scoped | **replaced by keep-green** |
| Security review | RED suite up front + per trust-boundary task | Characterization review + per trust-boundary transform step |
| Evidence | whole story suite on one fingerprint | Whole suite on one fingerprint **+ empty-contract-diff assertion** |
| Preflight / isolation / run-log / hooks / draft-PR | — | **Identical (reused)** |

## When to use / when to refuse

**Use** for: renames, extract-function/extract-class, inline, move-module, dedupe, dependency-injection
cleanup, type tightening, dead-code removal, and structural reorganization — any change whose entire
point is *"same behavior, better shape."*

**Refuse** (→ [story mode](story-mode.md)) the moment the change adds or alters behavior — a new
feature, a changed contract, a new validation/error, or a bugfix (which changes wrong behavior into
right, prefixed with `systematic-debugging`). **Refuse** (→ [scaffold mode](scaffold-mode.md)) when the
work is pure non-behavioral bootstrap of new files. When a task mixes a refactor with a behavior
change, **split it**: land the behavior change as a story, then refactor under keep-green.

## Composition

Refactor mode is still **one branch, one worktree**. Its parallelism is confined to the read-only
characterization-test *generation* phase; the transform, review, and convergence are serial. It is
**not** a substitute for `sso-executing-parallel-tracks` (worktree-per-track): a parallel orchestrator may
dispatch one refactor-mode run per independent refactor track, each holding its own frozen green suite
in its own worktree.
