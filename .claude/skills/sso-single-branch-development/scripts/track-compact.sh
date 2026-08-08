#!/usr/bin/env bash
# track-compact.sh — make context compaction AUDITABLE.
#
# WHY THIS EXISTS
#   A compaction happens INSIDE a live session: no SessionStart fires, track-reconcile.sh
#   does not re-run, and everything held only in the conversation is silently dropped —
#   starting with the governance excerpts every subagent brief depends on. The failure is
#   invisible by construction: post-compaction briefs get thinner while the model keeps
#   reporting full compliance. tests/prompt-level-checklist.md calls B2 ("after any
#   compaction, the bundle was RE-READ from disk before the next dispatch") the
#   highest-value manual check on the list, precisely because nothing recorded it.
#
#   This script records it. Two facts, both hook-observed, neither authored by the model:
#     compactions[]       — a compaction occurred, and when          (PreCompact/PostCompact)
#     governance_reads[]  — the pinned bundle was read from disk, and when   (PostToolUse)
#
#   With both on record, "was the bundle re-read after the compaction and BEFORE the next
#   subagent was dispatched?" becomes timestamp arithmetic over durable artifacts. That is
#   track-audit.sh's I4 check. The invariant stops being something a reviewer has to take
#   on trust and becomes something the run either proves or fails.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   A Read proves the bundle was pulled back into context. It does NOT prove the next brief
#   actually carried those constraints — that remains a human check, and the audit says so
#   rather than implying the stronger claim. Never widen this script's claim to cover it.
#
# EVENTS (branches on hook_event_name; unknown events are a silent no-op, so wiring it to
# a surface that lacks compaction events costs nothing):
#   PreCompact / PostCompact  → append {t, trigger} to compactions[]
#   PostToolUse               → if the call touched the pinned bundle, append to
#                               governance_reads[]. Matches a Read (tool_input.file_path)
#                               or a Bash/Grep command mentioning the path, since a re-read
#                               is just as legitimately `cat runs/<id>.governance.md`.
#
# Wire PostToolUse with a matcher (Read|Bash|Grep) where the surface supports one; on
# fire-on-every-call surfaces the early exits below keep it cheap.
#
# Opt-in / no-op unless RUN_ID is set. Requires: jq. Keep runtime < 1s.
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
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

if [ -t 0 ]; then input=""; else input="$(cat 2>/dev/null || true)"; fi
[ -n "$input" ] || exit 0

ev="$(jq -r '.hook_event_name // .hookEventName // empty' <<<"$input" 2>/dev/null || true)"
[ -n "$ev" ] || exit 0

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
# Canonical skeleton — identical across track-evidence/-meter/-trace/-compact so whichever
# hook fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Best-effort throughout: a failure to stamp must never break the tool call or the
# compaction itself. A dropped stamp degrades the audit to a WARN; a crashed hook
# would degrade the session.
write_rec() { # write_rec <jq-filter> [args...]
  _tmp="$(mktemp 2>/dev/null || true)"
  [ -n "$_tmp" ] || return 0
  if jq "$@" "$rec" >"$_tmp" 2>/dev/null; then mv "$_tmp" "$rec" 2>/dev/null || rm -f "$_tmp"
  else rm -f "$_tmp"; fi
  return 0
}

case "$ev" in
  PreCompact|PostCompact|preCompact|postCompact)
    # Both are recorded, deduped by event: a surface may expose only one of them, and a
    # PreCompact with no matching PostCompact still proves a compaction was entered.
    trigger="$(jq -r '.trigger // .matcher // empty' <<<"$input" 2>/dev/null || true)"
    write_rec --arg t "$ts" --arg e "$ev" --arg g "${trigger:-unknown}" \
      '.compactions = ((.compactions // []) + [{t:$t, event:$e, trigger:$g}])
       | .last_ts = $t'
    exit 0
    ;;

  PostToolUse|postToolUse)
    # Only interesting if a governance bundle has actually been pinned — without a path
    # there is nothing to recognise a re-read OF.
    gov_path="$(jq -r '.governance_bundle.path // empty' "$rec" 2>/dev/null || true)"
    [ -n "$gov_path" ] || exit 0

    tool="$(jq -r '.tool_name // .toolName // empty' <<<"$input" 2>/dev/null || true)"
    # A re-read is a Read of the file, or any command that names it (cat/head/grep/rg).
    # Both spellings of the path field, both surfaces' casing.
    target="$(jq -r '[.tool_input.file_path?, .tool_input.filePath?, .tool_input.notebook_path?,
                      .tool_input.command?, .tool_input.bash?, .tool_input.pattern?, .tool_input.path?]
                     | map(select(. != null and . != "")) | join(" ")' <<<"$input" 2>/dev/null || true)"
    [ -n "$target" ] || exit 0

    # Substring match on the pinned path. The bundle path is run-scoped
    # (runs/<RUN_ID>.governance.md), so it is specific enough not to collide.
    case "$target" in
      *"$gov_path"*)
        # Record WHAT matched, not just that something did. `{t, tool}` alone reads as
        # "at 09:27 some Bash command mentioned the bundle" — which cannot distinguish a
        # real `cat runs/<id>.governance.md` re-read from a command that merely names the
        # path in passing. Truncated because a matching command can be a whole heredoc.
        write_rec --arg t "$ts" --arg tool "${tool:-unknown}" --arg via "$target" \
          '.governance_reads = ((.governance_reads // []) + [{t:$t, tool:$tool, via:($via[0:200])}])
           | .last_ts = $t'
        ;;
    esac
    exit 0
    ;;
esac

exit 0
