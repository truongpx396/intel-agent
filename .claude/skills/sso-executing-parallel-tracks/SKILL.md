---
name: sso-executing-parallel-tracks
version: 0.2.0
description: 'Orchestrate multiple independent implementation tracks in parallel, each in its own
git worktree, fully autonomously from implement through review, verification, and pull request.
Use when asked to "run tracks in parallel", "execute track 1, 2, 3", "spawn parallel agents",
"fan out user stories", or to run several isolated work-streams concurrently with TDD, evidence
gates, and merge-queue integration. Reads a per-repo Parallel Tracks Orchestrator Manifest for project specifics and
composes the using-git-worktrees, dispatching-parallel-agents, and
sso-single-branch-development skills with strict parallel-only overlays.'
---

# Executing Parallel Tracks

Portable orchestration for running N independent implementation tracks concurrently. This skill is
the **conductor**: it owns isolation, gates, traceability, and integration sequencing, and delegates
the per-track implement/review/verify work to `sso-single-branch-development`. All project-specific facts
(which tasks belong to which track, file ownership, build commands, concurrency cap) live in a
per-repo Parallel Tracks Orchestrator Manifest at `.github/tracks/manifest.md` — never hardcode them here.

**Core mental model:** a **fan-out → isolate → verify → PR → observe** pipeline. *You are the
ceiling.* Parallelism is cheap; your review bandwidth and your ability to trace a failure is the
bottleneck. So the whole design exists to make each parallel worker **independently traceable**
(one run-id across branch, PR, commit trailer, and run record) and **independently revertible** (one
worktree, one branch, one draft PR).

**This skill is the asset; the orchestrator is a runtime role.** Any session can play orchestrator by
invoking this skill — the durable logic lives here, the live state (which worktrees are running,
budget remaining, run registry) lives in the session executing it.

## When to Use This Skill

- User says "execute track 1, track 2, track 3" / "run these tracks in parallel" / "fan out the stories".
- Several work-streams are mutually independent (disjoint files, non-overlapping migrations) and can progress at once.
- You want each track to run autonomously: implement → review → verify → open PR, with no human between tasks.
- A repo has a Parallel Tracks Orchestrator Manifest at `.github/tracks/manifest.md` (or an equivalent dispatch/tasks document) defining the tracks.

Do **not** use this for tightly-coupled tasks that share mutable files — run those serially with
`sso-single-branch-development` instead.

## Prerequisites

- `git` with worktree support; a remote configured for PRs (`gh` CLI authenticated for `gh pr create`).
- Docker available if tracks run integration suites (Testcontainers).
- A repo Parallel Tracks Orchestrator Manifest resolved (see [Manifest contract](#manifest-contract)). If absent, generate one from the repo's tasks/dispatch doc and confirm with the user before proceeding.
- These skills installed and composable: `using-git-worktrees`, `dispatching-parallel-agents`, `sso-single-branch-development`.
- *(Optional but recommended)* `jq` available and Copilot [agent hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) enabled, to make the gates mechanical rather than prompt-trusted (see [Deterministic enforcement via Copilot agent hooks](#deterministic-enforcement-via-copilot-agent-hooks)). Hooks may be disabled by enterprise policy — fall back to prompt-enforced gates if so.

## Autonomy boundary (read first)

Autonomous up to and including **opening a DRAFT PR**. The worker's job ends at `gh pr create
--draft`; **CI is the mechanical gate** (evidence, not claims). Merging is NOT the worker's job —
climb the [maturity ladder](#maturity-ladder-dont-start-at-the-top) deliberately. A green draft PR
proves a track in isolation; only the post-merge tree proves the default branch, so force-merging
PRs back-to-back is exactly the "never-tested main" failure this skill avoids.

Three gates are mandatory:
1. **Precheck gate** — validate before spawning; ask the human back ONLY if a check fails.
2. **Verifier gate (maker/checker split)** — a DISTINCT adversarial subagent verifies; a failed verifier writes a run record and does NOT open a PR.
3. **Merge gate** — workers stop at "draft PR + evidence + rebased if bounced"; CI gates it; a human or merge queue merges per the maturity rung.

Where a gate is a *mechanical* property (a path, a forbidden command, a counter), enforce it with a [Copilot agent hook](#deterministic-enforcement-via-copilot-agent-hooks) so the worker physically cannot cross it — don't rely on the model obeying a prompt.

## Manifest contract

The skill reads a **Parallel Tracks Orchestrator Manifest** at `.github/tracks/manifest.md`
providing project-wide orchestrator defaults — nothing specific to any individual track:

- **Orchestrator Defaults**: `default_branch`, `worktree_root`, `docker_namespace_pattern`,
  `max_concurrent_tracks`, `runs_dir`, `notify_webhook`.
- **Commands**: lint, unit test, integration test, e2e, dep-lock regen (e.g. `go mod tidy`, `uv lock`).
- **Evidence pack**: `kind:pattern` pairs + `glob:kind` path→kind selector for diff-conditional gates.
- **Frozen entrypoints**: files no track may edit without self-registration.
- **Ownership map**: shared files and who may touch them.
- **Invariants**: project release-blockers to assert in review.
- **Hook environment**: env-var derivation table for all hooks.

Per-track details (branch, worktree path, task IDs, owned paths) live in the **wave dispatch file**
generated at Step 0, not in this manifest. Mechanical ceilings (`TRACK_MAX_TOOL_CALLS`,
`TRACK_MAX_TOKEN_ESTIMATE`, `TRACK_SELF_HEAL_ATTEMPTS`) live in
`.github/hooks/track-env.base.sh` — not here. If a needed field is missing, ask the user once for
that specific value; do not guess.

## Orchestrator ledger (do this first, keep it current)

An orchestrator session outlives every worker it spawns — it is the **longest-running context in the
system**, and it *will* be compacted. Compaction is not a new session: no `SessionStart` fires, no
hook re-runs, nothing re-injects what was dropped. What you lose is precisely what makes you the
orchestrator — which tracks are in flight, which already reported, what the wave plan was, and which
budget you were tracking against.

Two habits, both cheap:

1. **Open a TODO list before the precheck**, one item per wave step plus **one per track**, each
   naming the artifact that proves it done:
   ```
   - [ ] 0 Wave plan confirmed by user      → wave plan approved in-thread
   - [ ] 1 Precheck + WAVE_ID persisted     → runs/<WAVE_ID>.wave.dispatch
   - [ ] 1 Smoke track us1 → success        → draft PR URL
   - [ ] 2 Worktrees created (us2, us3)     → git worktree list
   - [ ] 3 Fan out us2, us3 (AUTO_CONFIRM=1)→ runs/<WAVE_ID>_us*.json exist
   - [ ] 4 Collect terminal state per track → status in each run record
   - [ ] 7 Aggregate + close wave           → runs/summary.md, --complete stamped
   ```
2. **Never hold fleet state in your head.** `runs/<WAVE_ID>.wave.dispatch` lists `track_run_ids[]`
   and each `runs/<run-id>.json` holds that track's `status` / `phase` / `blocker`. After a
   compaction, rebuild from those files — `ls runs/*<wave-id>*` then read each record — never from
   what you remember dispatching. A track you forget is a worktree, a branch and a budget that leak.

## Traceability: wave dispatch + run records (the spine)

With N workers in flight, durable state is non-negotiable — the model forgets, the file doesn't. Two
artifact tiers per wave: **one wave dispatch** (`runs/<wave-id>.wave.dispatch`, minted by
`track-wave-preflight.sh --persist` at Step 1, closed at Step 7 `--complete`) plus **one run record
per track** (`runs/<run-id>.json`). All share the `WAVE_ID` prefix, so `ls runs/*wave1*` shows the
complete fleet state at a glance — exactly how you rebuild it after a compaction. All are gitignored.

- **Per-track RUN_ID** is derived deterministically as `<wave-id>_<track-id>`; the orchestrator
  exports it as `RUN_ID` when launching each worker (the worker's `${RUN_ID:-…}` idiom accepts the
  override). On resume the wave dispatch's `track_run_ids[]` is authoritative — never re-derive.
- **One run-id, four surfaces** — stamp it into the branch name, the draft PR title, a `Run-Id:`
  commit trailer, and the run record filename. Grep any one → reconstruct the whole run.
- **Write each track's `goal` as a contract, not a wish** — spell out the **end state**, the
  **evidence** required, the **constraints** that must hold, and the **budget** (the hard stops
  below). A goal with no evidence to fail against will always think it succeeded.
- **Two sources, never conflated** — `trace[]` = hook-observed subagent start/stop (mechanical,
  `track-trace.sh`); everything from `track-note.sh` (`skills[]`, `iterations`, `phase`, a
  model-asserted `status`) is the worker's own claim, tagged `self_reported:true`.
- **`status` + `blocker` + `next_step` + `phase` are what make a halted track re-dispatchable** — a
  worker that stops without writing them leaves you nothing to route on but a stale worktree.

See [references/traceability.md](references/traceability.md) for the full wave-dispatch and run-record
JSON schemas, field-by-field, and the `final_status` value set.

## Hard stops (enforced by the orchestrator)

The #1 protection against runaway cost with N workers in flight. Enforce all five:
- **Max iterations** per worker (default 25 turns) → halt, `status: no-progress` if exceeded.
- **No-progress detection** — if the verifier result hasn't moved in N passes (default 3), halt that worker `no-progress`. (Distinct from the self-heal cap, which counts *fix attempts*; this counts *stalled passes*.)
- **Max idle** (heartbeat) — if `now − last_ts` exceeds a wall-clock threshold (default 15 min), halt that worker `no-progress`. This is the signal the other four MISS: a worker hung on a network call, deadlocked in a container, or silently crashed stops advancing `last_ts` while its iteration/pass/token counters also freeze — so it looks identical to a slow-but-working one to every *count-based* cap. Every hook stamps `last_ts` (see the run record), so the orchestrator computes staleness per tick with no extra plumbing. **Enforce this orchestrator-side, not in a hook** — a truly hung worker isn't firing hooks to self-halt.
- **Per-worker token/\$ ceiling** → halt, `status: budget-exceeded`.
- **Global token/\$ ceiling across ALL workers** → at N>1 this matters more than any single cap; halt the fleet when hit.

### Failure taxonomy — route by class, don't feed everything to self-heal

A worker's self-heal budget is for *task* failures only. Conflating the three classes below wastes
fix attempts re-reasoning about a network blip, or lets a silent-but-wrong change through:

- **Infra failure** (registry timeout, image-pull failure, worktree lock, OOM) → **bounded retry with
  backoff at the orchestrator layer**, NOT the agent. The worker shouldn't reason about "npm timed
  out" — the orchestrator retries the step and escalates only if retries exhaust. Never spend the
  self-heal budget here.
- **Task failure** (tests fail, build breaks, lint errors) → what the worker **should** see and
  self-correct on, capped by `TRACK_SELF_HEAL_ATTEMPTS` / the no-progress limits above.
- **Divergence failure** (technically green but wrong — out-of-scope refactor, deleted a file it
  shouldn't) → the dangerous class, because tests still pass. Caught by the guard path-allowlist +
  frozen paths (mechanical, pre-emptive) and the distinct adversarial verifier — never by retrying.

## Terminal states (name them explicitly)

Blocked/exhausted runs are NOT successes — workers love to dress them up as done. Every run ends in
exactly one of:
- **success** — verifier passed, evidence pasted, draft PR opened.
- **blocked** — a dependency/bug the worker can't resolve within the self-heal cap.
- **no-progress** — max-iterations or no-progress detector tripped.
- **budget-exceeded** — per-worker or global ceiling hit.

Only `success` opens a PR. The other three write a run record — `status` + `blocker` + `next_step` +
`phase`, via `track-note.sh status` — and route to the orchestrator. These are the **same four states
`sso-single-branch-development` defines**, so a solo run and a fleet worker report identically.

## Deterministic enforcement via agent hooks (Copilot or Claude Code)

The per-branch gates become **mechanical** through agent
[hooks](https://docs.github.com/en/copilot/concepts/agents/hooks) — shell commands that run at
lifecycle points (`PreToolUse`, `PostToolUse`, `SubagentStart`/`SubagentStop`, `Stop`) and can
**block a tool call before it happens**. The bundle —
[`scripts/track-*.sh`](../sso-single-branch-development/scripts/) plus a per-surface wiring manifest
([`track-hooks.json`](../sso-single-branch-development/templates/track-hooks.json) for Copilot,
[`claude-settings.json`](../sso-single-branch-development/templates/claude-settings.json) for **Claude
Code**) — is **owned and documented by `sso-single-branch-development`**
([`references/hooks.md`](../sso-single-branch-development/references/hooks.md#running-under-claude-code)
covers what each script enforces, the per-event wiring, the Claude Code specifics, and
`install-hooks.sh --surface {copilot|claude|both}`). The scripts are surface-agnostic. This
orchestrator reuses that *identical* bundle and adds only the **parallel-only configuration**: a
*different* `TRACK_ALLOWED_PREFIXES` per worktree, shared frozen entrypoints, and a fleet-wide
tool-call ceiling.

Wire a gate to a hook only when it is a *mechanical* property (a path, a forbidden command, a
counter). Leave *judgement* gates — TDD ordering, the maker/checker split, review quality — as
prompt instructions; a hook cannot tell which subagent reasoned about something, nor whether the
*right* suite ran.

Resolve each worker's env **two-tier** before launch — **per-track** vars (`TRACK_ALLOWED_PREFIXES`,
`RUN_ID`) from the track's row in the **wave dispatch file**, **global** vars from the manifest
Defaults/Commands sections. Every value is **derived from a manifest or wave dispatch field**
(see its *Hook environment* table), not invented:
```bash
# PER-TRACK (a DIFFERENT value in each worktree — export inside each worker's launch)
export TRACK_ALLOWED_PREFIXES="internal/ingest:migrations/0007_:test/ingest"  # this track's owns_paths + owns_migrations
export RUN_ID="2026-06-27T14-03_us1"                                          # <UTC-timestamp>_<track_id>
export AUTO_CONFIRM=1                                                         # MANDATORY for a dispatched worker: waives SBD's human proceed-confirm (taken once at Step 0). Prereq failures still hard-fail. Never set on a solo run.
# GLOBAL (identical for every worker in the wave)
export TRACK_FROZEN_PATHS="cmd/main.go:internal/app/app.go"  # guard: frozen entrypoints
export RUNS_DIR="runs"                                       # one shared dir; RUN_ID keys the file
# OPTIONAL — global; each stays off until set
export TRACK_TEST_CMD_PATTERN="go test|uv run pytest|npm (run )?test"  # evidence
export TRACK_MAX_TOOL_CALLS=200                                       # hard stop
export TRACK_MAX_IDLE_SECS=900                                        # hard stop: heartbeat staleness (orchestrator-side)
export TRACK_NOTIFY_WEBHOOK="https://hooks.slack.com/services/..."     # notify
```
Per-track `TRACK_ALLOWED_PREFIXES` values must be **non-overlapping** across tracks — the
precheck gate already asserts this (overlap → STOP, it would only become a merge conflict).

**Hooks are defense-in-depth, not the final gate.** They are local and bypassable — the
agent can edit a hook script during its own run, and enterprise policy can disable hooks
entirely. Layer them: hooks (fast, in-session) → git `pre-push` (local backstop) →
**GitHub Actions (the unbypassable merge gate)**. CI stays the authority, exactly as the
[autonomy boundary](#autonomy-boundary-read-first) states.

## Pipeline (N Tracks)

### 0. Analyze & plan waves (confirm before fan-out)

**Before touching any branch**, read the requested stories/tasks and determine what can safely run in parallel and what must be sequenced.

1. **Read the source**: if a Parallel Tracks Orchestrator Manifest (`.github/tracks/manifest.md`) exists, use it. If absent, read `tasks.md` (or any dispatch/spec doc the user points to), extract the task set, infer the file-ownership surface per task, and draft the manifest — **do not silently invent one**; show it to the user.

2. **Detect dependencies and overlap**: for each pair of requested tasks, check:
   - Do they write overlapping file paths? (Overlap → must be sequential.)
   - Does one produce a migration number or schema object the other reads? (Sequential.)
   - Is there any explicit ordering stated in the spec? (Respect it.)

3. **Produce a wave plan** — group tasks into the minimum number of waves where every task inside a wave is truly independent:
   ```
   Wave 1 (parallel): US1, US2, US3   — non-overlapping, independent
   Wave 2 (parallel): US4, US5        — depend on Wave 1 merged; non-overlapping
   Wave 3 (serial):   US6             — touches shared entrypoint, must run alone
   ```

4. **Confirm with the user before proceeding.** Present the wave plan — tasks per wave, why each is grouped as it is, the sequencing constraint between waves — and ask a simple yes/no ("Run Wave 1 (US1+US2+US3) now, then wait for Wave 2?"). If the user wants a subset, adjust, recheck overlap, and confirm again.

   **Do not fan out any worker until the user confirms the plan.** This is the one mandatory human checkpoint before autonomous work begins — and it is the approval that later justifies passing `AUTO_CONFIRM=1` to each worker, which has no human of its own.

5. **Sequential wave enforcement**: after Wave 1's PRs are all merged into the default branch, re-run Step 0 for Wave 2 — recheck the current tree for new overlaps introduced by Wave 1's changes, then confirm the next wave plan. Never start Wave N+1 before Wave N is merged.

> **Why this step?** Pre-defined manifests are the stable-state happy path, but most real requests start as "do user story 1, 2, 3" with no manifest. Analyzing and confirming before fan-out prevents the worst failure mode: spinning up N workers only to find mid-run that two collide on the same file.

### 1. Precheck gate (ask-back only on failure)

Run all checks; proceed silently if all pass, else stop and ask the human with the specific failure:

- Working tree clean (`git status --porcelain` empty) and on the intended base branch.
- Parallel Tracks Orchestrator Manifest resolved (`.github/tracks/manifest.md`) and a wave dispatch file with every requested track defined.
- Requested tracks have **non-overlapping** file ownership and migration ranges (cross-check the ownership map). Overlap → STOP, report the collision (it would only become a merge conflict later anyway). Make this mechanical with the bundled [`scripts/track-precheck.sh`](scripts/track-precheck.sh): pipe it a JSON array of `{id, prefixes}` (each track's `TRACK_ALLOWED_PREFIXES`) and it exits non-zero with the exact colliding prefix pair — the same string-prefix rule the guard enforces, so the precheck asserts on precisely what the workers will run.
- Docker/host headroom ≥ requested concurrent tracks vs. the manifest cap. Over cap → propose reducing concurrency.
- `gh` authenticated; remote reachable. `runs/` exists and is git-ignored.
- Mint `WAVE_ID` = `<UTC-timestamp>_wave<WAVE_NUMBER>` and per-track `RUN_ID` = `<WAVE_ID>_<track-id>`.
  Run `track-wave-preflight.sh` (`inspect` mode first — prints the wave summary + derived IDs;
  then `--persist` after user confirms the wave plan from Step 0). This creates
  `runs/<wave-id>.wave.dispatch` and is the resume anchor for the orchestrator session.
- **Smoke ONE track end-to-end before fanning out the rest.** Run the first track through the full
  pipeline (implement → verify → draft PR) as a single worker and watch it. The first real run
  almost always exposes a missing check, a fuzzy ownership boundary, or a stop condition that needs
  sharpening — far cheaper to catch on one track than to discover it replicated across N runaway
  workers. Fan out the remaining tracks only after the smoke track reaches a clean `success`.

### 2. Create isolation (one per track)

Use `using-git-worktrees`. For each track from the manifest:
```bash
git worktree add <worktree_path> -b <branch>     # e.g. ../repo-us1 -b track/us1
```
Export the manifest's per-track Docker/DB namespace before any integration run (e.g.
`export COMPOSE_PROJECT_NAME=<repo>_us1`). Never point two tracks at one shared dev DB.

### 3. Fan out (one autonomous worker per track)

Use `dispatching-parallel-agents` to launch one worker per track. Each worker executes
`sso-single-branch-development` **inside its own worktree only** for the per-branch pipeline. Each
worker selects its own execution core from the task shape — **scaffold** (non-behavioral bootstrap),
**story** (phased TDD for new/changed behavior), or **refactor** (behavior-preserving keep-green) —
then runs preflight → isolate → core → evidence gate → draft-PR handoff. Mixed-mode fleets are fine
(e.g. one scaffold track plus three story tracks).

Pass each worker: run-id, task IDs, file-ownership scope, manifest commands, project invariants, and
**the confirm waiver** (below). If bundled hooks are enabled, resolve each worker's env two-tier
before launch (per-track + global) exactly as
[Deterministic enforcement](#deterministic-enforcement-via-copilot-agent-hooks) describes.

**Pass `--yes` (or `AUTO_CONFIRM=1`) to every worker's preflight — this is mandatory, not optional.**
`sso-single-branch-development` requires a *human* to approve its preflight summary before anything is
created. A dispatched worker has no human on the other end, so without the waiver each worker either
blocks forever waiting for an answer that cannot arrive, or silently grants itself the approval — and
N workers each making that call independently is worse than either. The waiver is legitimate here and
only here: **you already took that human gate at Step 0**, once, for the whole wave. It waives *only*
the interactive confirm — a failed prerequisite still hard-fails the worker — and it is recorded as
`auto_confirm:true` / `confirmed_by:"orchestrator-waiver"` in the worker's breadcrumb, so an audit can
always separate a human-approved run from a wave-waived one. Never pass it on a solo run.

This orchestrator then applies the stricter parallel-only overlays:

- **Distinct adversarial verifier required** — maker/checker must be a different subagent from the authoring worker; failed verifier -> run record + no PR.
- **Draft-only, no-merge worker boundary** — workers may open draft PRs only; merge remains the merge gate's job.
- **Run-id spine required** — run record + PR title/body + commit trailer stay trace-linked.
- **Fleet controls required** — enforce concurrency cap, no-progress detector, idle/heartbeat detector (`now − last_ts`), and global budget ceiling across workers.

### 4. Per-track finish → DRAFT PR (autonomous, success only)

Only a `success` run reaches this step. The worker opens a **draft** PR as the final step of
`sso-single-branch-development`, building the body from [`templates/pr-body.md`](../sso-single-branch-development/templates/pr-body.md)
with its **Auto** block rendered by [`track-report.sh`](../sso-single-branch-development/scripts/track-report.sh)
(files changed, evidence + fingerprints, `tool_calls` / `trace[]`, token estimate — all from
`runs/<run-id>.json`, never re-typed):
```bash
gh pr create --draft \
  --title "track/<id> [run <run-id>]" \
  --body "$(bash .github/skills/sso-single-branch-development/scripts/track-report.sh <run-id>)" \
  --label agent-generated
```
The PR body carries the run-id, the goal contract, and the pasted evidence (test output, cost) — the
trace anchor linking PR ↔ run record. The worker stops here; **CI is the real gate**.

### 5. Integration (merge gate — per the maturity rung, NOT the worker)

Workers never merge. Integration is serialized and chosen by your current
[maturity rung](#maturity-ladder-dont-start-at-the-top):
- **Default (start here):** a human reviews each green draft PR and merges; CI must be green first.
- **Graduated:** a merge queue integrates one at a time — rebase on default branch → **regenerate**
  lockfiles (`go mod tidy` / `uv lock`, never hand-merge) → full suite on the rebased tree → merge
  only if green. Never merge stacked PRs back-to-back without re-running the suite on each rebased tree.

After a track's PR merges, tear down its isolation (`git worktree remove <path>` + delete the merged
branch) so worktrees and per-track Docker namespaces don't accumulate across waves.

### 6. Stale-PR bounce (autonomous, to the owning worker)

When merging one PR makes another stale, do NOT hand-fix. Re-dispatch the owning worker:
```
Rebase track/<id> on origin/<default>; regenerate lockfiles (do NOT hand-merge); rerun the FULL
suite and paste output; force-push. If a SOURCE (non-lockfile) conflict remains, resolve preserving
both behaviors and explain it in the PR.
```

### 7. Report

Aggregate every `runs/<run-id>.json` into `runs/summary.md`. Per track report: terminal state
(success / blocked / no-progress / budget-exceeded), evidence pointer, draft-PR URL, iterations, and
cost. Do not claim success without the evidence having been produced. Blocked/exhausted runs are
reported as such — never dressed up as done.

Once the final wave status is known, close the wave dispatch:
```bash
WAVE_NUMBER=1 bash scripts/track-wave-preflight.sh --complete all-success
# or: partial-blocked | budget-exceeded | aborted
```
This stamps `completed_utc` + `final_status` + `duration_secs` onto `runs/<wave-id>.wave.dispatch`
(write-once; re-running is a no-op). The closed breadcrumb is the durable record that Wave N is done
and Wave N+1 may begin.

## Skill-Per-Step Map

Kind legend: 🧩 **skill** = runs in-session (reads a SKILL.md); 🤖 **subagent** = dispatched agent with isolated context, maker or reviewer role; ⚙️ **script** = bundled hook/CLI, mechanical, no LLM.

| Step | Fires | Kind |
|------|-------|------|
| 0 Analyze & plan waves | Read tasks.md / manifest → derive wave plan → confirm with user | (in-session reasoning) |
| 1 Precheck | `track-wave-preflight.sh` (mint WAVE\_ID + persist wave dispatch) then `track-precheck.sh` (ownership overlap gate) | ⚙️ script |
| 2 Isolate (one per track) | `using-git-worktrees` | 🧩 skill |
| 3 Fan out (one worker per track) | `dispatching-parallel-agents` → N× **worker** subagents, each running `sso-single-branch-development` **with `AUTO_CONFIRM=1`** | 🧩 skill → 🤖 subagents |
| 4 Per-track draft PR | `track-report.sh` builds Auto block → `gh pr create --draft` | ⚙️ script |
| 5 Integration (merge gate) | CI + human / merge queue — **not the worker** | (CI/human) |
| 6 Stale-PR bounce | re-dispatch to owning worker subagent | 🤖 subagent |
| 7 Report | `track-report.sh` → `runs/summary.md` aggregation + `track-wave-preflight.sh --complete` | ⚙️ script |

## Quality Gates (Owned Here)

Four gates are mandatory — every track must pass all four before a PR counts as `success`:

- **Precheck gate**: non-overlapping ownership, clean tree, manifest complete, Docker headroom within cap — all must pass before fan-out. Ask-back only on failure; proceed silently when clean.
- **Verifier gate (maker/checker split)**: a **distinct adversarial subagent** verifies each worker's output. A failed verifier writes `status: blocked` to the run record and opens **no PR** — it never quietly skips or adjusts to pass.
- **Merge gate**: workers stop at draft PR; **GitHub Actions CI is the mechanical gate**; merging is never the worker's job. Climb the [maturity ladder](#maturity-ladder-dont-start-at-the-top) deliberately — don't skip rungs.
- **Hard stops (all five enforced)**: iteration cap, no-progress detector, idle/heartbeat staleness (`now − last_ts`), per-worker budget ceiling, and global fleet budget ceiling. A worker that trips any of these halts and writes its terminal state to the run record.
- **Evidence gate**: `success` requires pasted output. A `success` claim without evidence in the run record is `NEEDS_CONTEXT`, not `success`.

## Maturity ladder (don't start at the top)

Start low; graduate only after weeks of clean runs.

| Rung | Setup | Your job |
|---|---|---|
| **Start here** | Workers open **draft** PRs in worktrees; CI gates them | Review + merge every PR |
| **Next** | A verifier subagent pre-screens before you see it | Approve the pre-filtered ones |
| **Only after sustained clean runs** | Auto-merge **low-risk classes only** (lint, dep bumps) on green CI; merge queue serializes | Audit the run log, not each diff |

## Gotchas

- **Never auto-merge from a worker.** Workers stop at draft PR; merging follows the maturity rung. Violating this reintroduces the never-tested-main risk.
- **A failed verifier never opens a PR.** It writes `status: blocked` (or no-progress/budget-exceeded) + the blocker to the run record; the orchestrator re-dispatches with the blocker as new context or escalates.
- **Lockfiles are derived** — regenerate, never hand-merge. The most common "conflict" is a no-op script, not a real merge.
- **Frozen entrypoints** (`main.go` / `app.py`) must iterate a module registry; tracks self-register via their own files. Editing the entrypoint per track guarantees merge conflicts.
- **Global budget > per-agent budget at N>1** — one runaway worker is cheap; ten are not. Enforce the fleet ceiling.
- **A silent worker beats every count-based cap** — iteration, no-progress, and token caps only advance when the worker is *acting*; a hung/crashed/deadlocked worker freezes all three and looks identical to a slow-but-working one. Track **staleness** (`now − last_ts` from the run record's heartbeat), not just pass/fail, and enforce `TRACK_MAX_IDLE_SECS` orchestrator-side — a truly hung worker won't fire a hook to self-halt.
- **A dispatched worker with no confirm waiver hangs on a question nobody will answer.** `sso-single-branch-development` treats its preflight confirm as mandatory; pass `AUTO_CONFIRM=1`/`--yes` on every fan-out (see [Step 3](#3-fan-out-one-autonomous-worker-per-track)). The reverse error is worse: never let a *solo* run self-waive because "it felt automated."
- **Your own context is the one nothing re-anchors.** Workers reconcile from their breadcrumbs; the orchestrator has only the [ledger](#orchestrator-ledger-do-this-first-keep-it-current). After a compaction, rebuild fleet state from `runs/*<wave-id>*` — a forgotten track leaks a worktree, a branch and a budget.
- **Human review of MERGED code never leaves the loop** — no matter how good the adversarial verifier gets, "done" is still a claim, not a proof, and comprehension debt grows faster the more the fleet ships code you didn't write. The verifier gate lets you approve faster; it does not let you stop reading what landed on the default branch.
- **Prefer CLIs over heavy MCP servers inside workers** — one broad MCP can burn ~20k+ tokens of a worker's context before it does any work, and context bloat is a top cause of quality decay, cost blowups, and earlier compaction over a long run. Give workers named CLIs (self-documenting via `--help`, ~zero context); reserve MCP for tools with no CLI equivalent. **Cap concurrency to the manifest value** too — Docker resource exhaustion shows up as flaky timeouts, misread as logic bugs.
- **Overlapping ownership is a precheck failure, not a runtime surprise** — catch it in Step 1.
- **Evidence, not assertion** — "all green" without pasted output is `NEEDS_CONTEXT`. The single most important gate.
- **The run-id is the trace** — if it isn't in the branch/PR/commit/record, the run is untraceable. Stamp all four.
- **VS Code ignores hook matchers** — a `PreToolUse` hook fires on EVERY tool call; branch on `tool_name` inside the script, never rely on a `"Edit|Write"` matcher to scope it.
- **Tool names and input keys differ across surfaces** — VS Code uses `create_file`/`replace_string_in_file` with camelCase `tool_input.filePath`; Claude/CLI use `Write`/`Edit` with snake_case `file_path`. A portable guard script checks both ([`track-guard.sh`](../sso-single-branch-development/scripts/track-guard.sh) does).
- **The agent can edit hook scripts** — set `chat.tools.edits.autoApprove` to disallow editing hook scripts, or a worker can neutralize its own guard mid-run. Keep hooks < 5s; they block the agent synchronously.

## Troubleshooting

- *Two tracks edited the same file* → ownership map was wrong; treat as a merge conflict at integration, bounce to the owning worker, and tighten the manifest so the shared file becomes append-only or frozen.
- *Integration suite flaky under parallel load* → reduce concurrent tracks below the cap; confirm per-track Docker namespaces are distinct.
- *Worker loops on a failing test* → self-heal cap exceeded; escalate `BLOCKED` with root-cause, do not keep retrying.
- *PR green but post-merge main red* → a cross-track interaction the merge queue should have caught; ensure the queue runs the FULL suite on the rebased tree, not just the PR's own subset.

## References

- [`references/traceability.md`](references/traceability.md) (bundled) — full wave-dispatch and run-record JSON schemas, field-by-field, plus the `final_status` value set.
- `track-manifest.template.md` (bundled) — copy into `.github/tracks/manifest.md` and fill per project.
- [`scripts/track-wave-preflight.sh`](scripts/track-wave-preflight.sh) (bundled, parallel-only) —
  mint/recover the orchestrator wave dispatch (`runs/<wave-id>.wave.dispatch`). Modes: `inspect`
  (default, read-only, prints summary + JSON), `--persist` (write wave breadcrumb; idempotent),
  `--complete <status>` (stamp `completed_utc` + `final_status`; write-once). Env: `WAVE_NUMBER`
  (required), `WAVE_TRACKS` (comma-separated, required for `--persist`), `WAVE_ID` (override, rare),
  `TRACK_BASE_REF`. Derives per-track RUN_IDs as `<wave-id>_<track-id>`.
- [`scripts/track-precheck.sh`](scripts/track-precheck.sh) (bundled, parallel-only) — the mechanical Precheck overlap gate: reads a JSON array of `{id, prefixes}` on stdin, exits 0 when all tracks' ownership prefixes are mutually disjoint, or exit 2 with the exact colliding pair / config error (empty ownership, duplicate id). Run it in Step 1 before fan-out.
- The Copilot agent-hook bundle is **owned by `sso-single-branch-development`** ([`track-hooks.json`](../sso-single-branch-development/templates/track-hooks.json) + [`scripts/track-*.sh`](../sso-single-branch-development/scripts/)) and reused whole by every worker: `track-reconcile.sh` (SessionStart resume), `track-guard.sh` (PreToolUse ownership + push lockout), `track-evidence.sh` / `track-meter.sh` (PostToolUse evidence + tool-call ceiling), `track-trace.sh` (Subagent trace with per-spawn reason), `track-evidence-gate.sh` / `track-tokens.sh` / `track-sentinel.sh` / `track-notify.sh` (Stop: freshness gate, token estimate, secrets scan, webhook). Manual/CLI members: `track-preflight.sh` (mint/recover RUN_ID; `--yes` waiver), `track-report.sh` (deterministic PR-body Auto block), `track-note.sh` (`phase`/`governance`/`status` + optional skill/loop trace). This orchestrator reuses the bundle and layers per-track/global env on top. See [`references/hooks.md`](../sso-single-branch-development/references/hooks.md) for the full per-script contract.
- [Copilot agent hooks (GitHub Docs)](https://docs.github.com/en/copilot/concepts/agents/hooks) · [Agent hooks in VS Code](https://code.visualstudio.com/docs/copilot/customization/hooks) · [Hooks reference (per-event I/O schema)](https://code.visualstudio.com/docs/agents/reference/hooks-reference) — events, JSON I/O, exit codes, Claude/CLI cross-compatibility.
- Composes: `using-git-worktrees`, `dispatching-parallel-agents`, `sso-single-branch-development`.
