#!/usr/bin/env bash
# track-brief.sh — make "the brief actually carried the governance" AUDITABLE.
#
# WHY THIS EXISTS
#   Governance discovery ends by pushing the distilled bundle into every maker and reviewer
#   brief (references/governance.md, Step 3). Until now nothing observed that last hop:
#   G1 proved the bundle exists, G2 that it covers the diff, G3 that it was pinned before the
#   first dispatch, I4 that it was re-read after a compaction — and then the audit's own
#   NOT-CHECKED list admitted the load-bearing step was taken on trust ("A5: maker briefs
#   embed governance CONTENT, not filenames — open a real dispatch and look"). Every
#   mechanical check was a proxy for a hop nobody watched.
#
#   A PreToolUse hook on the dispatch tool DOES see it: the brief is `tool_input.prompt`,
#   in full, before the subagent starts. So the invariant becomes arithmetic like the rest —
#   count how many of the bundle's binding constraint lines appear in the brief text.
#
#   Recorded per dispatch (hook-observed; the model authors none of these numbers):
#     briefs[] — {t, tool, bundle_sha, lines_total, lines_matched, sections[], declared_na}
#
#   track-audit.sh's G6 turns that into a verdict: a dispatch whose brief carried neither
#   bundle content nor an explicit `GOVERNANCE: n/a` declaration is a FAIL.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   Matching text is not judging relevance. A brief can carry three constraint lines that
#   have nothing to do with its cluster and still count here. G6 proves the content made the
#   hop; whether the RIGHT sections were sliced to the RIGHT cluster stays a human read, and
#   the audit's NOT-CHECKED list says so. Never widen this script's claim past "content was
#   present in the brief text".
#
#   It also does not block by default. A false deny costs a dispatch; a false record costs a
#   WARN. Opt in to blocking with TRACK_BRIEF_DENY=1 once a repo trusts the matcher.
#
# EVENTS
#   PreToolUse — the only event that carries the outbound brief. Non-dispatch tools exit 0
#                immediately (Copilot fires PreToolUse on EVERY tool call and cannot scope
#                by matcher, so the early exit is what keeps it cheap).
#
# ENV
#   RUN_ID                 required — no-op without it
#   RUNS_DIR               where run records live (default: runs)
#   TRACK_BRIEF_MIN_LINES  constraint lines a brief must carry to count as governed (default 3,
#                          capped at the bundle's own line count)
#   TRACK_BRIEF_DENY       1 → deny a thin dispatch instead of only recording it (default off)
#
# Requires: jq. Keep runtime < 1s.
set -eufo pipefail

# Bootstrap: load hook presets sitting beside this script, if present:
#   1. track-env.sh       per-worktree LOCAL overrides (gitignored, optional)
#   2. track-env.base.sh  repo-wide COMMITTED defaults (travels into every worktree)
__env_dir="${BASH_SOURCE[0]%/*}"
# Prefer the MAIN checkout's .github/hooks (canonical) when installed, so a hook firing from
# a linked worktree sources the SAME per-run env + RUN_ID block the main-checkout preflight
# wrote — not an absent worktree-local copy.
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
case "$ev" in PreToolUse|preToolUse|"") ;; *) exit 0 ;; esac

tool="$(jq -r '.tool_name // .toolName // empty' <<<"$input" 2>/dev/null || true)"
[ -n "$tool" ] || exit 0

# Is this a subagent dispatch? Tool names differ by surface (Claude Code: Task; others:
# Agent / dispatch_agent / runSubagent / …), so match on shape rather than an exact name —
# and require a prompt-shaped payload below, which is what actually distinguishes a dispatch
# from a same-named list/status tool.
case "$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')" in
  task|*subagent*|*dispatch*|agent|agent_tool|*runagent*|*run_agent*) ;;
  *) exit 0 ;;
esac

# The brief itself. Every known spelling, joined — a surface that splits instructions across
# two fields still gets its full text considered.
brief="$(jq -r '[ .tool_input?.prompt?, .tool_input?.description?, .tool_input?.brief?,
                  .tool_input?.instructions?, .tool_input?.input?, .tool_input?.message?,
                  .toolInput?.prompt?,      .toolInput?.description?,
                  .arguments?.prompt?,      .parameters?.prompt? ]
                | map(select(type == "string" and . != "")) | join("\n")' \
          <<<"$input" 2>/dev/null || true)"
[ -n "$brief" ] || exit 0

RUNS_DIR="${RUNS_DIR:-runs}"
# Anchor a RELATIVE RUNS_DIR to the main working tree so the run record is single-homed
# across the main checkout and any linked worktree.
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
mkdir -p "$RUNS_DIR" 2>/dev/null || true
# Canonical skeleton — identical across track-evidence/-meter/-trace/-compact/-brief so
# whichever hook fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Best-effort throughout: a failure to stamp must never break the dispatch. A dropped stamp
# degrades G6 to a WARN; a crashed hook would degrade the session.
write_rec() { # write_rec <jq args...>
  _tmp="$(mktemp 2>/dev/null || true)"
  [ -n "$_tmp" ] || return 0
  if jq "$@" "$rec" >"$_tmp" 2>/dev/null; then mv "$_tmp" "$rec" 2>/dev/null || rm -f "$_tmp"
  else rm -f "$_tmp"; fi
  return 0
}

# An explicit opt-out, mirroring the bundle's own "state ABSENT, never no-op by omission"
# rule: a read-only research or exploration dispatch genuinely carries no maker constraints,
# and saying so in the brief is a decision on record. A missing declaration is
# indistinguishable from a forgotten one, so only the literal marker counts.
declared_na=false
if printf '%s' "$brief" | grep -Eqi '^[[:space:]]*(>[[:space:]]*)?(\*\*)?GOVERNANCE(\*\*)?:[[:space:]]*(n/?a|none|not applicable)'; then
  declared_na=true
fi

gov_path="$(jq -r '.governance_bundle.path // empty' "$rec" 2>/dev/null || true)"
gov_sha="$(jq -r '.governance_bundle.sha // empty' "$rec" 2>/dev/null || true)"

lines_total=0; lines_matched=0; sections=""
if [ -n "$gov_path" ] && [ -f "$gov_path" ]; then
  # Normalize both sides the same way before comparing: lowercase, collapse runs of
  # non-alphanumerics to single spaces. A brief that re-wraps a constraint across lines, or
  # renders `- ` as `* `, or drops back-ticks, still matches — while a brief that only names
  # the FILE matches nothing, which is exactly the failure A5 was written for.
  norm_brief="$(printf '%s' "$brief" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ')"

  # Signature length: compare the first N normalized chars of each constraint. Long enough
  # that a match is the real line, short enough to tolerate a reworded tail.
  sig_len="${TRACK_BRIEF_SIG_LEN:-40}"

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    norm_line="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ')"
    norm_line="${norm_line# }"; norm_line="${norm_line% }"
    # Skip bullets too short to be a real constraint ("- see below", "- n/a").
    [ "${#norm_line}" -ge 12 ] || continue
    lines_total=$((lines_total + 1))
    sig="$(printf '%s' "$norm_line" | cut -c1-"$sig_len")"
    case "$norm_brief" in *"$sig"*) lines_matched=$((lines_matched + 1)) ;; esac
  done <<<"$(sed -n 's/^[[:space:]]*[-*][[:space:]]\{1,\}//p' "$gov_path" 2>/dev/null || true)"

  # Which bundle sections the brief names. Recorded for the report, NOT scored: naming a
  # section is the filename-passing failure mode, so it must never substitute for content.
  sections="$(sed -n 's/^##[[:space:]]\{1,\}//p' "$gov_path" 2>/dev/null \
    | while IFS= read -r h; do
        key="$(printf '%s' "$h" | sed 's/[[:space:]]*—.*$//' | sed 's/[[:space:]]*$//')"
        [ -n "$key" ] || continue
        if printf '%s' "$brief" | grep -qiF "$key"; then printf '%s\n' "$key"; fi
      done | paste -sd'|' - 2>/dev/null || true)"
fi

# TWO SIGNALS, NOT ONE — because a fan-out brief is SUPPOSED to be a slice.
#
#   thin      = carried ZERO constraint lines while a bundle was pinned. There is no legitimate
#               reading of that: the brief passed filenames, or nothing. This is G6's FAIL and
#               the only condition that can deny.
#   below_min = carried some, but fewer than TRACK_BRIEF_MIN_LINES. A cluster brief embedding
#               only its own two sections lands here, and so does a brief that pasted one line
#               and moved on — the hook cannot tell those apart, so it reports rather than
#               judges, and G6 raises a WARN the reviewer can resolve by looking.
min_lines="${TRACK_BRIEF_MIN_LINES:-3}"
[ "$lines_total" -lt "$min_lines" ] && min_lines="$lines_total"

thin=false; below_min=false
if [ "$declared_na" = "false" ] && [ -n "$gov_path" ]; then
  if [ "$lines_matched" -eq 0 ]; then thin=true
  elif [ "$lines_matched" -lt "$min_lines" ]; then below_min=true
  fi
fi

write_rec --arg t "$ts" --arg tool "$tool" --arg sha "${gov_sha:-}" \
          --argjson tot "$lines_total" --argjson mat "$lines_matched" \
          --argjson min "$min_lines" --arg secs "${sections:-}" \
          --argjson na "$declared_na" --argjson thin "$thin" --argjson bmin "$below_min" \
  '.briefs = ((.briefs // []) + [
      {t:$t, tool:$tool, bundle_sha:$sha, lines_total:$tot, lines_matched:$mat,
       min_lines:$min, declared_na:$na, thin:$thin, below_min:$bmin}
      + (if $secs != "" then {sections: ($secs | split("|"))} else {} end)
    ]) | .last_ts = $t'

# Blocking is opt-in. When it is on, the deny text has to be actionable — an agent that reads
# "denied" learns nothing, an agent that reads which constraints were missing can fix the
# brief and retry.
if [ "$thin" = "true" ] && [ "${TRACK_BRIEF_DENY:-0}" = "1" ]; then
  reason="Dispatch blocked: this brief carries NONE of the $lines_total binding constraints in $gov_path.
Embed the bundle's CONTENT for this cluster — the constraint lines themselves, not the filenames — or, if this dispatch genuinely needs none (read-only research), declare it in the brief:
  GOVERNANCE: n/a — <why>"
  # Both surfaces' deny contracts, same as track-guard.sh: JSON for Claude Code, exit 2 with
  # stderr for Copilot. Emitting both is harmless — each surface reads only its own.
  jq -nc --arg r "$reason" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
  printf '%s\n' "$reason" >&2
  exit 2
fi

exit 0
