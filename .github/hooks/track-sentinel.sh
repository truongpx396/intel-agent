#!/usr/bin/env bash
# track-sentinel.sh — Stop: last mechanical scan of the STAGED diff before a worker
# hands off. If it spots a likely secret or a debug leftover, it BLOCKS the stop so
# the agent cleans up before the draft PR — these never reach review.
#
# Opt-in (no-op unless enabled); honors stop_hook_active so it can't loop forever.
#   TRACK_SENTINEL          set to any value to enable the scan
#   TRACK_SECRET_PATTERN    (optional) override the secret-detection ERE
#   TRACK_LEFTOVER_PATTERN  (optional) override the debug-leftover ERE
#
# Blocks via Stop {decision:"block", reason} — the agent receives `reason` and keeps
# working. Scans only ADDED lines of `git diff --cached` (what's actually staged).
# Requires: jq, git. Keep runtime < 5s — hooks block the agent synchronously.
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

input="$(cat)"
[ -n "${TRACK_SENTINEL:-}" ] || exit 0

# Already blocked once this turn → don't trap the agent in a stop loop.
active="$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null || echo false)"
[ "$active" = "true" ] && exit 0

# Only what's staged for the handoff commit; added lines only (skip context/removed).
added="$(git diff --cached -U0 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
[ -n "$added" ] || exit 0

block() {
  jq -nc --arg r "$1" '{decision:"block", reason:$r}'
  exit 0
}

# Defaults are conservative to avoid false positives; override via env per stack.
# (Assigned on their own lines — embedding {n,} braces in a ${VAR:-...} default
#  can confuse bash brace matching.)
secret_re="${TRACK_SECRET_PATTERN:-}"
[ -n "$secret_re" ] || secret_re='(aws_secret_access_key|api[_-]?key|secret[_-]?key|private[_-]?key|passwd|password|token)[[:space:]]*[:=][[:space:]]*[^[:space:]]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|sk-[A-Za-z0-9]{20,}'

leftover_re="${TRACK_LEFTOVER_PATTERN:-}"
[ -n "$leftover_re" ] || leftover_re='console\.(log|debug)\(|debugger;|binding\.pry|breakpoint\(\)|TODO\(claude\)|FIXME'

if printf '%s\n' "$added" | grep -Eiq "$secret_re"; then
  block "Sentinel: the staged diff contains a likely secret (API key / token / private key / hardcoded password). Move it to an env var or secret store and unstage it before finishing."
fi

if printf '%s\n' "$added" | grep -Eq "$leftover_re"; then
  block "Sentinel: the staged diff has debug leftovers (console.log/debug, debugger, breakpoint, TODO(claude), FIXME). Remove them before handing off the draft PR."
fi

exit 0
