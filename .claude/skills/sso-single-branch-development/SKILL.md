---
name: sso-single-branch-development
version: 0.5.0
description: 'Run a full end-to-end implementation pipeline on one branch/worktree in one of three execution cores — scaffold (non-behavioral bootstrap batch), story (TDD for new/changed behavior), or refactor (behavior-preserving keep-green) — with two-stage spec-compliance + code-quality verification, evidence capture, optional Copilot hooks, and draft-PR handoff. Use when asked to implement one feature, fix one bug, refactor existing code, or do foundation/scaffold setup with strong quality gates but without multi-track parallel orchestration.'
---

# Single-Branch Development

Run one autonomous branch from implement → review → evidence → draft PR. This skill is a thin
**per-branch bracket** (isolation before, an evidence gate + draft-PR boundary after) around an
**execution core that always runs in one of three modes**: **scaffold mode** for non-behavioral
bootstrap batches, **story mode** for behavioral work that adds or changes behavior (a lone feature or
bugfix is story mode with N=1), or **refactor mode** for behavior-preserving change to existing code
(keep-green, no new behavior). There is no free-form per-task path. It does **not** re-implement the
implement/review loop — story and refactor modes' green phase delegates to `subagent-driven-development`
(SDD), and the draft-PR boundary **replaces** SDD's merge-capable finish. Use it standalone or composed
by an orchestrator.

## When to Use This Skill

- User asks to implement one feature end-to-end on a single branch.
- User asks for foundation/bootstrap work with strict gates before parallel tracks exist.
- You want TDD + verifier + evidence + draft PR without parallel fan-out complexity.
- You need a reusable per-branch worker contract that another skill can compose.
- A bugfix counts — story mode N=1. A refactor counts — refactor mode, keep-green.
- **Not** for reworking PR-review feedback on already-implemented work (no preflight/isolate/
  RED-authoring to run) — that's `sso-pr-review-feedback`.

## Prerequisites

- `git` and `gh` CLI authenticated for PR creation; project test commands known.
- One or more tasks defined. Planning is done upstream: this skill starts post-planning and does
  **not** reopen brainstorming, spec-writing, or task breakdown mid-run — it only *reads* a
  task-scoped SpecKit spec/plan/research/data-model/contracts slice at the governance gate (Step 4).
- Optional: mechanical hooks enabled — Copilot (`.github/hooks/*.json`) **or** Claude Code
  (`.claude/settings.json`). [`scripts/install-hooks.sh`](scripts/install-hooks.sh)` --surface
  {copilot|claude|both}` wires either; see [references/hooks.md](references/hooks.md#running-under-claude-code).

### Step 0 — First-run bootstrap (offer, then install on consent)

Probe with [`scripts/install-hooks.sh --check`](scripts/install-hooks.sh): exit `0` = installed
bundle matches source (skip Step 0 entirely), exit `3` = **missing or drifted** — a repo can
silently run a months-stale bundle, the #1 reason a run executes ungated. On drift: run
`install-hooks.sh` with no args for the **dry-run plan** (writes nothing), **surface it and get
consent** — it touches shared repo config (`.github/hooks/`, `.gitignore`), so never auto-apply —
then `--apply` on yes and have the user review + commit. It is idempotent, never clobbers an
existing base preset, and seeds a stack-aware `track-env.base.sh` with TASK-DERIVED scope/floor left
EMPTY so an unedited copy fails loud. On no, proceed: hooks no-op until their env is set.
See [references/hooks.md](references/hooks.md#install).

## Run Ledger (do this first, keep it current)

This pipeline is long: eight bracket steps around a core that spans many subagent dispatches. **A run
this long gets its context compacted mid-flight**, and compaction is not a new session — no
`SessionStart` fires, so nothing re-runs reconcile and nothing re-injects what was dropped. Anything
held only in the conversation is at risk: which core you picked, whether the RED suite is frozen,
which increment you were on, your governance excerpts. Three habits make the run survive it.

1. **Open a TODO list before Step 1** and keep it updated as you go. One item per pipeline step,
   each naming the artifact that proves it done — it is re-serialized every turn, so it survives a
   compaction that eats the middle of this document:
   ```
   - [ ] 1  Preflight & confirm      → runs/<RUN_ID>.dispatch persisted
   - [ ] 2  Reconcile / resume       → reconcile JSON read; dirty tree stashed
   - [ ] 3  Isolate                  → git worktree list shows > 1 entry
   - [ ] 4a Governance gate          → runs/<RUN_ID>.governance.md written + pinned
   - [ ] 4b Execution core (<mode>)  → per-mode steps from the mode reference
   - [ ] 5  Freeze & verify-all      → all kinds captured at ONE fingerprint
   - [ ] 6  Evidence gate            → real output pasted
   - [ ] 7  Confirm run record       → runs/<RUN_ID>.json reviewed
   - [ ] 8a Discipline audit         → track-audit.sh clean
   - [ ] 8b Draft PR                 → gh pr create --draft printed a URL
   ```
2. **Stamp every step boundary** with
   [`scripts/track-note.sh`](scripts/track-note.sh)` phase <mode> <step>`. **Mandatory**, not the
   optional self-trace: it is the only durable record of *where in the pipeline you are*, and
   `track-audit.sh` fails a run that never stamped one. Evidence freshness cannot supply it — that
   says which test kinds are current, never which core you chose or whether the tests are frozen.
   `track-reconcile.sh` replays it back as `position.phase` with a `resume_action`.
3. **Re-anchor after any compaction**: re-run `track-reconcile.sh`, act on its `resume_action`, and
   re-read `runs/<RUN_ID>.governance.md` before the next dispatch. Rebuilding position by *reading
   the worktree* is the failure Step 2 exists to prevent — that prohibition applies just as much
   after a compaction as after a crash. **This one is now audited, not trusted:** `track-compact.sh`
   records the compaction and the re-read, `track-brief.sh` records what the next brief carried, and
   `track-audit.sh`'s `I4` fails a run that dispatched a subagent after a compaction without
   re-reading the bundle in between — **or** that re-read it and then sent an empty brief anyway.

## Pipeline (One Branch)

Steps 1–3 (before) and 5–8 (after) are the **universal bracket** — identical no matter which mode
runs: preflight, reconcile, isolation, and the evidence-gate + draft-PR boundary are reused unchanged
by every core. Step 4 is the **execution core**: always scaffold, story, or refactor mode, never a
free-form per-task loop. See the [skill-per-step map](#skill-per-step-map) for which superpower skill
owns each step **and whether that step runs in-session or dispatches subagents** (🧩 skill vs 🤖
subagent vs ⚙️ script).

> **Cite gates by NAME, never by number.** This body numbers 1–8; each mode reference numbers its own
> core 0–6. The two schemes do not line up, so "Step 5" is ambiguous across documents and a
> cross-document number is how a step gets skipped. The named gates are: **governance gate** ·
> **mode guard** · **RED/pin-green gate** · **review gate** · **convergence gate** (freeze &
> verify-all) · **evidence gate** · **draft-PR boundary**.

1. **Preflight & confirm** — run [`scripts/track-preflight.sh`](scripts/track-preflight.sh)
   (`inspect` mode) before touching the repo. Supply only the **track slug** (`TRACK_ID=a`); the
   script settles identity off one durable fact — whether a `runs/*.dispatch` breadcrumb for this
   `TRACK_ID` exists. No breadcrumb → **START**: mint `RUN_ID` = `<UTC-timestamp>_<track>`, check
   prerequisites, and on approval persist `runs/<RUN_ID>.dispatch`. Breadcrumb exists → **RESUME**
   that run automatically (there is no `--resume` flag). It prints a one-screen summary (Mode · Track
   · Tasks · RUN_ID · Branch · Base ref · Prereqs) and the same as JSON. Then, in order:
   - **Confirm (mandatory).** Present the emitted summary **verbatim** for approval — never re-type it
     into a hand-built table, which can drift silently from what `--persist` stamps into the breadcrumb
     (the script's own output is the single source of truth). **STOP and get explicit human approval of
     this summary before Step 3 creates anything**, then re-run with `--persist` to persist.
   - **Waiver (orchestrator-dispatched worker only).** The one exception is `--yes` (or
     `AUTO_CONFIRM=1`), for a worker **dispatched by an orchestrator** whose human gate was already
     taken upstream at the wave plan — never self-granted just because no human answered. It is recorded
     (`auto_confirm:true` / `confirmed_by:"orchestrator-waiver"` in both the JSON and the breadcrumb) so
     an audit can tell an approved run from a waived one, and it waives **only** the confirm — a
     prerequisite failure still hard-fails under `--yes`.
   - **Derive task-shaped config first** — the values whose correct setting depends on *this* task, not
     repo-wide policy: `TRACK_ALLOWED_PREFIXES` (+ any `TRACK_FROZEN_PATHS`),
     `PREFLIGHT_REQUIRE_TOOLCHAIN` (so a missing bin fails here, not mid-run), and
     `TRACK_REQUIRED_EVIDENCE` (the evidence *floor*). Confirm them in the same proceed-confirm;
     `--persist` stamps them into the breadcrumb as a faithful record of what was approved. **Never
     hand-widen scope mid-run.** Repo-wide catalog/policy (`TRACK_EVIDENCE_KINDS`/`RULES`, sentinel,
     ceilings, `RUNS_DIR`) stays in the committed `track-env.base.sh` — never regenerate it per run.
     Preflight also checks the optional dependency lock: a committed `skill-deps.json` beside the hooks
     makes it probe each declared tool and fail hard on a required lock violation (warn on a non-strict
     out-of-range version), the result cached `TRACK_DEPS_CACHE_TTL_HOURS` hours (default 72) in
     `runs/.deps-cache.json`. See [references/hooks.md](references/hooks.md) for `RUN_ID` mechanics.
2. **Reconcile / resume** — run [`scripts/track-reconcile.sh`](scripts/track-reconcile.sh) to rebuild
   position from **persisted state only** (committed history + `runs/<run-id>.json`), never the
   model's reading of the worktree. It marks each evidence kind `fresh|stale|missing|failed` at the
   current fingerprint, and replays the durable **position** — the last `phase`, any terminal
   `status`, and the governance bundle's path + whether it still exists — as a one-line
   `resume_action`. **Act on `resume_action` first**: a non-`success` status means re-plan, never
   resume silently. Then stash any `dirty_worktree` (untrusted, reversible — never `reset --hard`),
   skip every `fresh` kind, and resume at the first `missing`/`stale`/`failed` task. Doneness is
   mechanical (fingerprint match), never a judgement call. **Run this after any compaction too**, not
   just at session start — see the [Run Ledger](#run-ledger-do-this-first-keep-it-current). No-op on a
   clean, complete tree; run by hand it does not hang (it skips the stdin read on a TTY).
3. **Isolate** — run `using-git-worktrees` to place the work in an **isolated worktree**, using the
   **Branch** name from preflight's summary (`TRACK_BRANCH` if set, else the track slug). **A
   dedicated worktree is the default and expected form of isolation** — the point is that a failed or
   abandoned run's files live in a *separate directory you can delete wholesale*, never in your
   primary checkout. Follow `using-git-worktrees` exactly: detect existing isolation first (if `git
   rev-parse --git-dir` ≠ `--git-common-dir` and you are not in a submodule, you are already in a
   linked worktree — reuse it), then prefer a native worktree tool, then fall back to `git worktree
   add`. **A bare branch in the primary checkout is NOT sufficient isolation** and is permitted *only*
   when `using-git-worktrees` routes there (user declined consent, or no worktree mechanism exists) —
   and then only after you surface that limitation and get explicit acknowledgement. Never silently
   downgrade worktree → branch-in-place, and never start on main.
4. **Run the execution core — pick the mode with the guard** (full comparison:
   **[The Three Execution Cores](#the-three-execution-cores)**). Work that **adds or changes**
   behavior — a test obligation, a trust boundary, or a correctness/security criterion → **story
   mode**. Behavior-**preserving** change to existing behavioral code (rename/extract/restructure, no
   contract change) → **refactor mode**. Pure non-behavioral bootstrap → **scaffold mode**. Story and
   refactor modes delegate their green phase to `subagent-driven-development`; this skill never re-runs
   SDD, it only closes SDD's two gaps: (a) SDD's test-first is opt-in, so story mode supplies the
   failing tests up front via the RED batch (refactor mode instead pins the existing suite green up
   front); (b) SDD's stage-2 review is quality-only, so every review also applies the standing
   **governance** — the project constitution (`.specify/memory/constitution.md`, if present) and the
   `.github/instructions/*` whose `applyTo` globs match the changed files — and any trust-boundary
   change additionally applies `security-and-owasp.instructions.md`. The review rubric
   (`code-review-generic.instructions.md`, no `applyTo`) is loaded at the review step and embedded in
   the reviewer brief, not at core entry.

   **Governance gate — mandatory, once at core entry, before the mode guard and before any code
   is written or subagent dispatched.** Read [`references/governance.md`](references/governance.md)
   and follow it: discover (constitution · every `applyTo`-matching `.github/instructions/*`, matched
   by listing the directory rather than from a remembered list · design artefacts for frontend
   surfaces · `security-and-owasp` on any trust boundary · the task's scoped SpecKit spec/plan/
   research/data-model/contracts slice, when present), **distil to binding constraints**, **persist
   to `runs/<RUN_ID>.governance.md`**, then pin it with `track-note.sh governance <path>`.

   Three rules the reference expands and this body will not restate:
   - **Persist it, don't just hold it.** The bundle lives in a file because this core spans many
     dispatches and the session *will* be compacted — and raw pasted file content is the first thing
     compaction drops. A model that "already read the instructions" but no longer holds them briefs
     subagents with filenames, which is the defect below.
   - **Content, not filenames, into every brief** — `dispatching-parallel-agents` fan-out makers and
     `subagent-driven-development` per-task makers/reviewers alike. A brief naming
     `go.instructions.md` gives an isolated-context subagent nothing to act on. **This is now
     audited, not trusted:** `track-brief.sh` reads each outgoing brief at dispatch time and
     `track-audit.sh`'s `G6` **fails** a dispatch whose brief carried none of the bundle's
     constraints. A dispatch that genuinely needs none (read-only research) declares it in the
     brief: `GOVERNANCE: n/a — <why>`.
   - **Widened the surface mid-core? Re-distil and re-pin.** Calling `track-note.sh governance`
     again is the sanctioned move — the stamp history is append-only, so `G3` asks whether every
     dispatch had a pin before it rather than penalizing the second pin. Editing the bundle without
     re-pinning is what WARNs.
   - **Governance is a *maker* obligation, not just a checker backstop.** Both ends is deliberate
     defense-in-depth: the brief prevents the violation, the review catches the remainder.
     **No-ops only when the files genuinely don't exist**, never by omission.

   *Annotations via [`scripts/track-note.sh`](scripts/track-note.sh) — all self-reported
   (`self_reported:true`), never hook-observed:* `phase <mode> <step>` at every core-step boundary and
   `governance <path>` once the bundle is persisted are **mandatory** — they are the resume anchor.
   `skill <name>` and `loop <phase>` (the `skills[]`/`iterations` trace) stay optional. The
   **mechanical** fields (`tool_calls`, `trace[]`, heartbeat) record automatically — preflight
   `--persist` persists `RUN_ID` into the installed `track-env.sh`, so even a solo run populates the
   record with no extra setup. See [references/hooks.md](references/hooks.md).
5. **Freeze & verify-all** (the **convergence gate**) — once the last task's review passes, make **no further edits**, then run
   every required evidence kind (`go-test`, `pg`, `redis`, …) back-to-back so all captures share the
   **same** fingerprint. Any change after this — including a review-driven fix — invalidates the
   convergence and requires re-running all kinds.
6. **Evidence gate** (`verification-before-completion`) — paste real command output; "all green"
   without pasted output is not done.
7. **Confirm the run record** — `runs/<RUN_ID>.json` carries hook-observed fields (`tool_calls`,
   `trace[]`, `evidence[]`, heartbeat) plus whatever `track-note.sh` asserted (`phase`,
   `governance_bundle`, `skills[]`, `iterations`, `status`). Never conflate the two: the self-reported
   ones are provenance-tagged for exactly that reason.
8. **Draft-PR finish** (only from `success` — see [Terminal States](#terminal-states-name-them-dont-dress-them-up))
   — open a **draft** PR and stop. This **replaces** SDD's call to
   `finishing-a-development-branch`; the worker never reaches its merge menu. Integration/merge is
   owned by repo process/CI. **Build the PR body from [`templates/pr-body.md`](templates/pr-body.md):**
   generate its **Auto** block with [`scripts/track-report.sh`](scripts/track-report.sh) (files changed +
   size from the diff, evidence with fingerprints + pass/fail, `tool_calls` / `trace[]`, and any
   self-reported `skills[]` / `iterations` — all rendered from `runs/<RUN_ID>.json` + the breadcrumb,
   never re-typed), then author only the **Asserted** zone (compliance narrative, caveats, "after merge").
   Keep the two zones visibly separate so a reviewer can tell a hook-verified fact from a model claim.
   The Auto block ends with a **Compliance warnings** section: if `track-report.sh` flags a *missing
   `requesting-code-review` activation* or an *empty evidence pack*, that gap is real — resolve it (run
   the core's **review gate** / capture the evidence) or explicitly acknowledge the waiver in the
   Asserted zone.
   **Run [`scripts/track-audit.sh`](scripts/track-audit.sh) before `gh pr create`** — it re-derives
   the pipeline's discipline invariants from durable artifacts (was governance pinned and does it
   cover the diff's matched instructions; was it stamped *before* the first subagent; did the phases
   advance; did the RED suite actually run red; did the lanes converge on one fingerprint; was a test
   weakened). Any ✗ blocks: fix it or the PR is a claim you can't back. **`track-report.sh` embeds
   the audit verdicts into the Auto block automatically** — each finding with the remediation that
   clears it, and a collapsed list of what it deliberately did *not* check — so the reviewer sees the
   same evidence you did instead of taking "I followed the pipeline" on trust. The unchecked
   remainder is yours to audit against
   [`tests/prompt-level-checklist.md`](tests/prompt-level-checklist.md).
   **Label the PR `agent-generated`** (`gh pr create --draft … --label agent-generated`): CI asserts
   the Auto block is present, internally consistent, and declares no blocking failure. Skipping the
   whole bundle produces no Auto block at all, and only a check *outside* the agent can see that
   absence — a reporter cannot report on its own absence. The label is **not** what makes the gate
   fire: `agent-pr-audit.yml` also detects the harness-written `Co-Authored-By` trailer on your
   commits, so omitting the label does not opt you out. It only makes the scope explicit.
   **Keep the template's footer** (`🌱 Powered by Supspec Orchestration 🤖`) as the last line of the
   body — it is the one fixed section that is not part of the "delete what doesn't apply" menu.
   **Never open a draft PR with an unaddressed ⚠️.** Once the PR is open, run `track-preflight.sh --complete` to stamp
   `completed_utc` + `duration_secs` (now − `created_utc`) onto the breadcrumb — write-once, the one
   deliberate boundary that knows the run's total wall-clock (a per-event hook never sees PR handoff).

## Terminal States (name them, don't dress them up)

A run that cannot finish is **not** a success, and "I'll just open the PR and mention the caveat" is
the failure this prevents. Every run ends in exactly one of four states — the same four an
orchestrator routes on, so a solo run and a fleet worker report identically:

| State | Means | Who writes it |
|---|---|---|
| `success` | Every gate passed, evidence pasted, draft PR opened | you, at Step 8 |
| `blocked` | A failure survived `TRACK_SELF_HEAL_ATTEMPTS` (default 2) retries | you — `track-note.sh status blocked …` |
| `no-progress` | Tool-call ceiling tripped | ⚙️ `track-meter.sh` |
| `budget-exceeded` | Token-estimate ceiling tripped | ⚙️ `track-tokens.sh` |

**Only `success` opens a PR.** On any other state: stop editing, then

```bash
bash .github/hooks/track-note.sh status blocked "<root cause, one line>" "<next step to try>"
```

and report the state, the blocker, and what you tried. `blocker`/`next_step` land in
`runs/<RUN_ID>.json`, so the run is resumable by someone who wasn't there — and `track-reconcile.sh`
refuses to resume it silently, telling the next session to re-plan instead.

**Retry only *task* failures** (tests fail, build breaks, lint errors). An **infra** failure
(registry timeout, image pull, worktree lock, OOM) is a bounded retry-with-backoff, not a self-heal
attempt — don't burn the budget re-reasoning about a network blip. A **divergence** failure (green
but wrong: out-of-scope edit, deleted file) is never fixed by retrying; that is what the guard, the
distinct reviewer, and `track-audit.sh` exist to catch.

## Skill-Per-Step Map

**The `Kind` column tags every row so you always know whether a *skill* runs in your own session or a
*subagent* is dispatched:**

- 🧩 **skill** — a superpower `SKILL.md` the **current** agent reads and follows **in-session**: no new
  agent, no isolated context, your session's history stays intact.
- 🤖 **subagent** — a **dispatched** agent with **isolated context + a hand-constructed brief**. Not a
  named catalog entry you trigger: subagents are runtime workers, always spawned **by** one of the two
  dispatcher skills (`dispatching-parallel-agents`, `subagent-driven-development`), always cast as
  **maker** or **reviewer**. "🧩 skill → 🤖 subagents" means you invoke the named skill and *it* fans out.
- ⚙️ **script** — a bundled hook/CLI: mechanical, deterministic, no LLM.

"Governance" below means the full bundle from [`references/governance.md`](references/governance.md):
constitution (hard gate) + every `applyTo`-matching `.github/instructions/*` + `security-and-owasp`
on trust boundaries + the task's scoped SpecKit artifact slice (when present), embedded as
**content**. The review rubric (`code-review-generic`) is not in the bundle — the review step loads
it separately.

| Step | Fires | Kind |
|------|-------|------|
| 1 Preflight | `track-preflight.sh` | ⚙️ script |
| 2 Reconcile | `track-reconcile.sh` | ⚙️ script |
| 3 Isolate | `using-git-worktrees` | 🧩 skill |
| 4 **Governance gate** (all modes, before the mode guard) | read (rules + task's spec/plan/research/data-model/contracts slice) → distil → `runs/<RUN_ID>.governance.md` → `track-note.sh governance` | 🧩 in-session + ⚙️ script |
| 4 Core — **story** RED author | `dispatching-parallel-agents` → **N× maker** (+ governance) | 🧩 skill → 🤖 subagents |
| 4 Core — **story** RED review + freeze | `requesting-code-review` (+ governance, + `security-and-owasp`) | 🧩 skill |
| 4 Core — **story** incremental green | `subagent-driven-development` → per-task **maker** + **reviewer** (+ governance) | 🧩 skill → 🤖 subagents |
| 4 Core — **refactor** pin-green + characterize | `dispatching-parallel-agents` → **N× maker** (+ governance) then `requesting-code-review` | 🧩 skill → 🤖 subagents |
| 4 Core — **refactor** incremental transform (keep green) | `subagent-driven-development` → **maker** + **reviewer** (+ governance) | 🧩 skill → 🤖 subagents |
| 4 Core — **scaffold** generate | `dispatching-parallel-agents` → **N× maker** (+ governance) | 🧩 skill → 🤖 subagents |
| 4 Core — **scaffold** review | `requesting-code-review` (+ governance; **no** security add-on — the guard cleared trust boundaries) | 🧩 skill |
| 5–6 Converge & gate | `verification-before-completion` | 🧩 skill |
| 8 Discipline audit (before the PR) | `track-audit.sh` — re-derives the pipeline invariants from artifacts | ⚙️ script |
| 8 Finish | draft PR — **overrides** `finishing-a-development-branch` | 🧩 skill (overridden) |

## Quality Gates (Owned Here)

Invariants this skill asserts; most are *realized by* SDD's loop, not re-run here.

- **TDD required** for behavioral changes — realized at story scope: story mode authors the failing
  RED suite before any implementation (N=1 for a lone task). It's a prompt-level invariant (hooks
  can't see test-first ordering), backstopped by the RED gate (tests must fail first) and the evidence
  gate (they must end green). Scaffold mode is the sole exemption — its guard proved nothing is
  behavioral.
- **Behavior-preserving work is keep-green, not red-first**: refactor mode is the third core — it
  never authors a failing RED suite. It pins the existing suite green up front (adding characterization
  tests that must pass *immediately* where coverage of the touched surface is thin), then holds it
  green through every transform step. A red test mid-refactor signals a behavior change and must route
  to story mode; greening it by editing a behavioral/contract test is a false green.
- **Governance gate — hard, in every mode (incl. scaffold)**: every review applies the repo's standing
  governance (now including feature/task context — governance.md item 6) on top of the quality
  rubric — the **project constitution** as a *hard* gate (a diff violating a stated principle fails
  review in every mode), plus every `applyTo`-matching `.github/instructions/*`, applied to the diff
  even when the reviewer didn't author the file. The baseline rubric comes from
  `code-review-generic.instructions.md`, loaded at this step rather than carried in the bundle (see
  below). The **same governance set is pushed upstream into every maker brief**, so governance gates
  both ends and review is the backstop, not the first consultation. **No-ops only when those files
  genuinely don't exist**, never by omission — and `track-audit.sh` fails a run whose bundle omits an
  `applyTo`-matched file. Procedure: [`references/governance.md`](references/governance.md).
- **Security review required** at stage 2 for trust-boundary changes: the `requesting-code-review`
  rubric is quality-only, so the reviewer must also apply `security-and-owasp.instructions.md`.
- **The reviewer gets the rubric as content.** At the review step, read
  `code-review-generic.instructions.md` and embed the relevant parts in the reviewer brief alongside
  the governance bundle. It carries no `applyTo` — nothing auto-injects it, on either surface.
- **Maker/checker required**: the stage-1/stage-2 reviewer must be a subagent distinct from the
  implementer (SDD's two-stage review).
- **Resume from durable state, not memory**: an interrupted run reconciles from committed history +
  the fingerprint-matched run record; uncommitted changes at startup are stashed, not built upon. The
  `RUN_ID` is durable too — minted once, persisted to a breadcrumb, recovered automatically on resume.
- **Evidence, not assertion**: completion requires command output. The fingerprint is whole-tree, so
  every required kind must pass against **one common final tree** (Step 5 converges the lanes).
- **Self-heal cap**: SDD loops "until approved" unbounded; this skill caps retries at
  `TRACK_SELF_HEAL_ATTEMPTS` (default 2, in `track-env.base.sh`) per distinct failure, then halts
  `blocked` rather than thrashing. Prompt-enforced — no hook counts review rounds — but the number
  lives in the preset so it survives a compaction instead of only in the model's head.
- **Position is durable, not remembered**: every step boundary is stamped with `track-note.sh phase`,
  and the governance bundle is persisted to a file. A compacted or crashed session re-anchors from
  `track-reconcile.sh`, never from re-reading the worktree.
- **Discipline is audited from artifacts, not asserted**: `track-audit.sh` re-derives what actually
  happened (governance ordering + coverage, phase advance, real RED, convergence, test weakening)
  and prints what it *cannot* check rather than implying a clean bill of health. Necessary, never
  sufficient.

## Gotchas

- **Resume keys on the *track slug*, not a remembered id.** Reuse the exact same slug — "track `a`"
  then "track `auth`" reads as two different tracks and starts fresh. To force a clean restart, delete
  that track's `runs/*_<track>.*` files. There is no `--resume` flag. Relatedly, **never hand-set
  `RUN_ID`**: it is minted once by `track-preflight.sh` and must stay stable across restarts so
  `track-reconcile.sh` reopens the same record.
- **A dirty worktree at startup is untrusted.** Reconcile stashes it (reversible) — never `git reset
  --hard` unfamiliar work and never build on it.
- **Isolation means a *worktree*, not just a branch.** An abandoned run's files must sit in a separate
  directory you can delete wholesale; a branch in the **primary** checkout pollutes your main tree and
  needs hand-cleaning (`git clean`). Branch-in-place is allowed **only** when `using-git-worktrees`
  routes there, and only after that is surfaced and acknowledged — never because it "feels lighter."
  Verify with `git worktree list`: more than the primary entry means you isolated; a single entry
  means you did **not**.
- **Doneness is mechanical.** A task is done only when its evidence `fingerprint` matches the current
  tree. "All green" without pasted output is not done.
- **Two config mistakes make the gates silently pass.** (a) No `TRACK_BASE_REF`: the gate derives
  "what changed" from the diff, so once work is *committed* the diff-vs-HEAD is empty, nothing is
  required, and it passes. (b) `runs/` not gitignored: the fingerprint hashes untracked non-ignored
  files, so evidence writes shift the fingerprint and the gate self-stales. Set both before the first
  run. Every other env/hook mechanic — the two-layer preset, solo-run self-activation, per-track
  `RUN_ID` in a fleet, bash+`jq` only, the guard's worktree-root resolution — is in
  [references/hooks.md](references/hooks.md#install), which is the single source for them.
- **Don't freeze entrypoints on a bootstrap branch.** Leave `TRACK_FROZEN_PATHS` unset until parallel
  tracks begin and the entrypoints exist.
- **The worker physically stops at `gh pr create --draft`.** Push/merge/force are denied by the guard.
- **`[P]` is *not* the scaffold trigger.** `[P]` marks file-disjointness, not non-behavioral-ness — it
  sits on security-critical tasks too. Scaffold mode keys on an explicit `scaffold_only` batch + the
  guard; any test obligation or trust boundary refuses the whole batch to story mode.
- **Two scaffold traps, both silent.** (a) The controller **applies** file bodies, it never *authors*
  them — writing them yourself because they're "just trivial config" collapses maker and applier and
  **skips the fan-out entirely**; a converged tree you wrote yourself is a violation even though it
  looks identical. (b) Generate only the **task-declared surface, no speculative structure** — a task naming
  `backend-go/{cmd/api,kernel,…}` does not license pre-building every future `internal/<domain>/…`,
  and the tell-tale is one `.gitkeep` per anticipated leaf flooding a bootstrap PR. Both in full in
  [`references/scaffold-mode.md`](references/scaffold-mode.md) — read it **before** executing the
  core; this body is a summary, the mode reference is the binding spec.
- **Report state from command output, not intent.** Never announce a commit, push, or PR "exists"
  until its creating command *returned successfully* — read the URL from **its** output. Saying
  "draft PR opened" after a bare `git push` is exactly the `verification-before-completion` failure
  this pipeline prevents: the artifact you claimed may not exist.
- **Never green a frozen test by weakening it (story) or editing behavior (refactor).** A deleted
  assertion, loosened matcher, `skip`-ped case, or a contract test rewritten to pass is a false green
  in every mode — `track-audit.sh` flags both signatures in the diff. A genuinely wrong test routes
  back through its review gate. (Full rules in the story/refactor sections.)
- **Governance AND feature-context discovery are a main-session in-context read — not a subagent
  task, not a filename reference, not a whole-document paste.** A subagent read loses it at the
  process boundary; a filename without content ("follow `go.instructions.md`", "implement per
  `spec.md`") gives the subagent nothing to act on. Pass **content**, scoped to this run's task
  IDs/user-story tags for feature context. VS Code's `applyTo` injection reaches the main session
  only and never propagates into dispatched subagents. Full procedure:
  [`references/governance.md`](references/governance.md) item 6.
- **A long run *will* be compacted, and compaction fires no hook.** It is not a new session, so
  `SessionStart`/`track-reconcile.sh` does not re-run and nothing re-injects what was dropped —
  first to go is bulk pasted content, i.e. your governance excerpts. The model keeps believing it
  complied. Defend with the three [Run Ledger](#run-ledger-do-this-first-keep-it-current) habits: a
  live TODO list, a `track-note.sh phase` stamp at every boundary, and a persisted governance bundle
  you re-read after any compaction. Never rebuild position by reading the worktree.
- **A green evidence gate is not proof the suite passed.** `track-evidence.sh` records the tool's
  **text** response, not an exit code, so the gate asserts a fingerprint match plus the absence of a
  failure marker in a possibly-truncated string — which a truncated pass-looking response satisfies
  trivially. `track-audit.sh` warns on suspiciously short passing captures, but read the output
  yourself; CI stays the authority.

## Hooks (Optional, Composable) — Bundle Owned Here

The quality gates are only as strong as the worker's compliance — unless they are enforced. This
skill ships the canonical bundle ([`scripts/track-*.sh`](scripts/) + a wiring manifest per surface:
[`templates/track-hooks.json`](templates/track-hooks.json) for Copilot,
[`templates/claude-settings.json`](templates/claude-settings.json) for Claude Code) — denying
out-of-scope edits, locking workers out of push/merge, recording test evidence, and blocking
completion on an incomplete evidence pack. Surface-agnostic; each script no-ops until its env is
set, so dropping the bundle in is safe.

**Three tiers, not two.** *Live* hooks catch mechanical properties as they happen (a path, a
forbidden command, a counter). `track-audit.sh` then re-derives the **discipline** invariants
after the fact from durable artifacts — governance ordering and coverage, phase advance, real RED,
convergence, test weakening — none of which a per-event hook can see. What survives both is genuine
judgement (did the reviewer *reason*, did the brief carry real constraints); the audit prints those
as its NOT-CHECKED list instead of pretending, and they belong to
[`tests/prompt-level-checklist.md`](tests/prompt-level-checklist.md).

**Still defense-in-depth, not the final gate.** Layer them: hooks → audit → `pre-push` → **CI**.

See [`references/hooks.md`](references/hooks.md) for the full bundle: every script and its event, the
install/env reference, portability notes, and what `runs/<RUN_ID>.json` does and doesn't capture.

## The Three Execution Cores

Step 4 always runs exactly one. Pick with the guard, then **read that mode's reference before
executing** — these summaries are orientation; the reference is the binding spec.

| | **Scaffold** | **Story** | **Refactor** |
|---|---|---|---|
| **Use when** | pure non-behavioral bootstrap: skeletons, manifests, lint/compose/`Makefile` configs, CI wiring | work that **adds or changes** behavior — a feature, or a bugfix at N=1 | behavior-**preserving** change to existing code: rename, extract, inline, move, retype |
| **Guard refuses to** | story mode, on *any* test obligation / trust boundary / correctness criterion (all-or-nothing, per batch) | — (this is the default for behavioral work) | story mode if behavior or contract changes; scaffold if it's new bootstrap |
| **Starting test state** | none | **RED** — a new failing suite | **GREEN** — the existing suite already passes |
| **Core** | fan out read-only generators (one per disjoint-file cluster, never sharing a file) → controller **applies** as sole writer → review → verify | author the RED batch → **review + freeze** it → green **incrementally** in dependency order | pin green + **characterize** thin coverage (must pass immediately) → review + freeze → transform in small steps |
| **Invariant** | it builds and comes up | drive red → green, never by weakening a test | **stay green after every step**; a red test means behavior changed → route to story |
| **Review** | one whole-diff pass (+ governance; no security add-on — the guard cleared trust boundaries) | RED review + per-increment two-stage (+ security) | characterization review + per-step (+ security on trust boundaries) |
| **Reference** | [`scaffold-mode.md`](references/scaffold-mode.md) | [`story-mode.md`](references/story-mode.md) | [`refactor-mode.md`](references/refactor-mode.md) |

Story and refactor delegate their green/transform phase to `subagent-driven-development`; scaffold
has no per-task loop at all. **A bugfix is story mode at N=1**, prefixed with `systematic-debugging`:
reproduce and root-cause *first*, encode the diagnosis as the failing regression test (that is the
RED batch), then green the cause. **A refactor that also changes behavior is two pieces of work** —
land the behavior change as a story, then refactor under keep-green; mixed, neither suite can prove
which half is correct.

## Composition Contract

When composed by a parallel orchestrator, this skill's gates may be **tightened** by overlays (distinct
adversarial verifier subagent, draft-only/no-merge boundary, stricter run-id/trace requirements) — and
exactly one may be **waived**: the Step-1 interactive confirm, via `--yes`, because the orchestrator
already took that human gate at its wave plan. Nothing else is waivable by an orchestrator.

## References

- **Story/refactor green delegates the per-task implement → two-stage review loop to**
  `subagent-driven-development`, which **transitively** uses `test-driven-development` and
  `requesting-code-review`. Do **not** list those as separate steps — they nest inside SDD, which
  nests inside the core. **Brackets every core with** `using-git-worktrees` (isolation, before) and
  `verification-before-completion` (evidence gate, after). **Overrides** SDD's terminal
  `finishing-a-development-branch`: this skill stops at a **draft PR**; merge is owned by repo/CI.
- [`references/governance.md`](references/governance.md) — the governance gate: discovery procedure,
  bundle format, persistence, context budget, and post-compaction re-anchor.
- [`tests/prompt-level-checklist.md`](tests/prompt-level-checklist.md) — the judgement invariants
  `track-audit.sh` deliberately leaves unchecked, and how to audit them by hand.
- [`references/hooks.md`](references/hooks.md) — full hooks bundle: every script + event, install/env
  reference, portability notes, and what the run record does and doesn't capture.
- [`references/scaffold-mode.md`](references/scaffold-mode.md) — non-behavioral bootstrap core: the
  eligibility guard, generate→apply→review→verify→PR flow, drop-vs-keep table.
- [`references/story-mode.md`](references/story-mode.md) — story-scoped phased-TDD core: RED batch →
  freeze → incremental green, and the incremental-vs-big-bang rationale.
- [`references/refactor-mode.md`](references/refactor-mode.md) — behavior-preserving keep-green core:
  the guard, the characterization safety-net, and the never-go-red transform rule.
- Related orchestrator: `../sso-executing-parallel-tracks/SKILL.md` (dispatches one run of this skill
  per track and layers parallel-only overlays).
