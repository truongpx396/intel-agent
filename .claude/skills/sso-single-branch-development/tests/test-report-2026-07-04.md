# Test Report — sso-single-branch-development Skill

> **Historical snapshot — not the current result.** This report records one manual run, on
> 2026-07-04, in a *different* repo (`aisat-studio`), at 66 assertions. The suite is now **148
> assertions** and runs on every push/PR via
> [`.github/workflows/skill-tests.yml`](../../../workflows/skill-tests.yml) — CI is the authority on
> whether the bundle is green. Kept for the §Bug Fixes history, which documents a real defect the
> suite caught; do not read the counts below as current.
>
> The suite covers the **mechanical** gates only. The judgement gates (TDD ordering, maker/checker
> split, governance-in-briefs) are audited by hand against
> [`prompt-level-checklist.md`](prompt-level-checklist.md).

| | |
|---|---|
| **Date** | 2026-07-04 |
| **Last run** | `2026-07-04T07:59:32Z` |
| **Branch** | `test/sbd-skill-1783151970` (temp branch created by suite) |
| **Run by** | `test-skill.sh` regression suite |
| **Repo** | `aisat-studio` |
| **Result** | ✅ 65 PASSED · ⏭ 1 SKIPPED · ❌ 0 FAILED · 66 total |

---

## Summary

All mechanical quality-gates in the hooks bundle were exercised across 11 test
suites (66 assertions total). One test was **SKIPPED** because it requires an
already-committed file under an immutable prefix, which is unavailable in the
ephemeral temp branch created by the suite.

**Changes since the previous run** (51 → 66 assertions):
- **New Suite 5** — `track-evidence.sh` producer behavioural tests + producer→gate
  end-to-end contract. Evidence records are now produced by the real script rather
  than hand-written, so any drift between producer and gate field names /
  fingerprint computation is immediately caught.
- **Guard**: 3 new allow-path assertions (benign terminal command, `git status`,
  non-file/non-terminal tool passthrough) guard against over-broad deny regressions.
- **Evidence-gate**: 1 new multi-kind block assertion (one kind present, a second
  required kind absent → block that names the missing kind).
- **Meter**: 2 new assertions (count accumulates across calls, `status=no-progress`
  written on ceiling trip).
- **New Suite 10** — `track-notify.sh` no-op assertion (no webhook → never blocks).
- **Removed** the standalone fingerprint-parity suite — it duplicated the reconcile
  suite's bug-regression assertion and is now superseded by the producer parity test.

One **critical bug** was discovered and fixed during a previous run (see §Bug Fixes).

---

## Test Results

### Suite 1 — `track-preflight.sh`

| # | Test | Result |
|---|------|--------|
| 1 | fresh start → mode=start + RUN_ID minted | ✅ PASS |
| 2 | `--commit` persists `.dispatch` breadcrumb | ✅ PASS |
| 3 | same slug → RESUME mode | ✅ PASS |
| 4 | different slug → fresh START | ✅ PASS |
| 5 | missing `TRACK_ID` → hard-fail exit 1 | ✅ PASS |

### Suite 2 — `track-reconcile.sh`

| # | Test | Result |
|---|------|--------|
| 6 | stale evidence identified (FP mismatch) | ✅ PASS |
| 7 | RUN_ID auto-recovered from breadcrumb | ✅ PASS |
| 8 | fingerprint == evidence-gate (bug-regression) | ✅ PASS (after fix) |
| 9 | no breadcrumb → silent no-op | ✅ PASS |

### Suite 3 — `track-guard.sh` — File Ownership

| # | Test | Result |
|---|------|--------|
| 10 | path within allowed prefix → allow | ✅ PASS |
| 11 | path outside allowed prefix → deny | ✅ PASS |
| 12 | frozen entrypoint → deny | ✅ PASS |
| 13 | GENERATED banner → deny | ✅ PASS |
| 14 | committed file under immutable prefix → deny | ⏭ SKIP (no committed file in temp branch) |
| 15 | multi_replace with one out-of-scope path → deny | ✅ PASS |
| 16 | unset `TRACK_ALLOWED_PREFIXES` → fail-closed deny | ✅ PASS |

### Suite 4 — `track-guard.sh` — Terminal Lockout

| # | Test | Result |
|---|------|--------|
| 17 | worker push blocked → deny | ✅ PASS |
| 18 | force-flag push blocked even with `TRACK_ALLOW_FF_PUSH=1` → deny | ✅ PASS |
| 19 | `gh pr merge` command blocked → deny | ✅ PASS |
| 20 | `git reset --hard` command blocked → deny | ✅ PASS |
| 21 | fast-forward push with `TRACK_ALLOW_FF_PUSH=1` → allow | ✅ PASS |
| 22 | `DROP TABLE` with `TRACK_GUARD_DESTRUCTIVE` → deny | ✅ PASS |
| 23 | Redis `FLUSHALL` with `TRACK_GUARD_DESTRUCTIVE` → deny | ✅ PASS |
| 24 | `rm -rf` absolute path with `TRACK_GUARD_DESTRUCTIVE` → deny | ✅ PASS |
| 25 | benign `go test ./...` terminal command → allow | ✅ PASS |
| 26 | benign `git status` terminal command → allow | ✅ PASS |
| 27 | unrelated tool (`read_file`) → allow (no interception) | ✅ PASS |

### Suite 5 — `track-evidence.sh` (producer)

Verifies the capture half of the evidence gate. All records are **produced by
the real script** — no hand-written JSON — so the producer→gate field-name and
fingerprint contract is exercised end-to-end.

| # | Test | Result |
|---|------|--------|
| 28 | `RUN_ID` unset → no record written | ✅ PASS |
| 29 | no matcher set → no record written | ✅ PASS |
| 30 | non-terminal tool (`create_file`) → no record | ✅ PASS |
| 31 | `TRACK_TEST_CMD_PATTERN` match → `kind=test` recorded | ✅ PASS |
| 32 | `TRACK_EVIDENCE_KINDS` `label:pattern` → `kind=go-test` derived (first-match-wins) | ✅ PASS |
| 33 | producer fingerprint == current tree fingerprint (producer↔gate parity) | ✅ PASS |
| 34 | *(e2e)* producer-captured pass at current FP → gate allows | ✅ PASS |
| 35 | *(e2e)* multi-kind: one kind present, second missing → gate blocks and names it | ✅ PASS |

### Suite 6 — `track-evidence-gate.sh`

| # | Test | Result |
|---|------|--------|
| 36 | missing run record → block | ✅ PASS |
| 37 | `stop_hook_active` → no-op | ✅ PASS |
| 38 | no required evidence set → no-op | ✅ PASS |
| 39 | fresh evidence at current FP → allow | ✅ PASS |
| 40 | stale FP → block | ✅ PASS |
| 41 | FAIL marker → block | ✅ PASS |
| 42 | multi-kind: second required kind absent → block names it | ✅ PASS |

### Suite 7 — `track-sentinel.sh`

| # | Test | Result |
|---|------|--------|
| 43 | `stop_hook_active` → no-op | ✅ PASS |
| 44 | `TRACK_SENTINEL` unset → no-op | ✅ PASS |
| 45 | staged secret (`sk_live_...`) → block | ✅ PASS |
| 46 | `console.log` leftover → block | ✅ PASS |

### Suite 8 — `track-meter.sh`

| # | Test | Result |
|---|------|--------|
| 47 | under ceiling → allow | ✅ PASS |
| 48 | ceiling=0 → block | ✅ PASS |
| 49 | unset ceiling → no-op | ✅ PASS |
| 50 | count accumulates across calls, trips past ceiling | ✅ PASS |
| 51 | ceiling trip writes `status=no-progress` to run record | ✅ PASS |

### Suite 9 — `track-trace.sh`

| # | Test | Result |
|---|------|--------|
| 52 | `SubagentStart` → appended to run record | ✅ PASS |
| 53 | no `RUN_ID` → no-op | ✅ PASS |

### Suite 10 — `track-notify.sh`

| # | Test | Result |
|---|------|--------|
| 54 | no webhook configured → silent no-op (never emits a block decision) | ✅ PASS |

### Suite 11 — `SKILL.md` + `track-hooks.json` Structural Integrity

| # | Test | Result |
|---|------|--------|
| 55 | all bundled scripts exist in `scripts/` | ✅ PASS |
| 56 | `track-hooks.json` is valid JSON | ✅ PASS |
| 57 | `preToolUse` → `track-guard.sh` | ✅ PASS |
| 58 | `sessionStart` → `track-reconcile.sh` | ✅ PASS |
| 59 | `postToolUse` → `track-evidence.sh` | ✅ PASS |
| 60 | `postToolUse` → `track-meter.sh` | ✅ PASS |
| 61 | `stop` → `track-evidence-gate.sh` | ✅ PASS |
| 62 | `stop` → `track-sentinel.sh` | ✅ PASS |
| 63 | `stop` order: evidence-gate before sentinel | ✅ PASS |
| 64 | `SKILL.md` defines Steps 1–8 in correct line order | ✅ PASS |
| 65 | `SKILL.md` references all required superpower skills | ✅ PASS |
| 66 | all scripts named in `track-hooks.json` exist in `scripts/` | ✅ PASS |

---

## Bug Fixes

### BUG-001 — Fingerprint inconsistency in `track-reconcile.sh`

**Severity**: Critical  
**Files fixed**:
- `.github/skills/sso-single-branch-development/scripts/track-reconcile.sh`
- `.github/hooks/track-reconcile.sh`

**Problem**

The fingerprint computation in `track-reconcile.sh` (line ~88) hashed only the
HEAD commit and staged diff:

```bash
current_fp="$({ git rev-parse HEAD; git diff HEAD; } | sha1sum | cut -d' ' -f1)"
```

Both `track-evidence.sh` and `track-evidence-gate.sh` also hashed:

1. Untracked file names (sorted `git ls-files --others --exclude-standard`)
2. Untracked file content (via `git hash-object --stdin-paths`)

This mismatch caused reconcile to misreport evidence freshness on any repo that
has untracked files, breaking the resume / interrupt-recovery workflow.

**Fix** — added the untracked-file hashing block:

```bash
current_fp="$(
  {
    git rev-parse HEAD
    git diff HEAD
    git ls-files --others --exclude-standard | sort
    git ls-files --others --exclude-standard | sort \
      | git hash-object --stdin-paths 2>/dev/null || true
  } | sha1sum | cut -d' ' -f1
)"
```

**Regression tests**: Suite 2 #8 (`reconcile: fingerprint == evidence-gate`) and Suite 5 #33 (`producer fingerprint == current tree`).

---

## Documentation Note

**Guard fail-closed behaviour**

`hooks.md` states the guard "no-ops until env is set". In practice, the
file-ownership gate is **fail-closed** (deny-all) when `TRACK_ALLOWED_PREFIXES`
is unset (test #16 confirms this). The documentation should be updated to:

> "The file-ownership gate is fail-closed until `TRACK_ALLOWED_PREFIXES` is
> configured; the terminal lockout patterns (push, force, merge, reset-hard)
> are always active regardless of env."

---

## Artefacts

| File | Purpose |
|------|---------|
| `scripts/test-skill.sh` | Reusable regression suite — 11 suites, 66 assertions (run from repo root) |
| `scripts/track-reconcile.sh` | Fixed fingerprint computation (BUG-001) |
| `.github/hooks/track-reconcile.sh` | Installed copy — same fix applied |
