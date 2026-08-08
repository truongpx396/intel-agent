#!/usr/bin/env bash
# track-reconcile.sh — Resume/Reconcile preflight: deterministically answer "where did
# an interrupted run leave off?" from PERSISTED STATE ONLY (committed history + the run
# record), never from the model's reading of the worktree. Mirrors the workflow-engine
# pattern (Temporal/Argo replay): rebuild position from a durable log, then move forward.
#
# Advisory: it prints a JSON report and does NOT mutate the repo, the tree, or git state.
# The skill's Step 0 consumes the report and decides the (reversible) cleanup (git stash of
# untrusted changes) and which task to resume — the model only ever picks the NEXT not-done
# task, never judges a task "done". Doneness stays mechanical here.
#
# The ONE thing it writes is a `last_reconcile` stamp in runs/<RUN_ID>.json (gitignored run
# state, exactly like every other hook writes). Without it, "did this run re-anchor from
# durable state, or did the model guess from the worktree?" leaves no artifact at all — and
# an invariant with no artifact cannot be audited, only hoped for. track-audit.sh reads it.
#
# What it computes (all deterministic — no model call):
#   1. dirty            — is the working tree dirty? Uncommitted edits at startup are
#                         UNTRUSTED (tests/review may not have run) and must not be built
#                         upon. Reported so Step 0 can `git stash` them (reversible),
#                         not `git reset --hard` (destructive).
#   2. head / branch    — the last durable commit to resume from.
#   3. evidence freshness per required kind at the CURRENT fingerprint, reusing
#      track-evidence-gate.sh's exact fingerprint + rule-selection logic:
#         fresh  = entry exists, fingerprint==current, no failure marker  -> proven done
#         stale  = entry exists but fingerprint!=current                  -> re-verify
#         missing= no entry for a diff-required kind                      -> not done
#   4. PIPELINE POSITION — the last `phase` / `status` / `governance_bundle` the skill
#      asserted via track-note.sh. Evidence freshness alone cannot answer "which core did
#      I pick / is the RED suite frozen / which increment am I on / where are my binding
#      governance excerpts" — so those are replayed here verbatim. Self-reported (the
#      model's own claim, provenance-tagged in the record) and echoed as such: they steer
#      the resume, they never substitute for the mechanical evidence verdict.
#
# Opt-in / no-op unless RUN_ID is set (matches the rest of the track-*.sh bundle). Honors
# the same env: RUN_ID, RUNS_DIR, TRACK_REQUIRED_EVIDENCE, TRACK_EVIDENCE_RULES,
# TRACK_BASE_REF, TRACK_FAIL_PATTERN. Surface-agnostic: reads stdin JSON (may be empty),
# branches on nothing tool-specific. Wire it at SessionStart / agentStart, or run it by
# hand at the top of a resumed session.
#
# NOTE (manual runs): this script reads the hook payload from stdin. When stdin is
# an interactive TTY (running it by hand) it SKIPS the read (see the `[ -t 0 ]`
# guard below) so it never blocks waiting for Ctrl-D. A `< /dev/null` redirect is
# therefore optional now; it was previously required to avoid an apparent hang.
#
# Requires: jq, git. Keep runtime < 5s.
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
# Local is sourced first so a worktree value wins over the repo base; every line
# uses ${VAR:-default}, so an already-exported value (e.g. an executing-parallel-
# tracks per-track override) still wins over both. No-op when a file is absent.
__env_dir="${BASH_SOURCE[0]%/*}"
# Prefer the MAIN checkout's .github/hooks (canonical) when installed, so a hook
# firing from a linked worktree sources the SAME per-run env + RUN_ID block the
# main-checkout preflight wrote — not an absent worktree-local copy (which would
# leave the guard with empty scope and deny every worktree write). git-common-dir
# resolves to the main repo's .git from any worktree; its parent is the main root.
__gcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$__gcd" ]; then
  case "$__gcd" in /*) ;; *) __gcd="$PWD/$__gcd" ;; esac
  __main_root="$(cd "$__gcd/.." 2>/dev/null && pwd || true)"
  if [ -n "$__main_root" ] && [ -d "$__main_root/.github/hooks" ]; then __env_dir="$__main_root/.github/hooks"; fi
  unset __main_root
fi
unset __gcd
if [ -f "$__env_dir/track-env.sh" ]; then . "$__env_dir/track-env.sh"; fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

# Read the hook payload from stdin — but only when stdin is NOT an interactive
# TTY. A hook surface always pipes/closes stdin, so `cat` returns immediately
# there. Run by hand in a terminal, an unguarded `cat` blocks on the TTY waiting
# for Ctrl-D and looks like a hang; the [ -t 0 ] guard makes manual runs a no-op
# without needing a `< /dev/null` redirect.
if [ -t 0 ]; then input=""; else input="$(cat 2>/dev/null || true)"; fi

RUNS_DIR="${RUNS_DIR:-runs}"
# Anchor a RELATIVE RUNS_DIR to the main working tree so the run record is
# single-homed across the main checkout and any linked worktree — a bare "runs"
# resolves against the process CWD, splitting the record when preflight mints it
# in the main checkout but later hooks fire from a sibling worktree. An absolute
# RUNS_DIR (explicit override, e.g. the test harness) is respected verbatim.
case "$RUNS_DIR" in
  /*) ;;
  *)
    __rgcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$__rgcd" ]; then
      case "$__rgcd" in /*) ;; *) __rgcd="$PWD/$__rgcd" ;; esac
      __rroot="$(cd "$__rgcd/.." 2>/dev/null && pwd || true)"
      if [ -n "$__rroot" ]; then RUNS_DIR="$__rroot/$RUNS_DIR"; fi
      unset __rroot
    fi
    unset __rgcd
    ;;
esac

# --- self-recovering resume: if no RUN_ID was provided, adopt it from the breadcrumb
# that track-preflight.sh persisted (runs/<id>.dispatch). This is the whole point of the
# breadcrumb — a resumed session need not have a human remember/retype the RUN_ID. Pick
# the newest breadcrumb for TRACK_ID if set, else the newest breadcrumb overall.
# NOTE: `set -f` (noglob) is active — use `find`, not a shell *.dispatch glob.
if [ -z "${RUN_ID:-}" ]; then
  want_track="${TRACK_ID:-}"
  sorted=""
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    sorted="$sorted$mt	$f
"
  done <<<"$(find "$RUNS_DIR" -maxdepth 1 -type f -name '*.dispatch' 2>/dev/null || true)"
  sorted="$(printf '%s' "$sorted" | sort -rn)"
  # Rank the candidates instead of taking the newest outright. "Newest breadcrumb in the
  # checkout" adopts a FINISHED run on an unrelated branch exactly as readily as this
  # session's own, and every line of the report below then describes the wrong task — the
  # same stale-state failure the managed RUN_ID block guards against. Preference order,
  # newest-first within each tier: (1) a run whose recorded branch is the one actually
  # checked out here, (2) any run not yet stamped terminal, (3) whatever matched — tier 3
  # keeps the recovery no weaker than it was before.
  head_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  pick_branch=""; pick_open=""; pick_any=""
  while IFS="$(printf '\t')" read -r _ f; do
    [ -n "${f:-}" ] || continue
    if [ -n "$want_track" ] && [ "$(jq -r '.track // empty' "$f" 2>/dev/null || true)" != "$want_track" ]; then
      continue
    fi
    cand="$(jq -r '.run_id // empty' "$f" 2>/dev/null || true)"
    [ -n "$cand" ] || continue
    [ -n "$pick_any" ] || pick_any="$cand"
    if [ -z "$pick_branch" ] && [ -n "$head_branch" ] \
       && [ "$(jq -r '.branch // empty' "$f" 2>/dev/null || true)" = "$head_branch" ]; then
      pick_branch="$cand"
    fi
    if [ -z "$pick_open" ]; then
      # Terminal = completed at PR handoff, or a status written by meter/tokens/note.
      if [ -z "$(jq -r '.completed_utc // empty' "$f" 2>/dev/null || true)" ] \
         && [ -z "$(jq -r '.status // empty' "$RUNS_DIR/$cand.json" 2>/dev/null || true)" ]; then
        pick_open="$cand"
      fi
    fi
  done <<<"$sorted"
  RUN_ID="${pick_branch:-${pick_open:-$pick_any}}"
fi

# Opt-in / no-op: nothing to reconcile without a RUN_ID (none given, none recoverable).
[ -n "${RUN_ID:-}" ] || exit 0

rec="$RUNS_DIR/$RUN_ID.json"

# --- durable position --------------------------------------------------------------
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
head="$(git rev-parse HEAD 2>/dev/null || echo no-head)"
# Dirty = staged or unstaged tracked changes, or untracked non-ignored files.
dirty=false
if ! git diff --quiet HEAD 2>/dev/null \
   || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
  dirty=true
fi

# --- current fingerprint — MUST match track-evidence{,-gate}.sh exactly -------------
hash_cmd() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }
current_fp="$({
  git rev-parse HEAD 2>/dev/null || echo no-head
  git diff HEAD 2>/dev/null || true
  u="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
  if [ -n "$u" ]; then
    printf '%s
' "$u"
    printf '%s
' "$u" | git hash-object --stdin-paths 2>/dev/null || true
  fi
} | hash_cmd | cut -d' ' -f1)"

# --- required-kind set: static floor UNION diff-derived rules (gate parity) ---------
base="${TRACK_BASE_REF:-}"
[ -n "$base" ] || base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
committed=""
if [ -n "$base" ] && git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  committed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
fi
worktree="$(git diff --name-only HEAD 2>/dev/null || true)"
untracked="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
touched="$(printf '%s\n%s\n%s\n' "$committed" "$worktree" "$untracked" | sed '/^$/d' | sort -u)"

required=""
if [ -n "${TRACK_REQUIRED_EVIDENCE:-}" ]; then
  saved_ifs="$IFS"; IFS=,
  for k in $TRACK_REQUIRED_EVIDENCE; do [ -n "$k" ] && required="$required $k"; done
  IFS="$saved_ifs"
fi
if [ -n "${TRACK_EVIDENCE_RULES:-}" ] && [ -n "$touched" ]; then
  saved_ifs="$IFS"; IFS=';'
  for rule in $TRACK_EVIDENCE_RULES; do
    glob="${rule%%:*}"; kind="${rule#*:}"
    [ -n "$glob" ] && [ -n "$kind" ] && [ "$glob" != "$rule" ] || continue
    glob="${glob#\*\*/}"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2254
      case "$p" in
        $glob) required="$required $kind"; break ;;
      esac
    done <<<"$touched"
    IFS=';'
  done
  IFS="$saved_ifs"
fi
required="$(printf '%s\n' $required | sed '/^$/d' | sort -u | tr '\n' ' ')"

fail_re="${TRACK_FAIL_PATTERN:-}"
[ -n "$fail_re" ] || fail_re='\bFAIL\b|FAILED|panic:|Traceback|error TS[0-9]|\bERROR\b|✖|exit code [1-9]|[1-9][0-9]* (failed|error)'

# --- classify each required kind against the run record at current_fp ---------------
fresh=""; stale=""; missing=""; failed=""
if [ -n "${required// /}" ] && [ -f "$rec" ]; then
  for kind in $required; do
    [ -n "$kind" ] || continue
    entry="$(jq -c --arg k "$kind" '[.evidence[]? | select(.kind == $k)] | last // empty' "$rec" 2>/dev/null || true)"
    if [ -z "$entry" ] || [ "$entry" = "null" ]; then missing="$missing $kind"; continue; fi
    fp="$(jq -r '.fingerprint // empty' <<<"$entry")"
    resp="$(jq -r '.response // empty' <<<"$entry")"
    if [ "$fp" != "$current_fp" ]; then stale="$stale $kind"; continue; fi
    if printf '%s' "$resp" | grep -Eq "$fail_re"; then failed="$failed $kind"; continue; fi
    fresh="$fresh $kind"
  done
elif [ -n "${required// /}" ]; then
  missing="$required"   # required kinds but no run record at all
fi

trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }
# resumable = clean tree AND nothing missing/stale/failed for the current diff.
resumable=false
if [ "$dirty" = false ] && [ -z "$(trim "$missing$stale$failed")" ]; then resumable=true; fi

# --- pipeline position (self-reported via track-note.sh) ----------------------------
# Replayed verbatim so a compacted/crashed session re-anchors on the phase it actually
# reached rather than inferring one from the worktree. `null` when never asserted.
phase="null"; status="null"; gov="null"
if [ -f "$rec" ]; then
  phase="$(jq -c '.phase // null' "$rec" 2>/dev/null || echo null)"
  status="$(jq -c '.status // null' "$rec" 2>/dev/null || echo null)"
  gov="$(jq -c '.governance_bundle // null' "$rec" 2>/dev/null || echo null)"
fi
# A governance bundle that was recorded but has since vanished must not be trusted — the
# briefs built from it are unreproducible, so say so instead of pointing at a dead path.
gov_present=false
gov_path="$(printf '%s' "$gov" | jq -r 'if type=="object" then (.path // "") else "" end' 2>/dev/null || true)"
[ -n "$gov_path" ] && [ -f "$gov_path" ] && gov_present=true

# --- leave the one durable trace that proves this ran -------------------------------
# Overwritten each time (the question is "did it re-anchor recently", not a history), and
# best-effort: a failure to stamp must never break the resume report itself.
if [ -n "${RUNS_DIR:-}" ]; then
  mkdir -p "$RUNS_DIR" 2>/dev/null || true
  [ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec" 2>/dev/null || true
  if [ -f "$rec" ]; then
    _rc_tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$_rc_tmp" ]; then
      jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg h "$head" \
         --argjson d "$dirty" --argjson r "$resumable" \
         '.last_reconcile = {t:$t, head:$h, dirty_worktree:$d, resumable:$r}' \
         "$rec" >"$_rc_tmp" 2>/dev/null && mv "$_rc_tmp" "$rec" 2>/dev/null || rm -f "$_rc_tmp"
    fi
  fi
fi

jq -nc \
  --arg run_id "$RUN_ID" \
  --arg branch "$branch" \
  --arg head "$head" \
  --arg fp "$current_fp" \
  --argjson dirty "$dirty" \
  --argjson resumable "$resumable" \
  --arg fresh "$(trim "$fresh")" \
  --arg stale "$(trim "$stale")" \
  --arg missing "$(trim "$missing")" \
  --arg failed "$(trim "$failed")" \
  --arg rec "$rec" \
  --argjson phase "$phase" \
  --argjson status "$status" \
  --argjson gov "$gov" \
  --argjson gov_present "$gov_present" \
  '{
     run_id: $run_id, branch: $branch, head: $head, fingerprint: $fp,
     run_record: $rec, dirty_worktree: $dirty, resumable: $resumable,
     evidence: {
       fresh:   ($fresh   | if . == "" then [] else split(" ") end),
       stale:   ($stale   | if . == "" then [] else split(" ") end),
       missing: ($missing | if . == "" then [] else split(" ") end),
       failed:  ($failed  | if . == "" then [] else split(" ") end)
     },
     position: {
       phase: $phase,
       status: $status,
       governance_bundle: $gov,
       governance_bundle_present: $gov_present,
       self_reported: true
     },
     note: (if $dirty then "Uncommitted changes are UNTRUSTED — git stash (reversible) before resuming; do not build on them." else "Clean tree — resume from HEAD." end),
     resume_action: (
       if $status != null and ($status | type) == "string" and $status != "success"
         then "Run ended in terminal state \"" + $status + "\" — do NOT resume silently; read blocker/next_step in the run record and re-plan."
       elif $phase == null
         then "No phase recorded — this run never passed a core-step boundary. Re-enter at the pipeline step matching the evidence verdict above."
       elif $gov != null and $gov_present == false
         then "Phase is \"" + ($phase.mode // "?") + "/" + ($phase.step // "?") + "\" but the recorded governance bundle is MISSING from disk — re-run governance discovery before dispatching any subagent."
       else "Re-enter at phase \"" + ($phase.mode // "?") + "/" + ($phase.step // "?") + "\"; re-read the governance bundle before dispatching any subagent."
       end
     )
   }'

exit 0
