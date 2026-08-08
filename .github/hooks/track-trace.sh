#!/usr/bin/env bash
# track-trace.sh — SubagentStart / SubagentStop: append to the run's activation trace.
#
# Builds the "skill → subagent → skill …" activation trace mechanically, so the run
# record shows which step a worker was in without reading the full transcript.
#
# NOTE: this records SUBAGENT spawn/stop events (the data hooks actually expose).
# The richest field is `agent_description` (the subagent's one-line "why") — it is
# present on SubagentStart ONLY; SubagentStop carries a `stop_reason` instead. Field
# NAMES differ across surfaces (VS Code: snake_case agent_id/agent_type; CLI/cloud:
# camelCase agentName/agentDisplayName/agentDescription — see references/hooks.md), so
# every known spelling is read below and the trace is populated on any surface.
#
# The `Run-Id:` COMMIT trailer is NOT added here — a Copilot hook can't cleanly
# rewrite an already-made commit. Add that trailer in the worker's commit command
# (prompt-enforced) or via a git `prepare-commit-msg` hook.
#
# Opt-in via env (no-op unless RUN_ID is set):
#   RUN_ID    stable run-id for this worker
#   RUNS_DIR  where run records live (default: runs)
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

[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
ev="$(jq -r '.hook_event_name // empty' <<<"$input")"
aid="$(jq -r '.agent_id // .agentId // empty' <<<"$input")"
atype="$(jq -r '.agent_type // .agentName // .agent_name // empty' <<<"$input")"
adisp="$(jq -r '.agent_display_name // .agentDisplayName // empty' <<<"$input")"
# The reason the agent was spawned (SubagentStart only); stop_reason (SubagentStop only).
reason="$(jq -r '.agent_description // .agentDescription // empty' <<<"$input")"
sreason="$(jq -r '.stop_reason // .stopReason // empty' <<<"$input")"

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

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
# Append the event AND refresh the heartbeat (started_ts once, last_ts every event) so
# now - last_ts stays a usable idle signal even between tool calls. The base entry keeps
# agent_id/agent_type (back-compat with track-report.sh); the display name, reason, and
# stop_reason keys are added ONLY when non-empty, so records stay clean on surfaces that
# don't supply them.
jq --arg t "$ts" --arg e "$ev" --arg id "$aid" --arg ty "$atype" \
   --arg disp "$adisp" --arg reason "$reason" --arg sr "$sreason" \
  '.trace = ((.trace // []) + [
     ({t:$t, kind:"subagent", event:$e, agent_id:$id, agent_type:$ty})
     + (if $disp   != "" then {agent_display_name:$disp} else {} end)
     + (if $reason != "" then {reason:$reason} else {} end)
     + (if $sr     != "" then {stop_reason:$sr} else {} end)
   ]) | .started_ts = (.started_ts // $t) | .last_ts = $t' \
  "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
