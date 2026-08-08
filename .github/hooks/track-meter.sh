#!/usr/bin/env bash
# track-meter.sh — PostToolUse: enforce a per-worker tool-call ceiling (hard stop).
#
# Counts tool calls in runs/<RUN_ID>.json and halts the session via `continue:false`
# when the ceiling trips — the mechanical backstop for the skill's "max iterations"
# hard stop.
#
# LIMITATION: hook I/O carries NO token/cost data, so this enforces a TOOL-CALL
# ceiling only. Token/$ ceilings (per-worker and the global fleet ceiling) must stay
# orchestrator-side. A tool-call count approximates "turns"; it is not identical.
#
# Opt-in via env (no-op unless the ceiling is set):
#   TRACK_MAX_TOOL_CALLS  integer ceiling; halt the worker once exceeded
#   RUN_ID                stable run-id for this worker
#   RUNS_DIR              where run records live (default: runs)
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

# Need a run record to write into. The tool-call COUNTER + heartbeat below are always
# on when RUN_ID is set — so even a SOLO run with no ceiling still captures tool_calls
# and last_ts. The ceiling only ADDS the hard-stop enforcement when it is configured.
[ -n "${RUN_ID:-}" ] || exit 0

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
rec="$RUNS_DIR/$RUN_ID.json"
mkdir -p "$RUNS_DIR"
# Canonical skeleton — identical across track-evidence/-meter/-trace so whichever hook
# fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

count="$(jq -r '(.tool_calls // 0) + 1' "$rec")"
now_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
# Also stamp the heartbeat: started_ts once, last_ts on every call. now - last_ts is
# the orchestrator's idle/staleness signal (a hung worker stops advancing last_ts);
# last_ts - started_ts is the run's wall-clock duration.
jq --argjson n "$count" --arg t "$now_ts" \
  '.tool_calls = $n | .started_ts = (.started_ts // $t) | .last_ts = $t' "$rec" >"$tmp" && mv "$tmp" "$rec"

if [ -n "${TRACK_MAX_TOOL_CALLS:-}" ] && [ "$count" -gt "$TRACK_MAX_TOOL_CALLS" ]; then
  # Also record the terminal state for the orchestrator's summary.
  tmp2="$(mktemp)"
  jq '.status = "no-progress"' "$rec" >"$tmp2" && mv "$tmp2" "$rec"
  # The count is CUMULATIVE for the run, so the trip is sticky by design — but a sticky
  # halt with no named way out is what turns "this run is over" into "this checkout is
  # over". Name both deliberate exits so the next operator does not have to read the hook.
  jq -nc --arg r "tool-call ceiling ($TRACK_MAX_TOOL_CALLS) exceeded for run $RUN_ID (count: $count); halting per hard-stop policy (status: no-progress). The count is cumulative for this run, so it stays tripped: to continue deliberately, raise TRACK_MAX_TOOL_CALLS above $count, or start a fresh run (new RUN_ID) via track-preflight.sh." \
    '{continue:false, stopReason:$r}'
fi
exit 0
