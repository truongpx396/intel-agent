#!/usr/bin/env bash
# track-note.sh — SELF-REPORTED run annotations. NOT a hook, NOT mechanically observed.
#
# The meter/trace/evidence hooks only record what a PostToolUse/Subagent hook can
# actually see (tool-call count, subagent spawns, test output). Several things the model
# knows but no hook can observe are (1) which skill it is currently executing, (2) how
# many implement→review loops it has run, (3) WHERE IN THE PIPELINE the run currently
# is, (4) that the run has reached a non-success terminal state, and (5) where the
# persisted governance bundle lives. This CLI lets the skill *assert* those into the run
# record — so they are the model's own claim, not a verified fact.
#
# To keep that honest, everything written here is provenance-tagged:
#   - skills[] entries carry  self_reported:true
#   - the loop counter lives in  iterations  and a mirror  iterations_self_reported:true
#     flag is set the first time it is touched, so a reader can never mistake either
#     array/scalar for hook-observed truth.
#   - phase / status / governance_bundle each carry  self_reported:true  inside the object.
#
# WHY phase/status/governance EXIST (the compaction problem)
#   A long run gets its context compacted mid-flight. Compaction is NOT a new session, so
#   SessionStart (and therefore track-reconcile.sh) does not fire, and the model silently
#   loses: which execution core it chose, whether the RED suite is frozen, which increment
#   it was on, and the governance excerpts it must embed in every subagent brief.
#   Evidence freshness cannot recover any of that — it only says which test kinds are
#   current. These three subcommands put that position in a FILE, so a compacted (or
#   crashed) session re-anchors from durable state instead of re-reading the worktree,
#   which the skill's own resume invariant forbids.
#
# Wire it from the SKILL prompt (not track-hooks.json): call `note skill …` at the top
# of each core step, `note loop …` once per RED→GREEN→review cycle, `note phase …` at
# EVERY pipeline-step boundary (mandatory — it is the resume anchor), `note governance …`
# once the bundle is persisted, and `note status …` on any non-success terminal state.
#
# Usage (no-op unless RUN_ID is set):
#   track-note.sh skill <name> [step]        append {t, skill, step, self_reported:true} to skills[]
#   track-note.sh loop  [phase]              iterations += 1  (+ optional phase label on the mark)
#   track-note.sh phase <mode> <step>        SET phase={mode,step,t} (overwritten) + append phase_log[]
#   track-note.sh governance <file>          SET governance_bundle={path,sha,t} — the persisted bundle
#                                            AND append the same to governance_stamps[] (the pin
#                                            HISTORY, so a legitimate mid-core re-pin is on record)
#   track-note.sh status <state> [blocker] [next_step]
#                                            SET status (+ blocker/next_step). state must be one of
#                                            success | blocked | no-progress | budget-exceeded
#
# Opt-in via env:
#   RUN_ID    stable run-id for this worker  (REQUIRED — no-op when unset)
#   RUNS_DIR  where run records live (default: runs)
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present (same contract as
# the hooks: local worktree overrides win over repo base, and an exported value wins
# over both via ${VAR:-default}). No-op when a file is absent.
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

sub="${1:-}"
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
# Canonical skeleton — identical across track-evidence/-meter/-trace/-note so whichever
# writer fires first stamps the same shape (v = run-record schema version). skills[] /
# iterations are added by the mutation below, never by the skeleton, to preserve that
# byte-for-byte invariant.
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"

case "$sub" in
  skill)
    name="${2:-}"
    [ -n "$name" ] || { printf '%s\n' "track-note: 'skill' needs a name." >&2; exit 2; }
    step="${3:-}"
    # Append the activation + refresh the heartbeat (started_ts once, last_ts every event).
    jq --arg t "$ts" --arg s "$name" --arg st "$step" \
      '.skills = ((.skills // []) + [{t:$t, skill:$s, step:$st, self_reported:true}])
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  loop)
    phase="${2:-}"
    # Increment the loop counter, tag its provenance once, and (if a phase was given)
    # drop a timestamped mark so the loop timeline is reconstructable, not just a total.
    jq --arg t "$ts" --arg p "$phase" \
      '.iterations = ((.iterations // 0) + 1)
       | .iterations_self_reported = true
       | (if $p != "" then .iteration_log = ((.iteration_log // []) + [{t:$t, phase:$p}]) else . end)
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  phase)
    # DURABLE PIPELINE POSITION — the compaction/crash re-anchor. `phase` is a single
    # object that is OVERWRITTEN each call (the answer to "where am I now?"), while
    # phase_log[] keeps the append-only history (the answer to "how did I get here?").
    # Both are needed: reconcile reads the scalar, an auditor reads the log.
    mode="${2:-}"
    step="${3:-}"
    [ -n "$mode" ] && [ -n "$step" ] \
      || { printf '%s\n' "track-note: 'phase' needs <mode> <step> (e.g. story red-review)." >&2; rm -f "$tmp"; exit 2; }
    jq --arg t "$ts" --arg m "$mode" --arg s "$step" \
      '.phase = {mode:$m, step:$s, t:$t, self_reported:true}
       | .phase_log = ((.phase_log // []) + [{t:$t, mode:$m, step:$s}])
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  governance)
    # Pin the PERSISTED governance bundle so a compacted session can re-read the binding
    # constraints from disk instead of from a context window that no longer holds them.
    # The sha lets a reader tell whether the bundle changed after briefs were built.
    file="${2:-}"
    [ -n "$file" ] || { printf '%s\n' "track-note: 'governance' needs a file path." >&2; rm -f "$tmp"; exit 2; }
    [ -f "$file" ] || { printf '%s\n' "track-note: governance bundle '$file' does not exist — persist it first." >&2; rm -f "$tmp"; exit 2; }
    sha="$( { if command -v shasum >/dev/null 2>&1; then shasum "$file"; else sha1sum "$file"; fi; } | cut -d' ' -f1)"
    # `governance_bundle` is the CURRENT pin (overwritten); `governance_stamps[]` is the
    # history (append-only). Both exist because a run legitimately re-pins mid-core: when a
    # later cluster drags in an instruction file the first pass did not match, the correct
    # move is re-distil → re-pin, and with only the overwritten field on record that looked
    # identical to "governance was stamped AFTER the first dispatch" — G3 failed the run for
    # doing the right thing. The history lets G3 ask the accurate question instead: was every
    # dispatch preceded by SOME pin?
    jq --arg t "$ts" --arg p "$file" --arg sha "$sha" \
      '.governance_bundle = {path:$p, sha:$sha, t:$t, self_reported:true}
       | .governance_stamps = ((.governance_stamps // [])
           + [{t:$t, path:$p, sha:$sha, self_reported:true}])
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  status)
    # TERMINAL STATE. Blocked/exhausted runs are not successes — naming them in the record
    # is what stops a worker dressing one up as done. Constrained to the same four states
    # sso-executing-parallel-tracks routes on, so a solo run and a fleet worker report alike.
    # NOTE: track-meter.sh (no-progress) and track-tokens.sh (budget-exceeded) also write
    # `status` mechanically; this is the model-asserted path for the states no hook sees.
    state="${2:-}"
    case "$state" in
      success|blocked|no-progress|budget-exceeded) ;;
      *) printf '%s\n' "track-note: 'status' needs one of: success | blocked | no-progress | budget-exceeded (got '${state:-<none>}')." >&2; rm -f "$tmp"; exit 2 ;;
    esac
    blocker="${3:-}"
    next_step="${4:-}"
    jq --arg t "$ts" --arg s "$state" --arg b "$blocker" --arg n "$next_step" \
      '.status = $s
       | .status_self_reported = true
       | (if $b != "" then .blocker = $b else . end)
       | (if $n != "" then .next_step = $n else . end)
       | .started_ts = (.started_ts // $t) | .last_ts = $t' \
      "$rec" >"$tmp" && mv "$tmp" "$rec"
    ;;
  *)
    rm -f "$tmp"
    printf '%s\n' "track-note: unknown subcommand '${sub:-<none>}' (want: skill | loop | phase | governance | status)." >&2
    exit 2
    ;;
esac
exit 0
