# Test Report — sso-executing-parallel-tracks Skill

> **Historical snapshot — not the current result.** This report records one manual run, on
> 2026-07-04, in a *different* repo (`aisat-studio`), at 188 assertions. The suite is now **205
> assertions** and runs on every push/PR via
> [`.github/workflows/skill-tests.yml`](../../../workflows/skill-tests.yml) — CI is the authority on
> whether the bundle is green. Do not read the counts below as current.

| | |
|---|---|
| **Date** | 2026-07-04 |
| **Last run** | `2026-07-04T11-07_local` |
| **Script** | `test-skill.sh` regression suite |
| **Repo** | `aisat-studio` |
| **Result** | ✅ 188 PASSED · ⏭ 0 SKIPPED · ❌ 0 FAILED · 188 total |

---

## Summary

All structural, behavioural, and extreme-parallel quality-gates for the
`sso-executing-parallel-tracks` skill were exercised across **27 test suites**
(188 assertions total). Zero skips; the ephemeral temp-git approach means every
assertion runs without needing a committed branch.

**Suites 1–17** are the documentation / contract fence: SKILL.md structural
completeness, track-manifest template fields, embedded run-record JSON schema,
ownership-overlap precheck logic, guard hook cross-worktree isolation (file
ownership + merge/push lockout), track-meter global budget ceiling, hard-stop
taxonomy, terminal state exhaustiveness, Docker isolation, run-ID 4-surface
traceability, stale-PR bounce protocol, and five extreme-parallel edge cases
(over-cap, all-blocked, global-budget mid-wave, smoke-first gate,
goal-as-contract).

**Suites 18–27** are the new *behavioral* layer added in this round: each drives
a real hook or gate script and asserts on actual allow/deny/block/output
decisions — a behavior regression now fails even if the prose is untouched. New
scripts covered: `track-guard.sh` CLI surface (`Write`/`Edit`/`MultiEdit`),
`track-evidence.sh` + `track-evidence-gate.sh` (capture fingerprint, fresh/
stale/failing/missing classification), `track-preflight.sh` (RUN-ID mint/
resume/breadcrumb/hard-fail), `track-sentinel.sh` (staged-secret and
debug-leftover scan), `track-trace.sh` (append-only activation trace),
`track-notify.sh` (fire-and-forget webhook), `track-reconcile.sh` (durable
resume report), and the new **`track-precheck.sh`** (mechanical Precheck overlap
gate, the last previously prose-only gate). An end-to-end lifecycle suite (22)
chains all five stages of a single worker run on one run-id.

---

## New Asset

### `scripts/track-precheck.sh` (parallel-only, skill-owned)

The Precheck gate's overlap check was previously documented in `SKILL.md` prose
only. This round adds a shipped script that mechanizes it the same way
`track-guard.sh` mechanizes per-worktree ownership.

**Interface:** reads a JSON array of `{id, prefixes}` (one entry per track,
`prefixes` = the same colon-separated string each worker receives as
`TRACK_ALLOWED_PREFIXES`) on stdin. Uses the identical string-prefix rule the
guard enforces, so the precheck asserts on exactly what the workers will run.

**Exit codes:**
- `0` — all pairs disjoint, fan-out may proceed.
- `2` — collision detected OR config error (empty ownership, duplicate id,
  malformed input) — fail-closed STOP.

**Output:** `{ok, tracks, collisions:[{a,b,a_prefix,b_prefix}], config_errors:[]}`.

`SKILL.md` Step 1 and References now link to it.

---

> **Bug fixes** discovered during suite development are documented separately in
> [bug-fixes-2026-07-04.md](bug-fixes-2026-07-04.md) (11 bugs, covering bash
> `set -e` pitfalls, shell-function/env-export gotchas, git fingerprint
> invariants, and the new `track-precheck.sh` empty-array unbound variable).

---

## Test Results

### Suite 1 — SKILL.md Structural Integrity

| # | Test | Result |
|---|------|--------|
| 1 | SKILL.md exists | ✅ PASS |
| 2 | frontmatter name=sso-executing-parallel-tracks | ✅ PASS |
| 3 | Steps 1-7 all present | ✅ PASS |
| 4 | Steps appear in ascending line order | ✅ PASS |
| 5 | 3 mandatory gates stated | ✅ PASS |
| 6 | 'Only success opens a PR' stated | ✅ PASS |
| 7 | 4 hard stops defined | ✅ PASS |
| 8 | maker/checker split required | ✅ PASS |
| 9 | draft-only / no-merge worker boundary stated | ✅ PASS |
| 10 | run-id: all 4 surfaces mentioned in one block | ✅ PASS |
| 11 | smoke-one-track-first in Step 1 | ✅ PASS |
| 12 | worktree teardown after merge in Step 5 | ✅ PASS |
| 13 | goal-as-contract guidance present | ✅ PASS |
| 14 | runs/summary.md aggregation mentioned | ✅ PASS |
| 15 | 'never dressed up as done' stated | ✅ PASS |
| 16 | track-manifest.template.md bundled | ✅ PASS |
| 17 | SBD scripts/ bundle referenced and exists | ✅ PASS |
| 18 | SBD templates/ bundle referenced and exists | ✅ PASS |
| 19 | runs/ gitignore guidance present | ✅ PASS |
| 20 | Gotchas section present | ✅ PASS |
| 20a | track-precheck.sh bundled + referenced in SKILL.md | ✅ PASS |
| 20b | SKILL.md references scripts/track-precheck.sh | ✅ PASS |

### Suite 2 — track-manifest.template.md Completeness

| # | Test | Result |
|---|------|--------|
| 21 | default_branch field | ✅ PASS |
| 22 | max_concurrent_tracks field | ✅ PASS |
| 23 | self_heal_attempts field | ✅ PASS |
| 24 | max_iterations field | ✅ PASS |
| 25 | no_progress_passes field | ✅ PASS |
| 26 | per_worker_budget_usd field | ✅ PASS |
| 27 | global_budget_usd field | ✅ PASS |
| 28 | Commands table present | ✅ PASS |
| 29 | Evidence pack section present | ✅ PASS |
| 30 | Frozen entrypoints section | ✅ PASS |
| 31 | Ownership map section | ✅ PASS |
| 32 | Docker namespace pattern | ✅ PASS |

### Suite 3 — Embedded Run Record JSON Schema

| # | Test | Result |
|---|------|--------|
| 33 | embedded run record is valid JSON | ✅ PASS |
| 34–46 | all 13 required fields present | ✅ PASS × 13 |
| 47 | status is one of the 4 terminal states | ✅ PASS |
| 48 | trace is an array with ≥2 entries | ✅ PASS |
| 49 | every trace entry has t, kind, name | ✅ PASS |
| 50 | trace kind values are only 'skill' or 'subagent' | ✅ PASS |

### Suite 4 — Precheck Gate: Ownership Overlap Detection (logic)

| # | Test | Result |
|---|------|--------|
| 51 | distinct non-overlapping prefixes → no overlap | ✅ PASS |
| 52 | identical prefix → overlap detected | ✅ PASS |
| 53 | parent prefix ⊂ child prefix → overlap detected | ✅ PASS |
| 54 | shared hotspot in both lists → overlap detected | ✅ PASS |
| 55 | completely disjoint prefixes → no overlap | ✅ PASS |
| 56 | 3-track wave all-disjoint → valid | ✅ PASS |
| 57 | 3-track wave shared hotspot → must stop | ✅ PASS |

### Suite 5 — Guard Hook: Cross-Worktree Ownership

| # | Test | Result |
|---|------|--------|
| 58 | track A edits own file → allow | ✅ PASS |
| 59 | track A edits track B's file → deny | ✅ PASS |
| 60 | track B edits own file → allow | ✅ PASS |
| 61 | track B edits track A's file → deny | ✅ PASS |
| 62 | frozen entrypoint → deny for any track | ✅ PASS |
| 63 | multi_replace with out-of-scope path → deny entire batch | ✅ PASS |
| 64 | TRACK_ALLOWED_PREFIXES unset → fail-closed deny | ✅ PASS |

### Suite 6 — Guard Hook: Merge/Push Lockout

| # | Test | Result |
|---|------|--------|
| 65 | git push → deny | ✅ PASS |
| 66 | git push --force → deny even with TRACK_ALLOW_FF_PUSH=1 | ✅ PASS |
| 67 | gh pr merge → deny | ✅ PASS |
| 68 | git reset --hard → deny | ✅ PASS |
| 69 | TRACK_ALLOW_FF_PUSH=1, plain push → allow | ✅ PASS |
| 70 | gh pr create --draft → allow | ✅ PASS |

### Suite 7 — Global Budget Ceiling via track-meter

| # | Test | Result |
|---|------|--------|
| 71 | 1st call → allow | ✅ PASS |
| 72 | 3rd call → allow | ✅ PASS |
| 73 | 4th call (over ceiling) → deny | ✅ PASS |
| 74 | ceiling trip writes status=no-progress to run record | ✅ PASS |

### Suite 8 — Hard Stop Taxonomy

| # | Test | Result |
|---|------|--------|
| 75 | max_iterations default (25) stated | ✅ PASS |
| 76 | no-progress default pass count (3) stated | ✅ PASS |
| 77 | no-progress distinct from self-heal cap | ✅ PASS |
| 78 | global ceiling halts the fleet | ✅ PASS |
| 79 | per-worker and global ceilings are separate | ✅ PASS |

### Suite 9 — Terminal State Exhaustiveness

| # | Test | Result |
|---|------|--------|
| 80 | 'success' defined | ✅ PASS |
| 81 | 'blocked' defined | ✅ PASS |
| 82 | 'no-progress' defined | ✅ PASS |
| 83 | 'budget-exceeded' defined | ✅ PASS |
| 84 | exactly 4 terminal states | ✅ PASS |
| 85 | failed verifier → run record, NOT PR | ✅ PASS |

### Suite 10 — Isolation: Per-Track Docker Namespace

| # | Test | Result |
|---|------|--------|
| 86 | COMPOSE_PROJECT_NAME exported per track | ✅ PASS |
| 87 | manifest defines Docker namespace pattern | ✅ PASS |
| 88 | 'Never point two tracks at one shared dev DB' | ✅ PASS |
| 89 | namespace pattern uses \<track_id\> | ✅ PASS |
| 90 | track A namespace ≠ track B namespace | ✅ PASS |

### Suite 11 — Traceability: Run-ID 4-Surface Stamping

| # | Test | Result |
|---|------|--------|
| 91 | run-id format \<UTC-timestamp\>_\<track_id\> | ✅ PASS |
| 92 | surface 1: branch name | ✅ PASS |
| 93 | surface 2: PR title | ✅ PASS |
| 94 | surface 3: commit trailer Run-Id: | ✅ PASS |
| 95 | surface 4: run record filename | ✅ PASS |
| 96 | 'Grep any one surface → reconstruct the whole run' | ✅ PASS |
| 97 | PR title contains [run \<run-id\>] pattern | ✅ PASS |
| 98 | embedded run_id matches format | ✅ PASS |

### Suite 12 — Stale-PR Bounce Protocol

| # | Test | Result |
|---|------|--------|
| 99 | Step 6 contains 'rebase' | ✅ PASS |
| 100 | Step 6 contains 'regenerate lockfiles' | ✅ PASS |
| 101 | Step 6 says 'DO NOT hand-merge' | ✅ PASS |
| 102 | Step 6 contains 'force-push' | ✅ PASS |
| 103 | SOURCE conflict → preserve both behaviors | ✅ PASS |
| 104 | bounce re-dispatched to owning worker | ✅ PASS |

### Suite 13 — Extreme Parallel: Over-Cap Detection

| # | Test | Result |
|---|------|--------|
| 105 | precheck checks Docker/host headroom | ✅ PASS |
| 106 | over-cap → propose reducing concurrency (not silent) | ✅ PASS |
| 107 | TRACK_ALLOWED_PREFIXES is per-track | ✅ PASS |
| 108 | RUN_ID is per-track | ✅ PASS |
| 109 | GLOBAL vars identical for every worker | ✅ PASS |
| 110 | N=3 > cap=2 → over-cap detected | ✅ PASS |

### Suite 14 — Extreme Parallel: All-Blocked Scenario

| # | Test | Result |
|---|------|--------|
| 111 | all tracks status=blocked → no phantom success | ✅ PASS |
| 112 | all blocked → pr_url=null | ✅ PASS |
| 113 | summary.md has exactly 3 track entries | ✅ PASS |
| 114 | summary.md has no 'success' entry | ✅ PASS |

### Suite 15 — Extreme Parallel: Global Budget Hit Mid-Wave

| # | Test | Result |
|---|------|--------|
| 115 | fleet cost > global budget → ceiling was hit | ✅ PASS |
| 116 | exactly 1 track succeeded before ceiling | ✅ PASS |
| 117 | 2 tracks halted as budget-exceeded | ✅ PASS |
| 118 | halted tracks have pr_url=null | ✅ PASS |
| 119 | global ceiling > per-worker stated as critical at N>1 | ✅ PASS |

### Suite 16 — Smoke Track Fails: Fan-Out Must Not Proceed

| # | Test | Result |
|---|------|--------|
| 120 | fan out only after smoke track reaches 'success' | ✅ PASS |
| 121 | smoke rule is in Step 1 (before fan-out) | ✅ PASS |
| 122–124 | blocked/no-progress/budget-exceeded → fan-out must NOT proceed | ✅ PASS × 3 |

### Suite 17 — Goal-as-Contract: All 4 Required Parts

| # | Test | Result |
|---|------|--------|
| 125 | 'end state' named | ✅ PASS |
| 126 | 'evidence' named | ✅ PASS |
| 127 | 'constraints' named | ✅ PASS |
| 128 | 'budget' named | ✅ PASS |
| 129 | goal without evidence 'will always think it succeeded' | ✅ PASS |
| 130 | embedded goal is non-trivial | ✅ PASS |

### Suite 18 — Guard Portability: CLI Surface (Write/Edit/MultiEdit) *(new)*

| # | Test | Result |
|---|------|--------|
| 131 | Write (snake_case file_path) in-scope → allow | ✅ PASS |
| 132 | Write out-of-scope → deny | ✅ PASS |
| 133 | Edit (CLI) out-of-scope → deny | ✅ PASS |
| 134 | Edit (CLI) frozen entrypoint → deny | ✅ PASS |
| 135 | MultiEdit (edits[].file_path) mixed → deny whole batch | ✅ PASS |
| 136 | MultiEdit both in-scope → allow | ✅ PASS |
| 137 | Write with prefixes unset → fail-closed deny (CLI) | ✅ PASS |

### Suite 19 — Evidence Gate: Capture + Assert *(new)*

| # | Test | Result |
|---|------|--------|
| 138 | fresh passing evidence (fingerprint matches) → allow | ✅ PASS |
| 139 | no evidence captured → block (missing) | ✅ PASS |
| 140 | failing evidence (FAIL marker) → block | ✅ PASS |
| 141 | stale evidence (tree changed since capture) → block | ✅ PASS |
| 142 | evidence entry stores a fingerprint | ✅ PASS |

### Suite 20 — Preflight: RUN_ID Mint / Resume / Hard-Fail *(new)*

| # | Test | Result |
|---|------|--------|
| 143 | fresh preflight mints run-id in correct format + mode=start | ✅ PASS |
| 144 | --commit persists runs/\<run-id\>.dispatch breadcrumb | ✅ PASS |
| 145 | resume recovers identical run-id (mode=resume) | ✅ PASS |
| 146 | distinct track → distinct run-id | ✅ PASS |
| 147 | missing prereq → exit 3 + prereq_ok=false | ✅ PASS |

### Suite 21 — Precheck Overlap, Proven by the REAL Guard *(new)*

| # | Test | Result |
|---|------|--------|
| 148 | overlapping prefixes → path admitted by both guards → real collision | ✅ PASS |
| 149 | identical prefixes → mutual-admit collision | ✅ PASS |
| 150 | disjoint, A's file → not mutually admitted | ✅ PASS |
| 151 | disjoint, B's file → not mutually admitted | ✅ PASS |

### Suite 22 — End-to-End Worker Lifecycle *(new)*

| # | Test | Result |
|---|------|--------|
| 152 | in-scope edit → guard allow | ✅ PASS |
| 153 | no evidence yet → gate blocks done-claim | ✅ PASS |
| 154 | fresh passing evidence → gate allow | ✅ PASS |
| 155 | gh pr merge → guard deny (worker boundary) | ✅ PASS |
| 156 | gh pr create --draft → guard allow | ✅ PASS |

### Suite 23 — Sentinel: Secret / Debug-Leftover Scan *(new)*

| # | Test | Result |
|---|------|--------|
| 157 | staged secret (api_key=...) → block | ✅ PASS |
| 158 | staged debug leftover (console.log) → block | ✅ PASS |
| 159 | clean staged diff → allow | ✅ PASS |
| 160 | TRACK_SENTINEL unset → no-op (opt-in gate) | ✅ PASS |
| 161 | stop_hook_active=true → no-op (loop-safe) | ✅ PASS |

### Suite 24 — Trace: Activation-Trace Append *(new)*

| # | Test | Result |
|---|------|--------|
| 162 | SubagentStart → run record created + 1 trace entry | ✅ PASS |
| 163 | SubagentStop → trace accumulates (append-only) | ✅ PASS |
| 164 | entries carry kind=subagent + event + agent_type | ✅ PASS |
| 165 | no RUN_ID → no-op | ✅ PASS |

### Suite 25 — Notify: Best-Effort Webhook *(new)*

| # | Test | Result |
|---|------|--------|
| 166 | webhook set → exit 0 (never blocks session) | ✅ PASS |
| 167 | payload carries run-id + status from record | ✅ PASS |
| 168 | no webhook → no-op, exit 0 | ✅ PASS |
| 169 | unreachable webhook → still exit 0 (fire-and-forget) | ✅ PASS |

### Suite 26 — Reconcile: Durable-State Resume Report *(new)*

| # | Test | Result |
|---|------|--------|
| 170 | clean tree, no required evidence → resumable=true | ✅ PASS |
| 171 | dirty tree → resumable=false + UNTRUSTED note | ✅ PASS |
| 172 | required-but-uncaptured evidence → missing, resumable=false | ✅ PASS |
| 173 | fresh passing evidence → fresh kind, resumable=true | ✅ PASS |
| 174 | tree changed after capture → evidence STALE, resumable=false | ✅ PASS |
| 175 | RUN_ID unset → self-recovers from breadcrumb | ✅ PASS |

### Suite 27 — Precheck Gate: track-precheck.sh *(new)*

| # | Test | Result |
|---|------|--------|
| 176 | track-precheck.sh is bundled + executable | ✅ PASS |
| 177 | disjoint prefixes → ok=true, exit 0 (fan-out may proceed) | ✅ PASS |
| 178 | parent ⊃ child prefix → collision, exit 2 (STOP) | ✅ PASS |
| 179 | collision report names both tracks + offending prefix pair | ✅ PASS |
| 180 | identical prefixes → collision, exit 2 | ✅ PASS |
| 181 | single track → ok=true, exit 0 (no self-comparison) | ✅ PASS |
| 182 | 3-way wave with shared hotspot → collision, exit 2 | ✅ PASS |
| 183 | 3-way disjoint wave → ok=true, exit 0 | ✅ PASS |
| 184 | empty-ownership track → config error, exit 2 (fail-closed) | ✅ PASS |
| 185 | duplicate track id → config error, exit 2 | ✅ PASS |
| 186 | non-array input → fail-closed exit 2 | ✅ PASS |

---

## Coverage Summary

| Category | Suites | Tests | Passed |
|----------|--------|-------|--------|
| Structural integrity (SKILL.md + manifest) | 1–2 | 34 | 34 |
| Run-record JSON schema | 3 | 18 | 18 |
| Precheck gate — logic only | 4 | 7 | 7 |
| Guard: file ownership (parallel) | 5 | 7 | 7 |
| Guard: merge/push lockout | 6 | 6 | 6 |
| Budget meter ceiling | 7 | 4 | 4 |
| Hard-stop taxonomy | 8 | 5 | 5 |
| Terminal state exhaustiveness | 9 | 6 | 6 |
| Docker isolation | 10 | 5 | 5 |
| Traceability (run-ID 4 surfaces) | 11 | 8 | 8 |
| Stale-PR bounce protocol | 12 | 6 | 6 |
| Extreme parallel — over-cap | 13 | 6 | 6 |
| Extreme parallel — all-blocked | 14 | 4 | 4 |
| Extreme parallel — global budget mid-wave | 15 | 5 | 5 |
| Extreme parallel — smoke-first gate | 16 | 5 | 5 |
| Goal-as-contract | 17 | 6 | 6 |
| Guard portability: CLI surface | 18 | 7 | 7 |
| Evidence gate: capture + assert | 19 | 5 | 5 |
| Preflight: RUN_ID mint/resume/hard-fail | 20 | 5 | 5 |
| Precheck — guard-backed proof | 21 | 4 | 4 |
| End-to-end worker lifecycle | 22 | 5 | 5 |
| Sentinel: secret/leftover scan | 23 | 5 | 5 |
| Trace: activation-trace append | 24 | 4 | 4 |
| Notify: best-effort webhook | 25 | 4 | 4 |
| Reconcile: durable-state resume | 26 | 6 | 6 |
| Precheck gate: track-precheck.sh | 27 | 11 | 11 |
| **Total** | **27** | **188** | **188** |
