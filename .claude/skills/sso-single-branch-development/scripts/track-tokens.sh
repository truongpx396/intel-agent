#!/usr/bin/env bash
# track-tokens.sh — Stop hook: estimate token usage from the session transcript
#                   and enforce a per-worker token ceiling (TRACK_MAX_TOKEN_ESTIMATE).
#
# Fires ONCE when the agent ends a turn (Stop / agentStop). Reads the transcript
# file supplied in the hook payload and writes `token_estimate` + the full
# `token_usage` breakdown into the run record. Both are OVERWRITTEN on every turn
# because the transcript is cumulative — re-reading it always gives the grand total
# for the whole session so far; appending would double-count.
#
# TWO SOURCES, in preference order:
#
#   1. `message.usage` — the provider's OWN per-turn counts, which Claude Code
#      writes verbatim into the transcript. Authoritative, and already inclusive of
#      the system prompt and injected tool schemas (they are part of the cached
#      input). Recorded in full as `token_usage`
#      {input, output, cache_read, cache_write}.
#
#      `token_estimate` — the number the ceiling is enforced on — is
#      input + cache_write + output. cache_read is deliberately EXCLUDED: re-reading
#      an already-cached context is the cheap part, and counting it makes the figure
#      grow with run length rather than with work actually done.
#
#   2. chars/4 over the raw transcript text — fallback for a surface whose
#      transcript carries no usage block. 1 token ≈ 4 characters. UNDERCOUNTS: it
#      cannot see the hidden system prompt, injected tool schemas, or cached tokens.
#
# Transcript schemas differ by surface and BOTH are read (source 2):
#   Claude Code: .type "user"/"assistant"      → .message.content
#   other:       .type "user.message"          → .data.content
#                .type "assistant.message"     → .data.content + .data.reasoningText
#                                                + .data.toolRequests[]
#                .type "tool.execution_start"  → .data.arguments
# Reading only one schema yields 0 chars, which silently disables the ceiling below
# (0 never exceeds it) — so a parser change here is a safety regression, not a
# cosmetic one.
#
# NOTE ON CEILINGS: a TRACK_MAX_TOKEN_ESTIMATE calibrated against the old chars/4
# figure is too low for the authoritative counts, which are several times larger
# because they include the cached system prompt and schemas. Re-tune it on a known-
# good run rather than inheriting the old value.
#
# CEILING ENFORCEMENT (TRACK_MAX_TOKEN_ESTIMATE):
#   TRACK_MAX_TOKEN_ESTIMATE sets a hard ceiling on estimated tokens. When the estimate
#   first exceeds the ceiling the hook:
#     1. Writes `status: "budget-exceeded"` to the run record.
#     2. Prints a clear message with the estimate and ceiling.
#     3. Exits 2 to block the stop — the agent sees the message and knows
#        NOT to open a PR. (Exit 2 is Claude Code's stop-blocking code AND is
#        non-zero, so Copilot blocks on it too.) On the NEXT stop attempt the hook sees `status:
#        "budget-exceeded"` already set and exits 0, allowing the run to end
#        cleanly with the terminal state recorded.
#   This mirrors how track-evidence-gate.sh blocks on a first miss and allows
#   a second stop after the required action (there: capturing evidence; here:
#   the agent acknowledges the budget state and does not open a PR).
#
#   IMPORTANT: the enforcement fires at Stop, not PostToolUse — the agent CANNOT
#   be halted truly mid-turn by this hook. The ceiling is not a billing firewall;
#   it is a "runaway-run" signal. For intra-turn protection set TRACK_MAX_TOOL_CALLS
#   (PostToolUse hook, enforced by track-meter.sh) and configure provider-side
#   budget controls.
#
# CONFIG (set in track-env.base.sh):
#   TRACK_MAX_TOKEN_ESTIMATE   integer ceiling (e.g. 200000). Hook is a no-op when unset
#                        or 0. Set high enough that normal feature work never hits
#                        it — only runaway agents should reach it.
#   RUN_ID               stable run-id for this worker (set by preflight --persist)
#   RUNS_DIR             where run records live (default: runs)
#
# Wire this in track-hooks.json under "stop" (already done in the template).
# It is safe to deploy even without TRACK_MAX_TOKEN_ESTIMATE — the hook is fully no-op.
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

[ "${TRACK_MAX_TOKEN_ESTIMATE:-0}" -gt 0 ] || exit 0
[ -n "${RUN_ID:-}" ] || exit 0

input="$(cat)"
# Read transcript_path — both VS Code snake_case and camelCase spellings.
tp="$(jq -r '.transcript_path // .transcriptPath // empty' <<<"$input")"
[ -n "$tp" ] || exit 0
[ -f "$tp" ] || exit 0

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
[ -f "$rec" ] || exit 0  # run record must already exist (preflight --persist creates it)

# --- source 1 (preferred): the provider's own usage numbers ------------------
# Claude Code records per-turn `message.usage` straight from the API. Those counts
# are authoritative and — unlike the heuristic below — already include the system
# prompt and injected tool schemas, because those live in the (cached) input.
# Summing across turns gives the run total: each turn's input_tokens is that call's
# full context, so the sum is "tokens processed", not "final context size".
usage="$(jq -s '
  [ .[] | select(.message.usage != null) | .message.usage ] as $u
  | if ($u | length) == 0 then empty
    else {
      input:       ([ $u[].input_tokens                 // 0 ] | add),
      output:      ([ $u[].output_tokens                // 0 ] | add),
      cache_read:  ([ $u[].cache_read_input_tokens      // 0 ] | add),
      cache_write: ([ $u[].cache_creation_input_tokens  // 0 ] | add)
    }
    end' "$tp" 2>/dev/null || true)"

chars=0
if [ -n "$usage" ] && [ "$usage" != "null" ]; then
  # The ceiling is enforced on NEW tokens (input + cache writes + output) and
  # deliberately excludes cache_read: re-reading a cached context is the cheap
  # part, and including it makes the number balloon with run length rather than
  # with actual work. The full breakdown is recorded either way.
  estimate="$(jq -r '.input + .cache_write + .output' <<<"$usage")"
  method="transcript message.usage (authoritative; new tokens = input + cache_write + output, excludes cache_read)"
else
  # --- source 2 (fallback): character heuristic over the raw transcript ------
  # Used when the transcript carries no usage block. Both transcript schemas are
  # read: Claude Code nests text under .message.content with a bare .type of
  # "user"/"assistant"; other surfaces use a dotted .type plus a .data payload.
  # Reading only one of the two silently yields 0 — which then disables the
  # ceiling below, since 0 never exceeds it.
  chars="$(jq -r '
    if   .type == "user" or .type == "assistant" then
      (.message.content | if type == "string" then . else (.[]? | tojson) end)
    elif .type == "user.message"         then (.data.content // "")
    elif .type == "assistant.message"    then (
      (.data.content // ""),
      (.data.reasoningText // ""),
      (.data.toolRequests[]? | tojson)
    )
    elif .type == "tool.execution_start" then (.data.arguments | tojson)
    else empty
    end
  ' "$tp" 2>/dev/null | wc -c)"
  chars="$(printf '%s' "$chars" | tr -d '[:space:]')"
  # 1 token ≈ 4 chars. Integer division is intentional — the result is approximate.
  estimate=$(( chars / 4 ))
  method="chars/4 heuristic — undercounts system prompt + injected schemas + cached tokens"
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Every write records the same shape; `extra` appends any status mutation. The
# method string and the usage breakdown live in ONE place so the three exit paths
# below cannot drift apart.
write_estimate() { # write_estimate [extra-jq-filter]
  _tmp="$(mktemp)"
  jq --argjson e "$estimate" --argjson c "${chars:-0}" --arg t "$ts" \
     --arg m "$method" --argjson u "${usage:-null}" \
    ".token_estimate = \$e
     | .token_estimate_chars = \$c
     | .token_estimate_method = \$m
     | .token_usage = \$u
     | .last_ts = \$t${1:+ | $1}" \
    "$rec" >"$_tmp" && mv "$_tmp" "$rec" || rm -f "$_tmp"
}

# --- ceiling check (first exceedance: block stop; second: allow clean exit) --
ceiling="${TRACK_MAX_TOKEN_ESTIMATE:-0}"
if [ "$ceiling" -gt 0 ] && [ "$estimate" -gt "$ceiling" ]; then
  current_status="$(jq -r '.status // empty' "$rec" 2>/dev/null || true)"
  if [ "$current_status" = "budget-exceeded" ]; then
    # Second stop attempt after budget-exceeded was written — record and exit 0.
    write_estimate
    exit 0
  fi
  # First exceedance: write terminal state and block this stop.
  write_estimate '.status = "budget-exceeded"'
  printf '%s\n' \
    "TRACK_TOKENS: TOKEN BUDGET EXCEEDED — estimated ~${estimate} tokens (ceiling: ${ceiling})." \
    "  Run record status set to 'budget-exceeded'." \
    "  DO NOT open a draft PR. Report status to orchestrator and stop cleanly." \
    "  (On the next stop attempt the hook will allow the clean exit.)" >&2
  exit 2   # 2 = Claude Code's stop-blocking code; also non-zero so Copilot blocks too
fi

# --- normal recording (under budget or no ceiling) ---------------------------
# OVERWRITE (not add) — transcript is cumulative so each Stop already gives the
# running grand total. Adding would double-count earlier turns.
write_estimate
exit 0
