#!/usr/bin/env bash
# track-evidence.sh — PostToolUse: record test-command results into the run record.
#
# Makes the evidence gate tool-recorded instead of model-claimed. When a terminal
# command matches the manifest's test pattern, append { command, response } to
# runs/<RUN_ID>.json so the evidence is captured by the tool, not pasted by the model.
#
# This is the CAPTURE half of the evidence gate. The closing assertion — a fresh,
# passing entry must exist for every required pack row before done is claimed — lives
# in track-evidence-gate.sh (Stop). Capture must run on every PostToolUse so the
# record cannot be back-filled or cherry-picked at the claim moment.
#
# ACCURACY: PostToolUse exposes `tool_response` (a TEXTUAL result, possibly
# truncated) — NOT a numeric exit code. This records what the tool reported; CI
# remains the authoritative pass/fail gate.
#
# Opt-in via env (no-op unless a matcher is set):
#   RUN_ID                  stable run-id for this worker (also the record filename)
#   TRACK_TEST_CMD_PATTERN  ERE matched against the command, e.g.
#                           "go test|uv run pytest|npm (run )?test|pnpm test"
#   TRACK_EVIDENCE_KINDS    (optional) ';'-separated label:ERE pairs that both match
#                           AND tag a command with a pack kind, e.g.
#                           "go-test:go test -race;py:uv run pytest;ts:tsc --noEmit".
#                           A command matching any pair is recorded with that label
#                           so track-evidence-gate.sh can require a fresh, passing
#                           entry per kind. Patterns are repo-supplied, never baked in.
#   RUNS_DIR                where run records live (default: runs)
#
# Each entry also stores a `fingerprint` (HEAD + tracked diff + untracked content
# hashes) so the gate can tell evidence for the CURRENT tree from a stale green run
# captured edits ago.
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
[ -n "${TRACK_TEST_CMD_PATTERN:-}${TRACK_EVIDENCE_KINDS:-}" ] || exit 0

input="$(cat)"
tool="$(jq -r '.tool_name // empty' <<<"$input")"
case "$tool" in run_in_terminal | bash | shell | Bash) ;; *) exit 0 ;; esac

cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
[ -n "$cmd" ] || exit 0

# --- what the command RUNS, not what it merely CONTAINS -----------------------
# Patterns are matched against a sanitised copy of the command, never the raw text.
# Matching raw text lets any command that just *mentions* a test command register as
# evidence for it — and two such commands occur on essentially every run:
#
#   1. Writing the PR body. It embeds the evidence table, which quotes the very
#      commands being matched, so `cat > pr-body.md <<'EOF' … go test ./… … EOF`
#      registers as a passing `go-test`. The report ends up certifying itself.
#   2. Echoing a payload into a hook while debugging, e.g.
#      `echo '{"command":"npx tsc --noEmit"}' | bash track-evidence.sh`.
#
# Both were observed forging a full required-evidence pack on a real run. Two
# removals close them, and neither touches a command that genuinely runs a test:
#   - heredoc BODIES (the `<<EOF … EOF` payload; the command line itself is kept)
#   - quoted string LITERALS (a test command inside quotes is data being passed
#     around, not a suite being run here)
# Prefixes still work — `npx tsc --noEmit` matches a `tsc --noEmit` pattern —
# because only quoted and heredoc-borne text is dropped, not leading words.
cmd_exec="$(printf '%s\n' "$cmd" | awk '
  skip { if ($0 ~ "^[[:space:]]*" delim "[[:space:]]*$") skip=0; next }
  {
    line=$0
    if (match(line, /<<-?[[:space:]]*['"'"'"]?[A-Za-z_][A-Za-z0-9_]*['"'"'"]?/)) {
      d=substr(line, RSTART, RLENGTH)
      sub(/^<<-?[[:space:]]*/, "", d); gsub(/['"'"'"]/, "", d)
      delim=d; skip=1
    }
    print line
  }')"
# Drop quoted literals (single and double). Done after heredoc stripping so an
# unterminated quote inside a heredoc body cannot swallow the rest of the command.
cmd_exec="$(printf '%s' "$cmd_exec" | sed "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")"

# Derive the pack kind from repo-supplied label:pattern pairs (first match wins).
kind=""
kind_pat=""
if [ -n "${TRACK_EVIDENCE_KINDS:-}" ]; then
  saved_ifs="$IFS"; IFS=';'
  for pair in $TRACK_EVIDENCE_KINDS; do
    label="${pair%%:*}"; pat="${pair#*:}"
    [ -n "$label" ] && [ -n "$pat" ] && [ "$label" != "$pair" ] || continue
    if printf '%s' "$cmd_exec" | grep -Eq "$pat"; then kind="$label"; kind_pat="$pat"; break; fi
  done
  IFS="$saved_ifs"
fi

# Record if it matches the test pattern OR any declared kind; tag a default kind.
matched=0
if [ -n "${TRACK_TEST_CMD_PATTERN:-}" ] && printf '%s' "$cmd_exec" | grep -Eq "$TRACK_TEST_CMD_PATTERN"; then
  matched=1; [ -n "$kind" ] || kind="test"
fi
[ -n "$kind" ] && matched=1
[ "$matched" -eq 1 ] || exit 0

# --- pick a concise, single-line command for display --------------------------
# `cmd` (below, in the record write) is the RAW tool call verbatim — often a
# whole shell block (cd / setup / debugging / the real invocation), not just
# the test itself. Showing that whole block as "the command" buries the actual
# invocation under scaffolding, and a literal newline inside it corrupts the PR
# body's evidence table (a markdown table row cannot contain one). `cmd_exec`
# was already computed above for MATCHING with quotes and heredoc bodies
# stripped, so any pattern hit inside it is a real, non-decorative occurrence —
# reuse it to pick which line to show, instead of guessing via truncation
# (which can just as easily cut off before reaching the real invocation). The
# full raw block is preserved as `cmd_full` (only when it actually differs) so
# nothing is lost for an audit that wants the whole picture.
cmd_display="$cmd"
if [ "$(printf '%s\n' "$cmd" | wc -l)" -gt 1 ]; then
  line_pat="$kind_pat"
  if [ -n "${TRACK_TEST_CMD_PATTERN:-}" ]; then
    if [ -n "$line_pat" ]; then line_pat="($line_pat)|(${TRACK_TEST_CMD_PATTERN})"
    else line_pat="$TRACK_TEST_CMD_PATTERN"; fi
  fi
  if [ -n "$line_pat" ]; then
    picked="$(printf '%s\n' "$cmd_exec" | grep -E "$line_pat" | tail -1 || true)"
    [ -n "$picked" ] && cmd_display="$picked"
  fi
fi

resp="$(jq -r '.tool_response // empty' <<<"$input")"

# --- verdict: decided ONCE, here, and recorded -------------------------------
# Previously each consumer re-derived pass/fail by grepping the response text with
# its OWN default pattern — track-evidence-gate.sh and track-report.sh shipped two
# different ones, so the gate and the PR body could grade the same capture
# differently. The verdict is now settled at capture and both read it back.
#
# Signals, strongest first:
#   1. an explicit exit code, when the surface reports one;
#   2. `returnCodeInterpretation` — Claude Code adds this key only when the command
#      exited non-zero (it holds the human-readable reading, e.g. "No matches found");
#   3. failure markers in the output text (last resort — see TRACK_FAIL_PATTERN).
# Text matching alone let two captures that printed `exit: 1` be graded ✅ pass.
exit_code="$(jq -r '(.tool_response.exit_code // .tool_response.exitCode //
                     .tool_response.returncode // .tool_response.status) // empty' <<<"$input" 2>/dev/null || true)"
rci="$(jq -r '.tool_response.returnCodeInterpretation // empty' <<<"$input" 2>/dev/null || true)"

# Shared default. `exit[: ]N` catches the `echo "exit: $?"` idiom agents use to make
# a status visible, which no previous pattern matched.
fail_re="${TRACK_FAIL_PATTERN:-}"
[ -n "$fail_re" ] || fail_re='\bFAIL\b|FAILED|--- FAIL|panic:|Traceback|AssertionError|error TS[0-9]|\bERROR\b|npm ERR!|✖|✗|exit(_code)?:?[[:space:]]*(code|status)?[[:space:]]*[1-9][0-9]*\b|exit code [1-9]|[1-9][0-9]* (failed|error)'

if [ -n "$exit_code" ] && [ "$exit_code" != "0" ] && [ "$exit_code" != "null" ]; then
  verdict="fail"; verdict_by="exit-code:$exit_code"
elif [ -n "$rci" ]; then
  verdict="fail"; verdict_by="nonzero-exit:$rci"
elif printf '%s' "$resp" | grep -Eq "$fail_re"; then
  verdict="fail"; verdict_by="fail-pattern"
else
  verdict="pass"; verdict_by="no-failure-signal"
fi

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

# --- fingerprint the tree the WORK is in, not the hook's CWD -------------------
# HEAD + all tracked (staged+unstaged) changes + untracked (non-ignored) file names
# & content hashes. Including untracked contents closes the hole where a brand-new
# unstaged file's later edits would leave a stale green reading as fresh.
#
# It must be computed in the run branch's WORKTREE. A PostToolUse hook inherits the
# session CWD — the main checkout — even while the agent edits a linked worktree, so
# this used to fingerprint a tree nobody was touching. On one real run that left all
# eight captures sharing a single fingerprint across three days of active file
# creation: the gate's staleness check was inert, and the audit's E1 "every kind's
# latest capture shares one fingerprint (converged)" passed for precisely the wrong
# reason. Resolved from the branch the breadcrumb records, so it needs no new state.
#
# Must match the identical computation in track-evidence-gate.sh.
hash_cmd() { if command -v shasum >/dev/null 2>&1; then shasum; else sha1sum; fi; }
fp_dir() { # echo the dir to fingerprint: the run branch's worktree, else CWD
  _b="$(jq -r '.branch // empty' "$RUNS_DIR/$RUN_ID.dispatch" 2>/dev/null || true)"
  [ -n "$_b" ] || { pwd; return 0; }
  _w="$(git worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$_b" '
          /^worktree /{p=substr($0,10)} /^branch /{if ($2==b){print p; exit}}' || true)"
  [ -n "$_w" ] && [ -d "$_w" ] && printf '%s\n' "$_w" || pwd
}
fingerprint="$(
  cd "$(fp_dir)" 2>/dev/null || true
  {
    git rev-parse HEAD 2>/dev/null || echo no-head
    git diff HEAD 2>/dev/null || true
    u="$(git ls-files --others --exclude-standard 2>/dev/null || true)"
    if [ -n "$u" ]; then
      printf '%s\n' "$u"
      printf '%s\n' "$u" | git hash-object --stdin-paths 2>/dev/null || true
    fi
  } | hash_cmd | cut -d' ' -f1
)"
# Canonical skeleton — identical across track-evidence/-meter/-trace so whichever hook
# fires first writes the same shape (v = run-record schema version).
[ -f "$rec" ] || printf '{"run_id":"%s","v":1,"trace":[],"evidence":[],"tool_calls":0}\n' "$RUN_ID" >"$rec"

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
tmp="$(mktemp)"
jq --arg t "$ts" --arg k "$kind" --arg c "$cmd_display" --arg cf "$cmd" --arg r "$resp" --arg f "$fingerprint" \
   --arg v "$verdict" --arg vb "$verdict_by" \
  '.evidence = ((.evidence // []) + [
      {t:$t, kind:$k, cmd:$c, response:$r, fingerprint:$f, verdict:$v, verdict_by:$vb}
      + (if $c != $cf then {cmd_full:$cf} else {} end)
    ]) | .started_ts = (.started_ts // $t) | .last_ts = $t' "$rec" >"$tmp" && mv "$tmp" "$rec"
exit 0
