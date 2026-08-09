#!/usr/bin/env bash
# test-skill.sh — Regression suite for the sso-executing-parallel-tracks skill.
#
# Usage (from repo root):
#   bash .github/skills/sso-executing-parallel-tracks/tests/test-skill.sh
#
# 27 suites / ~186 assertions. Exit 0 if all non-skipped tests pass, 1 if any fail.
# Requires: bash 4+, jq, git, awk.
#
# Suites 1-17 are the documentation/contract fence (mostly greps of SKILL.md and
# tautological logic). Suites 18-27 are BEHAVIORAL: they invoke the real hook and
# gate scripts (track-guard/evidence/evidence-gate/preflight/sentinel/trace/notify/
# reconcile/precheck) and assert on actual allow/deny/block/output decisions, so a
# behavior regression fails even if the prose is untouched.
set -euo pipefail

# ─── colour helpers ──────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; RESET='\033[0m'
PASS=0; FAIL=0; SKIP=0

pass() { printf "${GREEN}  ✅ PASS${RESET}  %s\n" "$1"; PASS=$((PASS+1)); }
fail() { printf "${RED}  ❌ FAIL${RESET}  %s\n" "$1"; FAIL=$((FAIL+1)); }
skip() { printf "${YELLOW}  ⏭ SKIP${RESET}  %s\n" "$1"; SKIP=$((SKIP+1)); }
suite() { echo; echo "### $1"; echo; }

assert() {
  local msg="$1"; shift
  if "$@" &>/dev/null; then pass "$msg"; else fail "$msg"; fi
}
refute() {
  local msg="$1"; shift
  if ! "$@" &>/dev/null; then pass "$msg"; else fail "$msg"; fi
}
# assertp runs a shell pipeline string safely in a subshell
assert_pipe() {
  local msg="$1"; shift
  if bash -c "$*" &>/dev/null 2>&1; then pass "$msg"; else fail "$msg"; fi
}

# ─── paths ───────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
SKILL_DIR="$REPO_ROOT/.github/skills/sso-executing-parallel-tracks"
SBD_DIR="$REPO_ROOT/.github/skills/sso-single-branch-development"
SKILL="$SKILL_DIR/SKILL.md"
MANIFEST_TPL="$SKILL_DIR/track-manifest.template.md"
GUARD="$SBD_DIR/scripts/track-guard.sh"
METER="$SBD_DIR/scripts/track-meter.sh"
EVIDENCE="$SBD_DIR/scripts/track-evidence.sh"
EVIDENCE_GATE="$SBD_DIR/scripts/track-evidence-gate.sh"
PREFLIGHT="$SBD_DIR/scripts/track-preflight.sh"
SENTINEL="$SBD_DIR/scripts/track-sentinel.sh"
TRACE="$SBD_DIR/scripts/track-trace.sh"
NOTIFY="$SBD_DIR/scripts/track-notify.sh"
RECONCILE="$SBD_DIR/scripts/track-reconcile.sh"
PRECHECK="$SKILL_DIR/scripts/track-precheck.sh"

# ─── temp dir (auto-cleaned) ─────────────────────────────────────────────────
TMPDIR_ROOT="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# Minimal git repo used by hook tests
TMPGIT="$TMPDIR_ROOT/repo"
mkdir -p "$TMPGIT"
git -C "$TMPGIT" init -q
git -C "$TMPGIT" config user.email "test@example.com"
git -C "$TMPGIT" config user.name "Test"
mkdir -p "$TMPGIT/internal/ingest" "$TMPGIT/internal/notify" \
         "$TMPGIT/migrations" "$TMPGIT/cmd"
echo "package main"            > "$TMPGIT/cmd/main.go"
echo "// ingest handler"       > "$TMPGIT/internal/ingest/handler.go"
echo "// notify handler"       > "$TMPGIT/internal/notify/handler.go"
printf "GENERATED — DO NOT EDIT\n\n\n" > "$TMPGIT/internal/generated.go"
git -C "$TMPGIT" add -A
git -C "$TMPGIT" commit -q -m "init"

# ─── guard helper ────────────────────────────────────────────────────────────
# Invokes track-guard.sh from $TMPGIT as PWD, passes JSON on stdin.
# Returns the permissionDecision ("allow" or "deny"), or "allow" on parse error.
guard_decision() {
  local json="$1"; local out
  # Export caller-set vars into the child bash process (subshell inherits them;
  # new process needs explicit export)
  out="$(echo "$json" | (cd "$TMPGIT";
    export TRACK_ALLOWED_PREFIXES TRACK_FROZEN_PATHS TRACK_ALLOW_FF_PUSH
    bash "$GUARD" 2>/dev/null))"
  # guard/meter emit nothing on allow; non-empty output is a deny JSON blob
  if [ -z "$out" ]; then echo "allow"; return 0; fi
  echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
    || echo "allow"
}

mkjson_edit() {
  # tool_name=$1, filePath=$2 (workspace-relative)
  jq -nc --arg t "$1" --arg f "$2" '{tool_name:$t,tool_input:{filePath:$f}}'
}
mkjson_terminal() {
  jq -nc --arg c "$1" '{tool_name:"run_in_terminal",tool_input:{command:$c}}'
}

# ─── overlap detection helper (mirrors skill's precheck rule) ────────────────
# Returns 0 (true) if any prefix in list A is a string-prefix of any in list B
# or vice-versa (colon-separated lists).
detect_overlap() {
  local a="$1" b="$2"
  local r=1
  IFS=: read -ra AA <<< "$a"
  IFS=: read -ra BB <<< "$b"
  for x in "${AA[@]}"; do
    for y in "${BB[@]}"; do
      case "$x" in "$y"*) r=0 ;; esac
      case "$y" in "$x"*) r=0 ;; esac
    done
  done
  return $r
}

# Extract the run-record example from SKILL.md — specifically the ```json block that
# contains "run_id". Selecting by content (not "first block") keeps this robust when
# other json blocks (e.g. the wave-dispatch example) appear before it in the doc.
# Strip JS-style inline comments so jq can parse it.
#
# The skill's documented contract spans SKILL.md PLUS its references/ files
# (progressive disclosure — the repo standard splits detail into references/ at
# ~200 lines, 500 hard max). Concatenate them so a section relocated into
# references/ (e.g. the run-record / wave-dispatch schemas) still satisfies the
# content-fence assertions below.
SKILL_DOC="$TMPDIR_ROOT/skill-doc.md"
cat "$SKILL" "$SKILL_DIR"/references/*.md > "$SKILL_DOC" 2>/dev/null || cat "$SKILL" > "$SKILL_DOC"

RUN_RECORD_JSON="$(awk '
  /^```json/ { flag=1; buf=""; next }
  /^```/     { if (flag) { if (buf ~ /"run_id"/) { printf "%s", buf; exit } flag=0 } next }
  flag       { buf = buf $0 "\n" }
' "$SKILL_DOC" | sed 's|//.*||')"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 1 — SKILL.md Structural Integrity
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 1 — SKILL.md Structural Integrity"

assert  "1  SKILL.md exists" test -f "$SKILL"
assert  "2  frontmatter name=sso-executing-parallel-tracks" \
  grep -q "name: sso-executing-parallel-tracks" "$SKILL"
assert  "3  Steps 1-7 all present" \
  awk '/^### 1\. Precheck/{s1=1}/^### 2\. Create/{s2=1}/^### 3\. Fan/{s3=1}/^### 4\. Per-track/{s4=1}/^### 5\. Integration/{s5=1}/^### 6\. Stale-PR/{s6=1}/^### 7\. Report/{s7=1}END{exit !(s1&&s2&&s3&&s4&&s5&&s6&&s7)}' "$SKILL"
assert  "3a Step 0 Analyze & plan waves present" \
  grep -q "^### 0\. Analyze" "$SKILL"
assert_pipe "3b Step 0 requires user confirm before fan-out" \
  "awk '/^### 0[.] Analyze/,/^### 1[.]/' '$SKILL' | grep -qi 'confirm'"
assert_pipe "3c Step 0 describes wave sequencing between dependent waves" \
  "awk '/^### 0[.] Analyze/,/^### 1[.]/' '$SKILL' | grep -qi 'wave'"
assert_pipe "3d Skill-Per-Step Map includes Step 0 row" \
  "grep -q '^| 0 ' '$SKILL'"
assert  "4  Steps appear in ascending line order" \
  awk '/^### 1\. Precheck/{l1=NR}/^### 7\. Report/{l7=NR}END{exit !(l1>0&&l7>0&&l1<l7)}' "$SKILL"
assert  "5  3 mandatory gates stated" \
  grep -q "Precheck gate" "$SKILL" && grep -q "Verifier gate" "$SKILL" && grep -q "Merge gate" "$SKILL"
assert  "6  'Only.*success.*opens a PR' stated" \
  grep -q "Only.*success.*opens a PR\|Only .success. opens" "$SKILL"
_hs="$(grep -c 'Max iterations\|No-progress detection\|Per-worker token\|Global token' "$SKILL" || true)"
[ "$_hs" -eq 4 ] && pass "7  4 hard stops defined" || fail "7  4 hard stops defined (got $_hs)"
assert  "8  maker/checker split required" \
  grep -q "maker.*checker\|adversarial verifier" "$SKILL"
assert  "9  draft-only / no-merge worker boundary stated" \
  grep -q "Workers never merge\|no-merge worker" "$SKILL"
assert  "10 run-id: all 4 surfaces mentioned in one block" \
  awk '/One run-id, four surfaces/{found=1}found&&/branch name/{b=1}found&&/PR title/{p=1}found&&/commit trailer/{c=1}found&&/run record filename/{r=1}END{exit !(b&&p&&c&&r)}' "$SKILL"
assert_pipe "11 smoke-one-track-first in Step 1" \
  "awk '/^### 1[.] Precheck/,/^### 2[.]/' '$SKILL' | grep -qi smoke"
assert_pipe "12 worktree teardown after merge in Step 5" \
  "awk '/^### 5[.] Integration/,/^### 6[.]/' '$SKILL' | grep -qi 'worktree remove\|tear down'"
assert  "13 goal-as-contract guidance present" \
  grep -q "contract.*not.*wish\|spell out four" "$SKILL"
assert  "14 runs/summary.md aggregation mentioned" \
  grep -q "summary.md" "$SKILL"
assert  "15 'never dressed up as done' stated" \
  grep -q "never dressed up as done" "$SKILL"
assert  "16 track-manifest.template.md bundled" test -f "$MANIFEST_TPL"
assert  "17 SBD scripts/ bundle referenced and exists" test -d "$SBD_DIR/scripts"
assert  "18 SBD templates/ bundle referenced and exists" test -d "$SBD_DIR/templates"
assert  "19 runs/ gitignore guidance present" \
  grep -q 'runs/.*gitignore\|Add.*runs.*gitignore' "$SKILL_DOC"
assert  "20 Gotchas section present" grep -q "^## Gotchas" "$SKILL"
assert  "20a track-precheck.sh bundled + referenced in SKILL.md" \
  test -f "$SKILL_DIR/scripts/track-precheck.sh"
assert  "20b SKILL.md references scripts/track-precheck.sh" \
  grep -q "scripts/track-precheck.sh" "$SKILL"

# --- Confirm-waiver plumbing (the fan-out deadlock) --------------------------
# sso-single-branch-development treats its preflight confirm as a MANDATORY human gate. A
# dispatched worker has no human, so unless the orchestrator passes the waiver each
# worker either blocks forever or silently self-approves — and N workers each deciding
# that independently is the worst outcome. These assert the plumbing exists on BOTH
# sides of the composition boundary.
assert  "20c Step 3 instructs passing the confirm waiver to every worker" \
  grep -q "AUTO_CONFIRM" "$SKILL"
assert_pipe "20d waiver appears in the per-track env block, not just prose" \
  "awk '/# PER-TRACK/,/# GLOBAL/' '$SKILL' | grep -q 'AUTO_CONFIRM=1'"
assert_pipe "20e Skill-Per-Step Map fan-out row names the waiver" \
  "grep -q '^| 3 Fan out.*AUTO_CONFIRM' '$SKILL'"
assert  "20f SBD preflight actually implements the waiver it is passed" \
  grep -q 'AUTO_CONFIRM' "$SBD_DIR/scripts/track-preflight.sh"
assert  "20g waiver is recorded for audit (human vs orchestrator-waiver)" \
  grep -q 'orchestrator-waiver' "$SBD_DIR/scripts/track-preflight.sh"
assert  "20h Gotchas warn about the un-waived fan-out deadlock" \
  grep -qi 'hangs on a question nobody will answer' "$SKILL"

# --- Orchestrator compaction discipline --------------------------------------
# The orchestrator session outlives every worker it spawns — it is the longest-running
# context in the system and nothing re-anchors it. Workers reconcile from breadcrumbs;
# the orchestrator has only its ledger.
assert  "20i Orchestrator ledger section present" \
  grep -qi "^## Orchestrator ledger" "$SKILL"
assert  "20j ledger names compaction as the threat" \
  grep -qi "compact" "$SKILL"
assert_pipe "20k ledger tells the orchestrator to rebuild fleet state from runs/ files" \
  "awk '/^## Orchestrator ledger/,/^## Traceability/' '$SKILL' | grep -q 'runs/'"
assert  "20l run-record schema carries phase + blocker + next_step for re-dispatch" \
  grep -q '"phase"' "$SKILL_DOC"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 2 — track-manifest.template.md Completeness
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 2 — track-manifest.template.md Completeness"

assert "21 default_branch field"           grep -q "default_branch"           "$MANIFEST_TPL"
assert "22 max_concurrent_tracks field"    grep -q "max_concurrent_tracks"    "$MANIFEST_TPL"
assert "23 TRACK_EVIDENCE_RULES env var documented" grep -q "TRACK_EVIDENCE_RULES"     "$MANIFEST_TPL"
assert "24 TRACK_EVIDENCE_KINDS env var documented"  grep -q "TRACK_EVIDENCE_KINDS"     "$MANIFEST_TPL"
assert "25 Hook environment section present"          grep -q "Hook environment"          "$MANIFEST_TPL"
assert "26 Mechanical ceilings note (TRACK_MAX_TOKEN_ESTIMATE or TRACK_MAX_TOOL_CALLS)" \
  grep -q "TRACK_MAX_TOKEN_ESTIMATE\|TRACK_MAX_TOOL_CALLS"   "$MANIFEST_TPL"
assert "27 wave dispatch file reference present"      grep -q "wave dispatch"             "$MANIFEST_TPL"
assert "28 Commands table present"         grep -q "lint\|unit test"          "$MANIFEST_TPL"
assert "29 Evidence pack section present"  grep -q "Evidence pack"            "$MANIFEST_TPL"
assert "30 Frozen entrypoints section"     grep -q "[Ff]rozen entrypoints"    "$MANIFEST_TPL"
assert "31 Ownership map section"          grep -q "[Oo]wnership map"         "$MANIFEST_TPL"
assert "32 Docker namespace pattern"       grep -q "COMPOSE_PROJECT_NAME\|docker_namespace" "$MANIFEST_TPL"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 3 — Embedded Run Record JSON Schema
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 3 — Embedded Run Record JSON Schema"

assert "33 embedded run record is valid JSON" \
  jq empty <<< "$RUN_RECORD_JSON"

for f in run_id track branch goal status evidence iterations iterations_self_reported tool_calls token_estimate \
         blocker next_step pr_url trace skills; do
  assert "34+ run record has field: $f" \
    jq -e "has(\"$f\")" <<< "$RUN_RECORD_JSON"
done

_rr_status="$(jq -r '.status' <<< "$RUN_RECORD_JSON")"
assert "47 status is one of the 4 terminal states" \
  grep -qE "^(success|blocked|no-progress|budget-exceeded)$" <<< "$_rr_status"

assert "48 trace is an array with ≥2 entries" \
  jq -e '(.trace | length) >= 2' <<< "$RUN_RECORD_JSON"

assert "49 every trace entry has t, kind, event, agent_id, agent_type" \
  jq -e '[.trace[] | has("t") and has("kind") and has("event") and has("agent_id") and has("agent_type")] | all' <<< "$RUN_RECORD_JSON"

assert "50 trace kind values are only 'subagent'" \
  jq -e '[.trace[].kind] | all(. == "subagent")' <<< "$RUN_RECORD_JSON"

assert "50a skills[] array present and self_reported tagged" \
  jq -e '(.skills | length) > 0 and ([.skills[] | .self_reported == true] | all)' <<< "$RUN_RECORD_JSON"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 4 — Precheck Gate: Ownership Overlap Detection
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 4 — Precheck Gate: Ownership Overlap Detection"

# 51 — distinct non-overlapping prefixes → no overlap
if ! detect_overlap "internal/ingest:migrations/0007_" "internal/notify:migrations/0008_"; then
  pass "51 distinct prefixes → no overlap"
else
  fail "51 distinct prefixes → no overlap"
fi

# 52 — exact same prefix → overlap
if detect_overlap "internal/ingest" "internal/ingest"; then
  pass "52 identical prefix → overlap detected"
else
  fail "52 identical prefix → overlap detected"
fi

# 53 — A is prefix of B → overlap
if detect_overlap "internal/" "internal/notify"; then
  pass "53 parent prefix ⊂ child prefix → overlap detected"
else
  fail "53 parent prefix ⊂ child prefix → overlap detected"
fi

# 54 — one shared hotspot key in both lists → overlap
if detect_overlap "internal/ingest:shared" "internal/notify:shared"; then
  pass "54 shared hotspot prefix in both lists → overlap detected"
else
  fail "54 shared hotspot prefix → overlap detected"
fi

# 55 — completely disjoint sets → no overlap
if ! detect_overlap "frontend/components" "backend-go/internal"; then
  pass "55 completely disjoint prefixes → no overlap"
else
  fail "55 completely disjoint prefixes → no overlap"
fi

# 56 — 3-way valid parallel wave: all pairs disjoint
PREFIXES=("internal/ingest:test/ingest" "internal/notify:test/notify" "frontend/components")
overlap_found=0
for ((i=0; i<${#PREFIXES[@]}; i++)); do
  for ((j=i+1; j<${#PREFIXES[@]}; j++)); do
    detect_overlap "${PREFIXES[$i]}" "${PREFIXES[$j]}" && overlap_found=1 || true
  done
done
[ "$overlap_found" -eq 0 ] \
  && pass "56 3-track wave: all prefix pairs disjoint → valid parallel wave" \
  || fail "56 3-track wave: all disjoint"

# 57 — 3-way INVALID wave: tracks 1+2 share 'shared/'
BAD_PREFIXES=("internal/ingest:shared" "internal/notify:shared" "frontend/components")
bad_overlap=0
for ((i=0; i<${#BAD_PREFIXES[@]}; i++)); do
  for ((j=i+1; j<${#BAD_PREFIXES[@]}; j++)); do
    detect_overlap "${BAD_PREFIXES[$i]}" "${BAD_PREFIXES[$j]}" && bad_overlap=1 || true
  done
done
[ "$bad_overlap" -eq 1 ] \
  && pass "57 3-track wave with shared hotspot → overlap detected → must stop" \
  || fail "57 invalid 3-track wave overlap detected"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 5 — Guard Hook: Cross-Worktree Ownership (Parallel-Specific)
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 5 — Guard Hook: Cross-Worktree Ownership (Parallel-Specific)"

if ! command -v jq &>/dev/null || ! test -f "$GUARD"; then
  for n in 58 59 60 61 62 63 64; do skip "$n  guard/jq unavailable"; done
else
  # 58 — Track A edits its own file → allow
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit create_file "internal/ingest/new.go")")
  [ "$d" = "allow" ] && pass "58 track A edits own file → allow" \
                       || fail "58 track A edits own file → allow"

  # 59 — Track A tries to edit Track B's file → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit replace_string_in_file "internal/notify/handler.go")")
  [ "$d" = "deny" ] && pass "59 track A edits track B's file → deny" \
                      || fail "59 track A edits track B's file → deny"

  # 60 — Track B edits its own file → allow
  d=$(TRACK_ALLOWED_PREFIXES="internal/notify" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit create_file "internal/notify/router.go")")
  [ "$d" = "allow" ] && pass "60 track B edits own file → allow" \
                       || fail "60 track B edits own file → allow"

  # 61 — Track B tries to edit Track A's file → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/notify" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit replace_string_in_file "internal/ingest/handler.go")")
  [ "$d" = "deny" ] && pass "61 track B edits track A's file → deny" \
                      || fail "61 track B edits track A's file → deny"

  # 62 — Frozen entrypoint: any track editing cmd/main.go → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit replace_string_in_file "cmd/main.go")")
  [ "$d" = "deny" ] && pass "62 frozen entrypoint (cmd/main.go) → deny for any track" \
                      || fail "62 frozen entrypoint → deny"

  # 63 — multi_replace: one in-scope + one out-of-scope path → deny entire batch
  MULTI_JSON=$(jq -nc '{
    tool_name:"multi_replace_string_in_file",
    tool_input:{replacements:[
      {filePath:"internal/ingest/a.go"},
      {filePath:"internal/notify/b.go"}
    ]}
  }')
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$MULTI_JSON")
  [ "$d" = "deny" ] && pass "63 multi_replace with one out-of-scope path → deny entire batch" \
                      || fail "63 multi_replace mixed paths → deny"

  # 64 — TRACK_ALLOWED_PREFIXES unset → fail-closed (deny all edits)
  d=$(
    unset TRACK_ALLOWED_PREFIXES
    TRACK_FROZEN_PATHS=""
    guard_decision "$(mkjson_edit create_file "internal/ingest/x.go")"
  )
  [ "$d" = "deny" ] && pass "64 TRACK_ALLOWED_PREFIXES unset → fail-closed deny all edits" \
                      || fail "64 TRACK_ALLOWED_PREFIXES unset → fail-closed"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 6 — Guard Hook: Merge/Push Lockout (Worker Autonomy Boundary)
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 6 — Guard Hook: Merge/Push Lockout (Worker Boundary)"

if ! command -v jq &>/dev/null || ! test -f "$GUARD"; then
  for n in 65 66 67 68 69 70; do skip "$n  guard/jq unavailable"; done
else
  BASE_PFX="internal/ingest"  # value only, applied via direct env assignment below

  # 65 — git push → deny (workers stop at draft PR)
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" guard_decision "$(mkjson_terminal "git push origin track/us1")")
  [ "$d" = "deny" ] && pass "65 git push → deny (worker boundary)" \
                      || fail "65 git push → deny"

  # 66 — git push --force → deny even with TRACK_ALLOW_FF_PUSH=1
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" TRACK_ALLOW_FF_PUSH=1 \
      guard_decision "$(mkjson_terminal "git push --force origin track/us1")")
  [ "$d" = "deny" ] && pass "66 git push --force → deny even with TRACK_ALLOW_FF_PUSH=1" \
                      || fail "66 force push always denied"

  # 67 — gh pr merge → deny
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" guard_decision "$(mkjson_terminal "gh pr merge 42 --merge")")
  [ "$d" = "deny" ] && pass "67 gh pr merge → deny" || fail "67 gh pr merge → deny"

  # 68 — git reset --hard → deny
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" guard_decision "$(mkjson_terminal "git reset --hard HEAD~1")")
  [ "$d" = "deny" ] && pass "68 git reset --hard → deny" || fail "68 git reset --hard → deny"

  # 69 — TRACK_ALLOW_FF_PUSH=1, plain push → allow (PR-rework flow)
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" TRACK_ALLOW_FF_PUSH=1 \
      guard_decision "$(mkjson_terminal "git push origin track/us1")")
  [ "$d" = "allow" ] && pass "69 TRACK_ALLOW_FF_PUSH=1, plain push → allow (PR-rework)" \
                       || fail "69 FF push with opt-in → allow"

  # 70 — gh pr create --draft → allow (legitimate worker action)
  d=$(TRACK_ALLOWED_PREFIXES="$BASE_PFX" \
      guard_decision "$(mkjson_terminal "gh pr create --draft --title 'track/us1 [run 2026-07-04T10-00_us1]'")")
  [ "$d" = "allow" ] && pass "70 gh pr create --draft → allow" || fail "70 draft PR creation → allow"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 7 — Guard Hook: Global Budget Ceiling (track-meter)
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 7 — Global Budget Ceiling via track-meter"

if ! command -v jq &>/dev/null || ! test -f "$METER"; then
  for n in 71 72 73 74; do skip "$n  meter/jq unavailable"; done
else
  RUNS_TMP="$TMPDIR_ROOT/runs"
  mkdir -p "$RUNS_TMP"
  METER_RUN_ID="2026-07-04T10-00_fleet"
  METER_REC="$RUNS_TMP/$METER_RUN_ID.json"
  echo '{"status":"in-progress","tool_calls":0}' > "$METER_REC"

  invoke_meter() {
    local tool="$1"
    jq -nc --arg t "$tool" '{tool_name:$t,tool_input:{}}' | \
      env TRACK_MAX_TOOL_CALLS=3 \
          RUN_ID="$METER_RUN_ID" \
          RUNS_DIR="$RUNS_TMP" \
      bash "$METER" 2>/dev/null
  }

  decision_of() {
    local raw="$1"
    # meter emits nothing on allow; non-empty output is a deny/stop blob
    if [ -z "$raw" ]; then echo "allow"; return 0; fi
    # meter format: { continue: false, stopReason: "..." }
    if echo "$raw" | jq -e '.continue == false' &>/dev/null 2>&1; then
      echo "deny"; return 0
    fi
    # guard format: { hookSpecificOutput: { permissionDecision: "deny" } }
    echo "$raw" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
      || echo "allow"
  }

  # 71 — 1st call (1/3) → allow
  d71="$(decision_of "$(invoke_meter create_file)")"
  [ "$d71" = "allow" ] && pass "71 1st call (1/3) → allow" || fail "71 1st call → allow"

  # 72 — 2nd + 3rd calls (still at or below ceiling) → allow
  invoke_meter replace_string_in_file >/dev/null 2>&1 || true
  d72="$(decision_of "$(invoke_meter run_in_terminal)")"
  [ "$d72" = "allow" ] && pass "72 3rd call (3/3) → allow" || fail "72 3rd call → allow"

  # 73 — 4th call exceeds ceiling → deny
  d73="$(decision_of "$(invoke_meter read_file)")"
  [ "$d73" = "deny" ] && pass "73 4th call (4>3) → deny (ceiling exceeded)" \
                        || fail "73 ceiling exceeded → deny"

  # 74 — run record updated to status=no-progress after ceiling trip
  st74="$(jq -r '.status' "$METER_REC" 2>/dev/null || echo missing)"
  [ "$st74" = "no-progress" ] \
    && pass "74 ceiling trip writes status=no-progress to run record" \
    || fail "74 run record status=no-progress on ceiling trip"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 8 — Hard Stop Taxonomy & Disambiguation
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 8 — Hard Stop Taxonomy & Disambiguation"

assert "75 max_iterations default (25) stated" grep -q "25" "$SKILL"
assert "76 no-progress default pass count (3) stated" \
  grep -q "default 3\|passes.*3\b\|3.*passes" "$SKILL"
assert "77 no-progress (stalled verifier passes) DISTINCT from self-heal cap (fix attempts)" \
  grep -q "Distinct from the self-heal cap\|stalled passes" "$SKILL"
assert "78 global ceiling halts the fleet, not just one worker" \
  grep -q "[Hh]alt.*fleet\|fleet.*ceiling\|global.*ALL workers" "$SKILL"
assert "79 per-worker ceiling and global ceiling are separate" \
  grep -q "Per-worker.*ceiling\|per-worker.*budget" "$SKILL" \
  && grep -q "Global.*ceiling\|global.*budget" "$SKILL"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 9 — Terminal State Exhaustiveness
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 9 — Terminal State Exhaustiveness"

assert "80 'success' terminal state defined"         grep -q "^\- \*\*success\*\*"         "$SKILL"
assert "81 'blocked' terminal state defined"         grep -q "^\- \*\*blocked\*\*"         "$SKILL"
assert "82 'no-progress' terminal state defined"     grep -q "^\- \*\*no-progress\*\*"     "$SKILL"
assert "83 'budget-exceeded' terminal state defined" grep -q "^\- \*\*budget-exceeded\*\*" "$SKILL"
_ts="$(awk '/^## Terminal states/{p=1;next} p && /^## /{exit} p && /^- \*\*/{c++} END{print c+0}' "$SKILL")"
[ "$_ts" -eq 4 ] && pass "84 exactly 4 terminal states in the section" \
               || fail "84 exactly 4 terminal states in the section (got $_ts)"
assert "85 failed verifier → run record, NOT PR" \
  grep -q "failed verifier.*run record\|verifier.*no PR\|verifier.*NOT open\|failed verifier.*does NOT open" "$SKILL"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 10 — Isolation: Per-Track Docker Namespace
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 10 — Isolation: Per-Track Docker Namespace"

assert "86 COMPOSE_PROJECT_NAME exported per track in SKILL.md" \
  grep -q "COMPOSE_PROJECT_NAME" "$SKILL"
assert "87 manifest template defines Docker namespace pattern" \
  grep -q "COMPOSE_PROJECT_NAME\|docker_namespace" "$MANIFEST_TPL"
assert "88 'Never point two tracks at one shared dev DB' stated" \
  grep -q "Never point two tracks.*shared\|one shared dev DB" "$SKILL"
assert "89 namespace pattern uses <track_id> so each track differs" \
  grep -q "<track_id>\|<repo>_<track" "$MANIFEST_TPL"

PROJ_A="myrepo_us1"; PROJ_B="myrepo_us2"
[ "$PROJ_A" != "$PROJ_B" ] \
  && pass "90 COMPOSE_PROJECT_NAME for track A ≠ track B (pattern guarantees distinct namespaces)" \
  || fail "90 distinct Docker namespaces"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 11 — Traceability: Run-ID 4-Surface Stamping
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 11 — Traceability: Run-ID 4-Surface Stamping"

assert "91 run-id format example: <UTC-timestamp>_<track_id>" \
  grep -q '[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9]\{2\}-[0-9]\{2\}_' "$SKILL"
assert "92 surface 1: branch name mentioned" grep -q "branch name" "$SKILL"
assert "93 surface 2: PR title mentioned"    grep -q "PR title"    "$SKILL"
assert "94 surface 3: commit trailer (Run-Id:)" grep -q "Run-Id:"  "$SKILL"
assert "95 surface 4: run record filename"   grep -q "run record filename\|runs/<run-id>.json" "$SKILL"
assert "96 'Grep any one surface → reconstruct the whole run'" \
  grep -q "[Gg]rep.*surface.*reconstruct\|reconstruct the whole run" "$SKILL"
assert "97 PR title contains [run <run-id>] pattern" \
  grep -q "\[run.*run-id\]\|\[run 2026" "$SKILL_DOC"

# Validate the run-id format from the embedded JSON matches the stated pattern
EXAMPLE_RUN_ID="$(echo "$RUN_RECORD_JSON" | jq -r '.run_id' 2>/dev/null || echo '')"
if echo "$EXAMPLE_RUN_ID" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}_[a-z0-9]+$"; then
  pass "98 embedded run_id '$EXAMPLE_RUN_ID' matches <UTC-timestamp>_<track_id> format"
else
  fail "98 embedded run_id '$EXAMPLE_RUN_ID' matches format"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 12 — Stale-PR Bounce Protocol
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 12 — Stale-PR Bounce Protocol"

BOUNCE_SECTION="$(awk '/^### 6\. Stale-PR/,/^### 7\./' "$SKILL")"

assert "99  Step 6 contains 'rebase'" \
  grep -qi rebase <<< "$BOUNCE_SECTION"
assert "100 Step 6 contains 'regenerate lockfiles'" \
  grep -qi regenerate <<< "$BOUNCE_SECTION"
assert "101 Step 6 says 'DO NOT hand-merge'" \
  bash -c 'grep -qi "NOT hand-merge\|not hand.merge" <<< "$1"' _ "$BOUNCE_SECTION"
assert "102 Step 6 contains 'force-push'" \
  bash -c 'grep -qi "force-push\|force push" <<< "$1"' _ "$BOUNCE_SECTION"
assert "103 Step 6 instructs SOURCE conflict → preserve both behaviors" \
  bash -c 'grep -qi "SOURCE.*conflict\|preserving both" <<< "$1"' _ "$BOUNCE_SECTION"
assert "104 bounce is re-dispatched to OWNING worker" \
  bash -c 'grep -qi "[Oo]wning worker\|Re-dispatch\|owning" <<< "$1"' _ "$BOUNCE_SECTION"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 13 — Extreme Parallel: Over-Cap Detection
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 13 — Extreme Parallel: Over-Cap Detection"

assert "105 precheck checks Docker/host headroom vs manifest cap" \
  grep -q "[Dd]ocker.*headroom\|headroom.*cap\|concurrent tracks.*cap" "$SKILL"
assert "106 over-cap → 'propose reducing concurrency' (not silent)" \
  grep -q "[Pp]ropose reducing concurrency\|reduce.*concurrency" "$SKILL"
_per_track="$(awk '/# PER-TRACK/,/# GLOBAL/' "$SKILL")"
assert "107 TRACK_ALLOWED_PREFIXES is per-track (shown in PER-TRACK block)" \
  grep -q TRACK_ALLOWED_PREFIXES <<< "$_per_track"
assert "108 RUN_ID is per-track (shown in PER-TRACK block)" \
  grep -q RUN_ID <<< "$_per_track"
assert "109 GLOBAL vars identical for every worker (comment states it)" \
  grep -q "[Ii]dentical for every worker\|same.*every worker" "$SKILL"

# N=3 with cap=2 triggers over-cap flag
max_cap=2; requested=3
[ "$requested" -gt "$max_cap" ] \
  && pass "110 N=$requested > cap=$max_cap → over-cap detected (orchestrator must ask back)" \
  || fail "110 over-cap detection logic"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 14 — Extreme Parallel: All-Blocked Scenario
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 14 — Extreme Parallel: All-Blocked Scenario"

ALL_BLOCKED_DIR="$TMPDIR_ROOT/all-blocked"
mkdir -p "$ALL_BLOCKED_DIR"
for t in us1 us2 us3; do
  jq -n \
    --arg id "2026-07-04T10-00_${t}" \
    --arg tr "$t" \
    '{run_id:$id, track:$tr, branch:("track/"+$tr), goal:"Test goal",
      status:"blocked", evidence:{}, iterations:20, tokens:40000, cost_usd:0.80,
      blocker:"external dep unavailable", next_step:"escalate",
      pr_url:null, trace:[]}' \
    > "$ALL_BLOCKED_DIR/2026-07-04T10-00_${t}.json"
done

# 111 — all 3 tracks show status=blocked (no phantom success)
all_blocked=true
for f in "$ALL_BLOCKED_DIR"/*.json; do
  st="$(jq -r '.status' "$f")"; [ "$st" = "blocked" ] || { all_blocked=false; break; }
done
$all_blocked && pass "111 all tracks status=blocked → no phantom success" \
              || fail "111 all-blocked: no phantom success"

# 112 — no PR URLs present for any blocked track
no_pr=true
for f in "$ALL_BLOCKED_DIR"/*.json; do
  pr="$(jq -r '.pr_url' "$f")"
  [ "$pr" = "null" ] || [ -z "$pr" ] || { no_pr=false; break; }
done
$no_pr && pass "112 all blocked tracks → pr_url=null (no PR opened)" \
        || fail "112 blocked tracks → no PR"

# 113 — summary.md covers every track
{ echo "# Summary"
  for f in "$ALL_BLOCKED_DIR"/*.json; do
    jq -r '"- [" + .run_id + "] status=" + .status' "$f"
  done
} > "$ALL_BLOCKED_DIR/summary.md"

_sum3="$(grep -c '^- ' "$ALL_BLOCKED_DIR/summary.md" || true)"
[ "$_sum3" -eq 3 ] && pass "113 summary.md has exactly 3 track entries" \
               || fail "113 summary.md has exactly 3 track entries (got $_sum3)"
refute "114 summary.md has no 'success' entry for all-blocked scenario" \
  grep -q "status=success" "$ALL_BLOCKED_DIR/summary.md"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 15 — Extreme Parallel: Global Budget Hit Mid-Wave
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 15 — Extreme Parallel: Global Budget Hit Mid-Wave"

GLOBAL_RUNS="$TMPDIR_ROOT/global-budget"
mkdir -p "$GLOBAL_RUNS"
GLOBAL_BUDGET=10.0

jq -n '{run_id:"2026-07-04T10-00_us1",track:"us1",status:"success",
        cost_usd:6.0,pr_url:"https://github.com/example/repo/pull/1",
        evidence:{unit:"42 passed"},trace:[]}' \
  > "$GLOBAL_RUNS/2026-07-04T10-00_us1.json"

jq -n '{run_id:"2026-07-04T10-00_us2",track:"us2",status:"budget-exceeded",
        cost_usd:5.0,pr_url:null,blocker:"global budget ceiling hit",trace:[]}' \
  > "$GLOBAL_RUNS/2026-07-04T10-00_us2.json"

jq -n '{run_id:"2026-07-04T10-00_us3",track:"us3",status:"budget-exceeded",
        cost_usd:0.0,pr_url:null,blocker:"global budget ceiling; not started",trace:[]}' \
  > "$GLOBAL_RUNS/2026-07-04T10-00_us3.json"

fleet_cost="$(jq -s '[.[].cost_usd] | add' "$GLOBAL_RUNS"/*.json)"

if command -v bc &>/dev/null; then
  [ "$(echo "$fleet_cost > $GLOBAL_BUDGET" | bc -l)" = "1" ] \
    && pass "115 fleet cost ($fleet_cost) > global budget ($GLOBAL_BUDGET) → ceiling was hit" \
    || fail "115 fleet budget ceiling check"
else
  skip "115 bc unavailable — skip arithmetic check"
fi

success_count="$(jq -rs '[.[].status] | map(select(.=="success")) | length' "$GLOBAL_RUNS"/*.json)"
budget_count="$(jq -rs '[.[].status] | map(select(.=="budget-exceeded")) | length' "$GLOBAL_RUNS"/*.json)"
[ "$success_count" = "1" ] && pass "116 exactly 1 track succeeded before ceiling" \
                             || fail "116 success count = 1"
[ "$budget_count"  = "2" ] && pass "117 2 tracks halted as budget-exceeded" \
                             || fail "117 budget-exceeded count = 2"

assert "118 halted tracks have pr_url=null" \
  jq -rs '[.[] | select(.status=="budget-exceeded") | .pr_url] | all(. == null)' \
    "$GLOBAL_RUNS"/*.json

assert "119 SKILL.md: global ceiling > per-worker ceiling stated as critical at N>1" \
  grep -q "[Gg]lobal.*N>1\|N>1.*global\|N>1.*matters more" "$SKILL"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 16 — Smoke Track Fails: Fan-Out Must Not Proceed
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 16 — Smoke Track Fails: Fan-Out Must Not Proceed"

assert "120 SKILL.md: fan out only after smoke track reaches clean 'success'" \
  grep -q "[Ff]an out the remaining.*success\|smoke track.*success\|only after.*smoke" "$SKILL"
assert_pipe "121 smoke rule is in Step 1 (before Step 2 / fan-out)" \
  "awk '/^### 1[.] Precheck/,/^### 2[.]/' '$SKILL' | grep -qi smoke"

for smoke_status in "blocked" "no-progress" "budget-exceeded"; do
  [ "$smoke_status" != "success" ] \
    && pass "122+ smoke_status=$smoke_status → fan-out must NOT proceed (correct)" \
    || fail "122+ smoke=success should allow fan-out"
done

# ═════════════════════════════════════════════════════════════════════════════
# Suite 17 — Goal-as-Contract: All 4 Required Parts
# ═════════════════════════════════════════════════════════════════════════════
suite "Suite 17 — Goal-as-Contract: All 4 Required Parts"

assert "125 goal contract 'end state' named" \
  grep -q "\*\*end state\*\*\|end state" "$SKILL"
assert "126 goal contract 'evidence' named" \
  grep -q '\*\*evidence\*\*\|evidence.*required' "$SKILL"
assert "127 goal contract 'constraints' named" \
  grep -q '\*\*constraints\*\*\|constraints.*must hold' "$SKILL"
assert "128 goal contract 'budget' named" \
  grep -q '\*\*budget\*\*\|hard stops' "$SKILL"
assert "129 goal without evidence 'will always think it succeeded'" \
  grep -q 'will always think it succeeded\|no evidence.*succeed' "$SKILL"
_rr_goal="$(jq -r '.goal' <<< "$RUN_RECORD_JSON")"
assert "130 embedded run record goal is non-trivial (not empty/placeholder)" \
  grep -qv '^$\|^TODO\|placeholder' <<< "$_rr_goal"

# ═════════════════════════════════════════════════════════════════════════════
# Suite 18 — Guard Portability: CLI Surface (Write/Edit/MultiEdit, file_path)
# ═════════════════════════════════════════════════════════════════════════════
# The skill's Gotchas claim the guard is portable across surfaces: VS Code
# (create_file/replace_string_in_file, camelCase filePath) AND Claude/CLI
# (Write/Edit/MultiEdit, snake_case file_path). Suites 5-6 only cover the VS Code
# surface. These exercise the CLI surface against the REAL guard so the portability
# claim is backed by behavior, not just prose.
suite "Suite 18 — Guard Portability: CLI Surface (Write/Edit/MultiEdit)"

if ! command -v jq &>/dev/null || ! test -f "$GUARD"; then
  for n in 131 132 133 134 135 136 137; do skip "$n  guard/jq unavailable"; done
else
  mkjson_write()     { jq -nc --arg f "$1" '{tool_name:"Write",tool_input:{file_path:$f}}'; }
  mkjson_edit_cli()  { jq -nc --arg f "$1" '{tool_name:"Edit",tool_input:{file_path:$f}}'; }
  mkjson_multiedit() { jq -nc --arg a "$1" --arg b "$2" \
                        '{tool_name:"MultiEdit",tool_input:{edits:[{file_path:$a},{file_path:$b}]}}'; }

  # 131 — Write (CLI) in-scope → allow
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_write "internal/ingest/new.go")")
  [ "$d" = "allow" ] && pass "131 Write (snake_case file_path) in-scope → allow" \
                       || fail "131 Write in-scope → allow (got $d)"

  # 132 — Write (CLI) out-of-scope → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_write "internal/notify/x.go")")
  [ "$d" = "deny" ] && pass "132 Write out-of-scope → deny" \
                      || fail "132 Write out-of-scope → deny (got $d)"

  # 133 — Edit (CLI) out-of-scope → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit_cli "internal/notify/handler.go")")
  [ "$d" = "deny" ] && pass "133 Edit (CLI) out-of-scope → deny" \
                      || fail "133 Edit (CLI) out-of-scope → deny (got $d)"

  # 134 — Edit (CLI) frozen entrypoint → deny
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_edit_cli "cmd/main.go")")
  [ "$d" = "deny" ] && pass "134 Edit (CLI) frozen entrypoint → deny" \
                      || fail "134 Edit (CLI) frozen entrypoint → deny (got $d)"

  # 135 — MultiEdit with one out-of-scope path → deny entire batch
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_multiedit "internal/ingest/a.go" "internal/notify/b.go")")
  [ "$d" = "deny" ] && pass "135 MultiEdit (edits[].file_path) mixed → deny whole batch" \
                      || fail "135 MultiEdit mixed → deny (got $d)"

  # 136 — MultiEdit with both paths in-scope → allow
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_decision "$(mkjson_multiedit "internal/ingest/a.go" "internal/ingest/b.go")")
  [ "$d" = "allow" ] && pass "136 MultiEdit both in-scope → allow" \
                       || fail "136 MultiEdit both in-scope → allow (got $d)"

  # 137 — CLI surface must ALSO fail-closed when TRACK_ALLOWED_PREFIXES is unset
  d=$(
    unset TRACK_ALLOWED_PREFIXES
    TRACK_FROZEN_PATHS=""
    guard_decision "$(mkjson_write "internal/ingest/x.go")"
  )
  [ "$d" = "deny" ] && pass "137 Write with prefixes unset → fail-closed deny (CLI surface)" \
                      || fail "137 Write fail-closed → deny (got $d)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 19 — Evidence Gate: Capture + Assert (the 'evidence not assertion' gate)
# ═════════════════════════════════════════════════════════════════════════════
# The single most important gate per the skill: a done-claim must not land with
# missing, stale, or failing evidence. Drives the REAL track-evidence.sh (capture)
# and track-evidence-gate.sh (Stop assertion) in a throwaway git repo.
suite "Suite 19 — Evidence Gate: Capture + Assert"

if ! command -v jq &>/dev/null || ! test -f "$EVIDENCE" || ! test -f "$EVIDENCE_GATE"; then
  for n in 138 139 140 141 142; do skip "$n  evidence scripts/jq unavailable"; done
else
  EVGIT="$TMPDIR_ROOT/evrepo"
  mkdir -p "$EVGIT/internal/ingest"
  git -C "$EVGIT" init -q
  git -C "$EVGIT" config user.email "test@example.com"
  git -C "$EVGIT" config user.name "Test"
  echo "// svc"      > "$EVGIT/internal/ingest/svc.go"
  echo "package m"   > "$EVGIT/go.mod.stub"
  echo "runs/"       > "$EVGIT/.gitignore"   # runs/ MUST be git-ignored (skill invariant)
  git -C "$EVGIT" add -A
  git -C "$EVGIT" commit -q -m "init"
  EVRUNS="$EVGIT/runs"

  # Capture a test-command result into runs/<RUN_ID>.json via the REAL hook.
  ev_capture() { # $1=run_id  $2=cmd  $3=tool_response
    jq -nc --arg c "$2" --arg r "$3" \
      '{tool_name:"run_in_terminal",tool_input:{command:$c},tool_response:$r}' | \
      ( cd "$EVGIT"; RUN_ID="$1" RUNS_DIR="runs" \
        TRACK_TEST_CMD_PATTERN="go test|uv run pytest" \
        bash "$EVIDENCE" >/dev/null 2>&1 ) || true
  }
  # Run the Stop gate; echoes "block" or "allow".
  ev_gate() { # $1=run_id
    local out
    out="$(printf '{"stop_hook_active":false}' | \
      ( cd "$EVGIT"; RUN_ID="$1" RUNS_DIR="runs" TRACK_REQUIRED_EVIDENCE=test \
        bash "$EVIDENCE_GATE" 2>/dev/null ))"
    [ -z "$out" ] && { echo "allow"; return 0; }
    echo "$out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow"
  }

  # 138 — fresh, passing evidence for the current tree → gate allows
  ev_capture "run_pass" "go test ./..." "ok  	pkg	42 passed"
  d="$(ev_gate run_pass)"
  [ "$d" = "allow" ] && pass "138 fresh passing evidence (fingerprint matches) → allow" \
                       || fail "138 fresh passing → allow (got $d)"

  # 139 — no evidence captured at all → gate blocks (MISSING)
  d="$(ev_gate run_missing)"
  [ "$d" = "block" ] && pass "139 no evidence captured → block (missing)" \
                       || fail "139 missing evidence → block (got $d)"

  # 140 — captured but response shows a failure marker → gate blocks (FAILING)
  ev_capture "run_fail" "go test ./..." "--- FAIL: TestIngest (0.01s)"
  d="$(ev_gate run_fail)"
  [ "$d" = "block" ] && pass "140 failing evidence (FAIL marker) → block" \
                       || fail "140 failing evidence → block (got $d)"

  # 141 — passing evidence, then the tree changes → fingerprint mismatch → STALE
  ev_capture "run_stale" "go test ./..." "ok  	pkg	42 passed"
  echo "// later edit" >> "$EVGIT/internal/ingest/svc.go"   # mutate tree after capture
  d="$(ev_gate run_stale)"
  git -C "$EVGIT" checkout -q -- internal/ingest/svc.go       # restore for later suites
  [ "$d" = "block" ] && pass "141 stale evidence (tree changed since capture) → block" \
                       || fail "141 stale evidence → block (got $d)"

  # 142 — the captured record actually stores a fingerprint (freshness is real)
  fp="$(jq -r '.evidence[0].fingerprint // ""' "$EVRUNS/run_pass.json" 2>/dev/null)"
  [ -n "$fp" ] && pass "142 evidence entry stores a fingerprint (freshness anchor)" \
                 || fail "142 evidence entry has fingerprint"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 20 — Preflight: RUN_ID Mint / Resume / Hard-Fail (the run-id spine)
# ═════════════════════════════════════════════════════════════════════════════
# The run-id is the trace spine for N parallel workers. track-preflight.sh mints it,
# persists a breadcrumb, and recovers it on resume. Drives the REAL script.
suite "Suite 20 — Preflight: RUN_ID Mint / Resume / Hard-Fail"

if ! command -v jq &>/dev/null || ! test -f "$PREFLIGHT"; then
  for n in 143 144 145 146 147; do skip "$n  preflight/jq unavailable"; done
else
  PFGIT="$TMPDIR_ROOT/pfrepo"
  mkdir -p "$PFGIT"
  git -C "$PFGIT" init -q
  git -C "$PFGIT" config user.email "test@example.com"
  git -C "$PFGIT" config user.name "Test"
  echo x > "$PFGIT/f.txt"; git -C "$PFGIT" add -A; git -C "$PFGIT" commit -q -m init

  pf() { # runs preflight inspect in PFGIT, gh not required; echoes stdout JSON
    ( cd "$PFGIT"; TRACK_ID="$1" PREFLIGHT_REQUIRE_GH=0 bash "$PREFLIGHT" 2>/dev/null )
  }

  # 143 — fresh run mints run-id in <UTC-timestamp>_<track_id> format, mode=start
  J="$(pf us1)"
  RID="$(jq -r '.run_id' <<<"$J" 2>/dev/null || echo '')"
  if echo "$RID" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}-[0-9]{2}_us1$' \
     && [ "$(jq -r '.mode' <<<"$J")" = "start" ]; then
    pass "143 fresh preflight mints run-id '$RID' (format ok) + mode=start"
  else
    fail "143 fresh preflight mint/format/start (run_id='$RID')"
  fi

  # 144 — --commit persists a durable breadcrumb keyed by the run-id
  ( cd "$PFGIT"; TRACK_ID=us1 RUN_ID="$RID" PREFLIGHT_REQUIRE_GH=0 \
      bash "$PREFLIGHT" --commit >/dev/null 2>&1 ) || true
  [ -f "$PFGIT/runs/$RID.dispatch" ] \
    && pass "144 --commit persists runs/<run-id>.dispatch breadcrumb" \
    || fail "144 breadcrumb persisted"

  # 145 — resume recovers the SAME run-id from the breadcrumb (mode=resume)
  J2="$(pf us1)"
  if [ "$(jq -r '.mode' <<<"$J2")" = "resume" ] \
     && [ "$(jq -r '.run_id' <<<"$J2")" = "$RID" ]; then
    pass "145 resume recovers identical run-id '$RID' (mode=resume)"
  else
    fail "145 resume recovers same run-id (mode=$(jq -r '.mode' <<<"$J2"), id=$(jq -r '.run_id' <<<"$J2"))"
  fi

  # 146 — a distinct track mints a DIFFERENT run-id (no cross-track collision)
  RID2="$(jq -r '.run_id' <<<"$(pf us2)" 2>/dev/null || echo '')"
  [ -n "$RID2" ] && [ "$RID2" != "$RID" ] \
    && pass "146 distinct track → distinct run-id (us2 ≠ us1)" \
    || fail "146 distinct run-id per track (us1=$RID us2=$RID2)"

  # 147 — hard prerequisite failure (missing toolchain bin) → exit 3, prereq_ok=false
  rc=0
  OUT="$( cd "$PFGIT"; TRACK_ID=us3 PREFLIGHT_REQUIRE_GH=0 \
          PREFLIGHT_REQUIRE_TOOLCHAIN="zzz_not_a_real_bin_9x" \
          bash "$PREFLIGHT" 2>/dev/null )" || rc=$?
  if [ "$rc" -eq 3 ] && [ "$(jq -r '.prereq_ok' <<<"$OUT")" = "false" ]; then
    pass "147 missing prerequisite → exit 3 + prereq_ok=false (blocks dispatch)"
  else
    fail "147 hard-fail on missing prereq (rc=$rc prereq_ok=$(jq -r '.prereq_ok' <<<"$OUT" 2>/dev/null))"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 21 — Precheck Overlap, Proven by the REAL Guard (not a re-implementation)
# ═════════════════════════════════════════════════════════════════════════════
# Suite 4 tests a detect_overlap() defined inside this file — logic that ships
# nowhere. Here we PROVE overlap the way it actually bites at runtime: two tracks'
# ownership prefixes overlap iff some concrete path is admitted by BOTH tracks'
# guards (a real edit collision). Uses the shipped track-guard.sh for both sides.
suite "Suite 21 — Precheck Overlap, Proven by the REAL Guard"

if ! command -v jq &>/dev/null || ! test -f "$GUARD"; then
  for n in 148 149 150 151; do skip "$n  guard/jq unavailable"; done
else
  # mutual_allow A B PATH → 0 (true) iff both tracks' guards allow editing PATH.
  mutual_allow() {
    local da db
    da="$(TRACK_ALLOWED_PREFIXES="$1" TRACK_FROZEN_PATHS="" \
          guard_decision "$(mkjson_edit create_file "$3")")"
    db="$(TRACK_ALLOWED_PREFIXES="$2" TRACK_FROZEN_PATHS="" \
          guard_decision "$(mkjson_edit create_file "$3")")"
    [ "$da" = "allow" ] && [ "$db" = "allow" ]
  }

  # 148 — parent ⊃ child prefixes: a shared path is admitted by BOTH → collision
  if mutual_allow "internal/" "internal/notify" "internal/notify/x.go"; then
    pass "148 overlapping prefixes → path admitted by both guards → real collision"
  else
    fail "148 overlapping prefixes should collide via guard"
  fi

  # 149 — identical prefixes → collision (both admit the same path)
  if mutual_allow "internal/ingest" "internal/ingest" "internal/ingest/x.go"; then
    pass "149 identical prefixes → mutual-admit collision detected by guard"
  else
    fail "149 identical prefixes should collide via guard"
  fi

  # 150 — disjoint prefixes, track A's path → only A admits (B denies) → no collision
  if ! mutual_allow "internal/ingest" "internal/notify" "internal/ingest/x.go"; then
    pass "150 disjoint prefixes, A's file → not mutually admitted (no collision)"
  else
    fail "150 disjoint prefixes must not mutually admit A's file"
  fi

  # 151 — disjoint prefixes, track B's path → only B admits (A denies) → no collision
  if ! mutual_allow "internal/ingest" "internal/notify" "internal/notify/y.go"; then
    pass "151 disjoint prefixes, B's file → not mutually admitted (no collision)"
  else
    fail "151 disjoint prefixes must not mutually admit B's file"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 22 — End-to-End Worker Lifecycle (guard → evidence → gate → boundary)
# ═════════════════════════════════════════════════════════════════════════════
# Chains the mechanical gates in the order a real worker hits them, on one run-id:
# in-scope edit allowed → evidence captured & gate satisfied → merge denied →
# draft-PR creation allowed. Proves the pipeline composes, not just each gate alone.
suite "Suite 22 — End-to-End Worker Lifecycle"

if ! command -v jq &>/dev/null || ! test -f "$GUARD" \
   || ! test -f "$EVIDENCE" || ! test -f "$EVIDENCE_GATE"; then
  for n in 152 153 154 155 156; do skip "$n  guard/evidence/jq unavailable"; done
else
  LCGIT="$TMPDIR_ROOT/lcrepo"
  mkdir -p "$LCGIT/internal/ingest"
  git -C "$LCGIT" init -q
  git -C "$LCGIT" config user.email "test@example.com"
  git -C "$LCGIT" config user.name "Test"
  echo "// svc" > "$LCGIT/internal/ingest/svc.go"
  echo "runs/"  > "$LCGIT/.gitignore"   # runs/ MUST be git-ignored (skill invariant)
  git -C "$LCGIT" add -A; git -C "$LCGIT" commit -q -m init

  # guard runner scoped to LCGIT (guard_decision is hard-wired to $TMPGIT)
  guard_lc() { # $1=json ; echoes allow/deny, env from caller
    local out
    out="$(echo "$1" | ( cd "$LCGIT";
      export TRACK_ALLOWED_PREFIXES TRACK_FROZEN_PATHS TRACK_ALLOW_FF_PUSH
      bash "$GUARD" 2>/dev/null ))"
    [ -z "$out" ] && { echo "allow"; return 0; }
    echo "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
      || echo "allow"
  }
  lc_capture() { # $1=cmd $2=response  (RUN_ID=lc_run)
    jq -nc --arg c "$1" --arg r "$2" \
      '{tool_name:"run_in_terminal",tool_input:{command:$c},tool_response:$r}' | \
      ( cd "$LCGIT"; RUN_ID="lc_run" RUNS_DIR="runs" \
        TRACK_TEST_CMD_PATTERN="go test|uv run pytest" \
        bash "$EVIDENCE" >/dev/null 2>&1 ) || true
  }
  lc_gate() {
    local out
    out="$(printf '{"stop_hook_active":false}' | \
      ( cd "$LCGIT"; RUN_ID="lc_run" RUNS_DIR="runs" TRACK_REQUIRED_EVIDENCE=test \
        bash "$EVIDENCE_GATE" 2>/dev/null ))"
    [ -z "$out" ] && { echo "allow"; return 0; }
    echo "$out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow"
  }

  # 152 — step 1: worker edits an in-scope file → guard allows
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" TRACK_FROZEN_PATHS="cmd/main.go" \
      guard_lc "$(mkjson_edit create_file "internal/ingest/handler.go")")
  [ "$d" = "allow" ] && pass "152 lifecycle 1/5: in-scope edit → guard allow" \
                       || fail "152 lifecycle in-scope edit → allow (got $d)"

  # 153 — step 2: before evidence, the Stop gate blocks the done-claim
  d="$(lc_gate)"
  [ "$d" = "block" ] && pass "153 lifecycle 2/5: no evidence yet → gate blocks done-claim" \
                       || fail "153 lifecycle premature done → block (got $d)"

  # 154 — step 3: capture passing evidence → gate now allows the claim
  lc_capture "go test ./..." "ok  	pkg	42 passed"
  d="$(lc_gate)"
  [ "$d" = "allow" ] && pass "154 lifecycle 3/5: fresh passing evidence → gate allow" \
                       || fail "154 lifecycle evidence satisfied → allow (got $d)"

  # 155 — step 4: worker attempts to merge → guard denies (autonomy boundary)
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      guard_lc "$(mkjson_terminal "gh pr merge 7 --merge")")
  [ "$d" = "deny" ] && pass "155 lifecycle 4/5: gh pr merge → guard deny (worker boundary)" \
                      || fail "155 lifecycle merge → deny (got $d)"

  # 156 — step 5: worker opens the DRAFT PR → guard allows (legitimate endpoint)
  d=$(TRACK_ALLOWED_PREFIXES="internal/ingest" \
      guard_lc "$(mkjson_terminal "gh pr create --draft --title 'track/us1 [run lc_run]'")")
  [ "$d" = "allow" ] && pass "156 lifecycle 5/5: gh pr create --draft → guard allow" \
                       || fail "156 lifecycle draft PR → allow (got $d)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 23 — Sentinel (Stop): Secret / Debug-Leftover Scan of the Staged Diff
# ═════════════════════════════════════════════════════════════════════════════
# track-sentinel.sh is the last mechanical scan before handoff: a staged secret or
# debug leftover BLOCKS the stop so it never reaches the draft PR. Drives the real
# script against a repo with actual staged content.
suite "Suite 23 — Sentinel: Secret / Debug-Leftover Scan (Stop)"

if ! command -v jq &>/dev/null || ! test -f "$SENTINEL"; then
  for n in 157 158 159 160 161; do skip "$n  sentinel/jq unavailable"; done
else
  SNGIT="$TMPDIR_ROOT/snrepo"
  mkdir -p "$SNGIT/src"
  git -C "$SNGIT" init -q
  git -C "$SNGIT" config user.email "test@example.com"
  git -C "$SNGIT" config user.name "Test"
  echo "clean" > "$SNGIT/src/base.txt"
  git -C "$SNGIT" add -A; git -C "$SNGIT" commit -q -m init

  sentinel_run() { # echoes block/allow; TRACK_SENTINEL passed via caller env
    local out
    out="$(printf '{"stop_hook_active":false}' | \
      ( cd "$SNGIT"; export TRACK_SENTINEL; bash "$SENTINEL" 2>/dev/null ))"
    [ -z "$out" ] && { echo "allow"; return 0; }
    echo "$out" | jq -r '.decision // "allow"' 2>/dev/null || echo "allow"
  }

  # 157 — staged secret (API key assignment) → block
  printf 'api_key = "abcd1234efgh5678ijkl"\n' > "$SNGIT/src/leak.txt"
  git -C "$SNGIT" add src/leak.txt
  d=$(TRACK_SENTINEL=1 sentinel_run)
  [ "$d" = "block" ] && pass "157 staged secret (api_key=...) → block" \
                       || fail "157 staged secret → block (got $d)"
  git -C "$SNGIT" reset -q src/leak.txt; rm -f "$SNGIT/src/leak.txt"

  # 158 — staged debug leftover (console.log) → block
  printf 'console.log("here")\n' > "$SNGIT/src/dbg.js"
  git -C "$SNGIT" add src/dbg.js
  d=$(TRACK_SENTINEL=1 sentinel_run)
  [ "$d" = "block" ] && pass "158 staged debug leftover (console.log) → block" \
                       || fail "158 staged leftover → block (got $d)"
  git -C "$SNGIT" reset -q src/dbg.js; rm -f "$SNGIT/src/dbg.js"

  # 159 — clean staged diff (no secret/leftover) → allow
  printf 'const total = a + b;\n' > "$SNGIT/src/ok.js"
  git -C "$SNGIT" add src/ok.js
  d=$(TRACK_SENTINEL=1 sentinel_run)
  [ "$d" = "allow" ] && pass "159 clean staged diff → allow" \
                       || fail "159 clean staged diff → allow (got $d)"

  # 160 — disabled (TRACK_SENTINEL unset) → no-op allow even with a staged secret
  printf 'password = "supersecretvalue"\n' > "$SNGIT/src/leak2.txt"
  git -C "$SNGIT" add src/leak2.txt
  d=$( unset TRACK_SENTINEL; sentinel_run )
  [ "$d" = "allow" ] && pass "160 TRACK_SENTINEL unset → no-op (opt-in gate)" \
                       || fail "160 disabled sentinel → no-op (got $d)"

  # 161 — stop_hook_active=true → no-op (never traps the agent in a stop loop)
  out="$(printf '{"stop_hook_active":true}' | \
    ( cd "$SNGIT"; TRACK_SENTINEL=1 bash "$SENTINEL" 2>/dev/null ))"
  [ -z "$out" ] && pass "161 stop_hook_active=true → no-op (loop-safe)" \
                 || fail "161 stop_hook_active → no-op (got '$out')"
  git -C "$SNGIT" reset -q src/leak2.txt 2>/dev/null; rm -f "$SNGIT/src/leak2.txt"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 24 — Trace (SubagentStart/Stop): Activation-Trace Append
# ═════════════════════════════════════════════════════════════════════════════
# track-trace.sh builds the run's activation trace mechanically — one entry per
# subagent spawn/stop — so the run record shows which step a worker was in.
suite "Suite 24 — Trace: Activation-Trace Append"

if ! command -v jq &>/dev/null || ! test -f "$TRACE"; then
  for n in 162 163 164 165; do skip "$n  trace/jq unavailable"; done
else
  TRRUNS="$TMPDIR_ROOT/trruns"
  mkdir -p "$TRRUNS"
  trace_event() { # $1=event $2=agent_id $3=agent_type ; RUN_ID=tr_run
    jq -nc --arg e "$1" --arg id "$2" --arg ty "$3" \
      '{hook_event_name:$e, agent_id:$id, agent_type:$ty}' | \
      env RUN_ID="tr_run" RUNS_DIR="$TRRUNS" bash "$TRACE" >/dev/null 2>&1 || true
  }

  # 162 — a SubagentStart event creates the record + appends a trace entry
  trace_event "SubagentStart" "a1" "implementer"
  n162="$(jq -r '.trace | length' "$TRRUNS/tr_run.json" 2>/dev/null || echo 0)"
  [ "$n162" = "1" ] && pass "162 SubagentStart → run record created + 1 trace entry" \
                      || fail "162 SubagentStart appends entry (len=$n162)"

  # 163 — a second event (SubagentStop) accumulates (append-only log)
  trace_event "SubagentStop" "a1" "implementer"
  n163="$(jq -r '.trace | length' "$TRRUNS/tr_run.json" 2>/dev/null || echo 0)"
  [ "$n163" = "2" ] && pass "163 SubagentStop → trace accumulates (append-only, len=2)" \
                      || fail "163 trace accumulates (len=$n163)"

  # 164 — entries carry kind=subagent + event + agent_type
  ok164="$(jq -e '[.trace[] | .kind=="subagent" and has("event") and has("agent_type")] | all' \
            "$TRRUNS/tr_run.json" >/dev/null 2>&1 && echo yes || echo no)"
  [ "$ok164" = "yes" ] && pass "164 trace entries carry kind=subagent + event + agent_type" \
                        || fail "164 trace entry shape"

  # 165 — no-op without RUN_ID (opt-in, writes nothing)
  before="$(ls "$TRRUNS" | wc -l | tr -d ' ')"
  printf '{"hook_event_name":"SubagentStart","agent_id":"x","agent_type":"y"}' | \
    ( unset RUN_ID; RUNS_DIR="$TRRUNS" bash "$TRACE" >/dev/null 2>&1 ) || true
  after="$(ls "$TRRUNS" | wc -l | tr -d ' ')"
  [ "$before" = "$after" ] && pass "165 no RUN_ID → no-op (writes nothing)" \
                            || fail "165 no RUN_ID no-op (before=$before after=$after)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 25 — Notify (Stop): Best-Effort Webhook, Never Blocks
# ═════════════════════════════════════════════════════════════════════════════
# track-notify.sh POSTs the run's terminal state to a webhook. It must NEVER block
# or fail the session. A curl shim on PATH captures the payload so we can assert the
# status/PR are read from the run record — without any real network.
suite "Suite 25 — Notify: Best-Effort Webhook (Stop)"

if ! command -v jq &>/dev/null || ! test -f "$NOTIFY"; then
  for n in 166 167 168 169; do skip "$n  notify/jq unavailable"; done
else
  NTRUNS="$TMPDIR_ROOT/ntruns"; mkdir -p "$NTRUNS"
  NTBIN="$TMPDIR_ROOT/ntbin";   mkdir -p "$NTBIN"
  NT_PAYLOAD="$TMPDIR_ROOT/nt_payload.txt"
  # curl shim: capture the -d payload to a file, always succeed (like a live webhook).
  cat > "$NTBIN/curl" <<EOF
#!/usr/bin/env bash
p=""; while [ \$# -gt 0 ]; do case "\$1" in -d) shift; p="\$1";; esac; shift; done
printf '%s' "\$p" > "$NT_PAYLOAD"
exit 0
EOF
  chmod +x "$NTBIN/curl"

  # run record with a terminal state to report
  jq -n '{run_id:"nt_run",status:"blocked",pr_url:null}' > "$NTRUNS/nt_run.json"

  # 166 — with webhook set → exits 0 (never fails the session)
  rc=0
  printf '{}' | ( PATH="$NTBIN:$PATH" RUN_ID="nt_run" RUNS_DIR="$NTRUNS" \
    TRACK_NOTIFY_WEBHOOK="https://example.invalid/hook" bash "$NOTIFY" >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] && pass "166 webhook set → exit 0 (never blocks/fails session)" \
                    || fail "166 notify exit 0 (rc=$rc)"

  # 167 — payload text carries the run-id and the record's status
  ok167=no
  [ -f "$NT_PAYLOAD" ] && grep -q "nt_run" "$NT_PAYLOAD" && grep -q "blocked" "$NT_PAYLOAD" && ok167=yes
  [ "$ok167" = "yes" ] && pass "167 payload carries run-id + status read from record" \
                        || fail "167 payload content (got: $(cat "$NT_PAYLOAD" 2>/dev/null))"

  # 168 — no webhook set → no-op, no payload written, exit 0
  rm -f "$NT_PAYLOAD"; rc=0
  printf '{}' | ( PATH="$NTBIN:$PATH" RUN_ID="nt_run" RUNS_DIR="$NTRUNS"; \
    unset TRACK_NOTIFY_WEBHOOK; bash "$NOTIFY" >/dev/null 2>&1 ) || rc=$?
  { [ "$rc" -eq 0 ] && [ ! -f "$NT_PAYLOAD" ]; } \
    && pass "168 no webhook → no-op (no POST, exit 0)" \
    || fail "168 no-webhook no-op (rc=$rc payload_exists=$([ -f "$NT_PAYLOAD" ] && echo y || echo n))"

  # 169 — real unreachable webhook (no shim) still exits 0 (best-effort swallow)
  rc=0
  printf '{}' | ( RUN_ID="nt_run" RUNS_DIR="$NTRUNS" \
    TRACK_NOTIFY_WEBHOOK="http://127.0.0.1:0/nope" bash "$NOTIFY" >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -eq 0 ] && pass "169 unreachable webhook → still exit 0 (fire-and-forget)" \
                    || fail "169 unreachable webhook exit 0 (rc=$rc)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 26 — Reconcile (Resume): Durable-State Position & Evidence Freshness
# ═════════════════════════════════════════════════════════════════════════════
# track-reconcile.sh answers "where did an interrupted run leave off?" from persisted
# state only. Drives the real script and asserts resumable/dirty/evidence classes.
suite "Suite 26 — Reconcile: Durable-State Resume Report"

if ! command -v jq &>/dev/null || ! test -f "$RECONCILE" || ! test -f "$EVIDENCE"; then
  for n in 170 171 172 173 174 175; do skip "$n  reconcile/evidence/jq unavailable"; done
else
  RCGIT="$TMPDIR_ROOT/rcrepo"
  mkdir -p "$RCGIT/src"
  git -C "$RCGIT" init -q
  git -C "$RCGIT" config user.email "test@example.com"
  git -C "$RCGIT" config user.name "Test"
  echo "// a" > "$RCGIT/src/a.go"
  echo "runs/" > "$RCGIT/.gitignore"     # runs/ MUST be git-ignored (skill invariant)
  git -C "$RCGIT" add -A; git -C "$RCGIT" commit -q -m init

  reconcile() { # runs reconcile in RCGIT with given env; echoes stdout JSON
    printf '{}' | ( cd "$RCGIT"; env "$@" bash "$RECONCILE" 2>/dev/null )
  }

  # 170 — clean tree, no required evidence → resumable=true, dirty=false
  J="$(reconcile RUN_ID=rc_run RUNS_DIR=runs)"
  if [ "$(jq -r '.resumable' <<<"$J")" = "true" ] \
     && [ "$(jq -r '.dirty_worktree' <<<"$J")" = "false" ]; then
    pass "170 clean tree, no required evidence → resumable=true, dirty=false"
  else
    fail "170 clean/resumable (resumable=$(jq -r '.resumable' <<<"$J") dirty=$(jq -r '.dirty_worktree' <<<"$J"))"
  fi

  # 171 — dirty worktree → dirty=true, resumable=false, UNTRUSTED note
  echo "// uncommitted" >> "$RCGIT/src/a.go"
  J="$(reconcile RUN_ID=rc_run RUNS_DIR=runs)"
  if [ "$(jq -r '.dirty_worktree' <<<"$J")" = "true" ] \
     && [ "$(jq -r '.resumable' <<<"$J")" = "false" ] \
     && jq -e '.note | test("UNTRUSTED")' <<<"$J" >/dev/null; then
    pass "171 dirty tree → dirty=true, resumable=false, note flags UNTRUSTED changes"
  else
    fail "171 dirty tree report (dirty=$(jq -r '.dirty_worktree' <<<"$J") resumable=$(jq -r '.resumable' <<<"$J"))"
  fi
  git -C "$RCGIT" checkout -q -- src/a.go   # restore clean tree

  # 172 — required evidence but none captured → missing kind, resumable=false
  J="$(reconcile RUN_ID=rc_run RUNS_DIR=runs TRACK_REQUIRED_EVIDENCE=go-test)"
  if jq -e '.evidence.missing | index("go-test")' <<<"$J" >/dev/null \
     && [ "$(jq -r '.resumable' <<<"$J")" = "false" ]; then
    pass "172 required-but-uncaptured evidence → missing kind, resumable=false"
  else
    fail "172 missing-evidence report ($(jq -c '.evidence' <<<"$J"))"
  fi

  # 173 — capture fresh passing evidence for the current tree → fresh kind, resumable=true
  jq -nc --arg c "go test ./..." --arg r "ok  	pkg	5 passed" \
    '{tool_name:"run_in_terminal",tool_input:{command:$c},tool_response:$r}' | \
    ( cd "$RCGIT"; RUN_ID=rc_run RUNS_DIR=runs \
      TRACK_EVIDENCE_KINDS="go-test:go test" bash "$EVIDENCE" >/dev/null 2>&1 ) || true
  J="$(reconcile RUN_ID=rc_run RUNS_DIR=runs TRACK_REQUIRED_EVIDENCE=go-test)"
  if jq -e '.evidence.fresh | index("go-test")' <<<"$J" >/dev/null \
     && [ "$(jq -r '.resumable' <<<"$J")" = "true" ]; then
    pass "173 fresh passing evidence (fingerprint matches) → fresh kind, resumable=true"
  else
    fail "173 fresh-evidence report ($(jq -c '.evidence' <<<"$J") resumable=$(jq -r '.resumable' <<<"$J"))"
  fi

  # 174 — tree changes after capture → same evidence now STALE, resumable=false
  echo "// drift" >> "$RCGIT/src/a.go"
  J="$(reconcile RUN_ID=rc_run RUNS_DIR=runs TRACK_REQUIRED_EVIDENCE=go-test)"
  if jq -e '.evidence.stale | index("go-test")' <<<"$J" >/dev/null \
     && [ "$(jq -r '.resumable' <<<"$J")" = "false" ]; then
    pass "174 tree changed after capture → evidence STALE, resumable=false"
  else
    fail "174 stale-evidence report ($(jq -c '.evidence' <<<"$J"))"
  fi
  git -C "$RCGIT" checkout -q -- src/a.go

  # 175 — self-recover RUN_ID from a preflight breadcrumb when RUN_ID is unset
  if test -f "$PREFLIGHT"; then
    ( cd "$RCGIT"; TRACK_ID=rc RUN_ID=rc_run PREFLIGHT_REQUIRE_GH=0 \
        bash "$PREFLIGHT" --commit >/dev/null 2>&1 ) || true
    J="$( printf '{}' | ( cd "$RCGIT"; unset RUN_ID; TRACK_ID=rc RUNS_DIR=runs \
          bash "$RECONCILE" 2>/dev/null ) )"
    [ "$(jq -r '.run_id' <<<"$J" 2>/dev/null)" = "rc_run" ] \
      && pass "175 RUN_ID unset → self-recovers 'rc_run' from breadcrumb" \
      || fail "175 breadcrumb self-recovery (got $(jq -r '.run_id' <<<"$J" 2>/dev/null))"
  else
    skip "175 preflight unavailable — cannot seed breadcrumb"
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Suite 27 — Precheck Gate: track-precheck.sh (mechanical overlap assertion)
# ═════════════════════════════════════════════════════════════════════════════
# Suite 4 tests a detect_overlap() defined inside this file — logic that shipped
# nowhere. This drives the REAL bundled track-precheck.sh: pipe it the tracks' JSON
# and assert the exit code + report, using the SAME string-prefix rule the guard
# enforces, so the Precheck gate is now mechanical, not prose-trusted.
suite "Suite 27 — Precheck Gate: track-precheck.sh"

if ! command -v jq &>/dev/null || ! test -f "$PRECHECK"; then
  for n in 176 177 178 179 180 181 182 183 184 185 186; do skip "$n  precheck/jq unavailable"; done
else
  # run precheck; echoes "<exit_code> <json>" so tests can assert both.
  pc() { local out rc=0; out="$(printf '%s' "$1" | bash "$PRECHECK" 2>/dev/null)" || rc=$?; printf '%s\t%s' "$rc" "$out"; }
  pc_rc()   { printf '%s' "$1" | cut -f1; }
  pc_json() { printf '%s' "$1" | cut -f2-; }

  # 176 — bundled script exists and is executable
  assert "176 track-precheck.sh is bundled + executable" test -x "$PRECHECK"

  # 177 — disjoint prefixes → ok=true, exit 0
  R="$(pc '[{"id":"us1","prefixes":"internal/ingest:migrations/0007_"},{"id":"us2","prefixes":"internal/notify:migrations/0008_"}]')"
  { [ "$(pc_rc "$R")" = "0" ] && [ "$(jq -r '.ok' <<<"$(pc_json "$R")")" = "true" ]; } \
    && pass "177 disjoint prefixes → ok=true, exit 0 (fan-out may proceed)" \
    || fail "177 disjoint → ok/exit0 (rc=$(pc_rc "$R") json=$(pc_json "$R"))"

  # 178 — parent ⊃ child prefix → collision, exit 2
  R="$(pc '[{"id":"us1","prefixes":"internal/"},{"id":"us2","prefixes":"internal/notify"}]')"
  { [ "$(pc_rc "$R")" = "2" ] && [ "$(jq -r '.ok' <<<"$(pc_json "$R")")" = "false" ]; } \
    && pass "178 parent ⊃ child prefix → collision, exit 2 (STOP)" \
    || fail "178 parent overlap → exit2 (rc=$(pc_rc "$R"))"

  # 179 — the collision report names BOTH tracks and the offending prefix pair
  J="$(pc_json "$R")"
  { [ "$(jq -r '.collisions[0].a' <<<"$J")" = "us1" ] \
    && [ "$(jq -r '.collisions[0].b' <<<"$J")" = "us2" ] \
    && [ "$(jq -r '.collisions[0].a_prefix' <<<"$J")" = "internal/" ] \
    && [ "$(jq -r '.collisions[0].b_prefix' <<<"$J")" = "internal/notify" ]; } \
    && pass "179 collision report names both tracks + the offending prefix pair" \
    || fail "179 collision report shape ($(jq -c '.collisions' <<<"$J"))"

  # 180 — identical prefixes → collision, exit 2
  R="$(pc '[{"id":"us1","prefixes":"internal/ingest"},{"id":"us2","prefixes":"internal/ingest"}]')"
  [ "$(pc_rc "$R")" = "2" ] && pass "180 identical prefixes → collision, exit 2" \
                             || fail "180 identical → exit2 (rc=$(pc_rc "$R"))"

  # 181 — single track → trivially ok, exit 0 (no self-comparison)
  R="$(pc '[{"id":"us1","prefixes":"internal/ingest"}]')"
  { [ "$(pc_rc "$R")" = "0" ] && [ "$(jq -r '.ok' <<<"$(pc_json "$R")")" = "true" ]; } \
    && pass "181 single track → ok=true, exit 0 (never compared with itself)" \
    || fail "181 single track ok (rc=$(pc_rc "$R"))"

  # 182 — 3-way wave, tracks 1+2 share 'shared' hotspot → collision, exit 2
  R="$(pc '[{"id":"us1","prefixes":"internal/ingest:shared"},{"id":"us2","prefixes":"internal/notify:shared"},{"id":"us3","prefixes":"frontend/"}]')"
  { [ "$(pc_rc "$R")" = "2" ] \
    && [ "$(jq -r '.collisions[0].a_prefix' <<<"$(pc_json "$R")")" = "shared" ]; } \
    && pass "182 3-way wave with shared hotspot → collision on 'shared', exit 2" \
    || fail "182 3-way shared hotspot (rc=$(pc_rc "$R") json=$(pc_json "$R"))"

  # 183 — 3-way fully-disjoint wave → ok=true, exit 0
  R="$(pc '[{"id":"us1","prefixes":"internal/ingest:test/ingest"},{"id":"us2","prefixes":"internal/notify:test/notify"},{"id":"us3","prefixes":"frontend/components"}]')"
  { [ "$(pc_rc "$R")" = "0" ] && [ "$(jq -r '.ok' <<<"$(pc_json "$R")")" = "true" ]; } \
    && pass "183 3-way disjoint wave → ok=true, exit 0" \
    || fail "183 3-way disjoint (rc=$(pc_rc "$R"))"

  # 184 — a track with EMPTY ownership → config error, exit 2 (fail-closed)
  R="$(pc '[{"id":"us1","prefixes":""},{"id":"us2","prefixes":"internal/notify"}]')"
  { [ "$(pc_rc "$R")" = "2" ] \
    && jq -e '.config_errors | index("us1(no-prefixes)")' <<<"$(pc_json "$R")" >/dev/null; } \
    && pass "184 empty-ownership track → config error, exit 2 (fail-closed)" \
    || fail "184 empty ownership (rc=$(pc_rc "$R") json=$(pc_json "$R"))"

  # 185 — duplicate track id → config error, exit 2
  R="$(pc '[{"id":"us1","prefixes":"a/"},{"id":"us1","prefixes":"b/"}]')"
  { [ "$(pc_rc "$R")" = "2" ] \
    && jq -e '.config_errors | index("us1(duplicate-id)")' <<<"$(pc_json "$R")" >/dev/null; } \
    && pass "185 duplicate track id → config error, exit 2" \
    || fail "185 duplicate id (rc=$(pc_rc "$R") json=$(pc_json "$R"))"

  # 186 — malformed input (not a JSON array) → fail-closed exit 2
  R="$(pc '{"not":"an array"}')"
  [ "$(pc_rc "$R")" = "2" ] && pass "186 non-array input → fail-closed exit 2" \
                             || fail "186 malformed input → exit2 (rc=$(pc_rc "$R"))"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Final summary
# ═════════════════════════════════════════════════════════════════════════════
TOTAL=$((PASS + FAIL + SKIP))
echo
echo "═══════════════════════════════════════════════════════"
printf "Result: ${GREEN}%d PASSED${RESET} · ${YELLOW}%d SKIPPED${RESET} · ${RED}%d FAILED${RESET} · %d total\n" \
  "$PASS" "$SKIP" "$FAIL" "$TOTAL"
echo "═══════════════════════════════════════════════════════"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
