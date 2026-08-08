#!/usr/bin/env bash
# track-guard.sh — PreToolUse guard for the sso-executing-parallel-tracks skill.
#
# Makes two of the skill's gates MECHANICAL instead of prompt-trusted:
#   1. Deny-by-default file ownership (per worktree) + frozen entrypoints.
#   2. Worker push/merge lockout — workers stop at `gh pr create --draft`.
#
# Wiring: copy this file + the bundled track-hooks.json into the repo's
# .github/hooks/ directory (the JSON points VS Code / Copilot CLI / cloud agent
# at this script).
# Requires: jq. Keep runtime < 5s — hooks block the agent synchronously.
#
# Per-worktree scope (export BEFORE launching each worker):
#   TRACK_ALLOWED_PREFIXES  colon-separated path prefixes this track may edit, relative to
#                           the git WORKTREE ROOT (never to the hook's CWD), e.g.
#                           "internal/ingest:migrations/0007_:test/ingest".
#                           A path outside every worktree stays absolute, so allowing a
#                           scratch dir means listing it absolutely, e.g. "/tmp/scratch/".
#   TRACK_FROZEN_PATHS      colon-separated exact files no track may edit, e.g.
#                           "cmd/main.go:internal/app/app.go"
#   TRACK_IMMUTABLE_PREFIXES  (optional) colon-separated prefixes whose
#                           already-committed files are append-only, e.g.
#                           "migrations/:backend-go/migrations/". A NEW file under
#                           the prefix is fine; editing one with git history is denied.
#
# Always-on (no env needed): any file whose first 3 lines carry a
# "GENERATED — DO NOT EDIT" banner is denied — re-run its generator instead.
#
# Opt-in destructive-infra guard (off unless set):
#   TRACK_GUARD_DESTRUCTIVE  set to any value to also deny irreversible data/infra
#                            shell commands (DROP/TRUNCATE, unbounded DELETE, Redis
#                            FLUSHALL/FLUSHDB, NATS stream/consumer teardown,
#                            rm -rf on an absolute/home path). Tune per stack.
#
# Opt-in fast-forward push (off unless set):
#   TRACK_ALLOW_FF_PUSH      set to any value to permit a plain `git push` (e.g. a
#                            PR-rework flow updating an existing PR branch). --force,
#                            --no-verify, gh pr merge, git merge, and reset --hard
#                            stay denied, so only a fast-forward push is allowed.
#
# NOTE: Copilot/VS Code ignores hook "matchers", so under that surface this script
# fires on EVERY tool call and branches on tool_name itself. Claude Code DOES scope
# by matcher (see the .claude/settings.json wiring), but the branching stays so a
# single script serves both surfaces. Tool names / input keys differ across
# surfaces — VS Code: create_file / replace_string_in_file + run_in_terminal,
# camelCase tool_input.filePath; Claude Code: Write / Edit / MultiEdit + Bash,
# snake_case file_path / command. All are handled below.
set -eufo pipefail   # -f: no globbing (path prefixes are literal, never patterns)

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
tool="$(jq -r '.tool_name // empty' <<<"$input")"

deny() {
  jq -nc --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# Normalize a tool-supplied path to a path relative to the git worktree ROOT it
# belongs to. TRACK_ALLOWED_PREFIXES is written relative to the worktree root, so the
# comparison is only meaningful against a root-relative path — and the hook's $PWD is
# NOT a reliable stand-in for that root. Two ways it drifts, both observed in real runs:
#
#   * a sibling WORKTREE holds the isolated work while the agent (and $PWD) stay rooted
#     in the main checkout, and
#   * a plain `cd` into a subdirectory in an earlier Bash call — after which a $PWD-strip
#     yields "contracts/agent-graph.md" for a file the scope names as
#     "specs/001-x/contracts/agent-graph.md".
#
# Both end the same way: the relativized path never matches a prefix, every scoped write
# is denied (fail-closed), and the pressure is toward ungoverned terminal-heredoc writes.
# So resolve against the worktree root UNCONDITIONALLY — relative inputs included, since
# a bare "contracts/x.md" typed from a subdirectory is exactly the case that used to slip
# through. `git rev-parse --show-prefix` is git's own answer to "where am I inside this
# worktree?", which also sidesteps the string-strip mismatch when a checkout is reached
# through a symlink (/tmp on macOS) and git reports the physical path instead. create_file
# targets — and their parent dirs — may not exist yet, so resolve from the deepest
# EXISTING ancestor and re-attach the not-yet-created tail.
#
# Emits TWO lines: the discovered worktree root (may be empty) and the root-relative path.
# The root has to come back through STDOUT rather than a global, because the caller reads
# this function in a command substitution — a variable it sets dies with that subshell.
# That is why the immutable-prefix check silently fell back to `$PWD` and stopped matching
# whenever the hook's CWD was not the worktree root: exactly the sibling-worktree case the
# root-tracking was added for, so the check quietly passed everything it was meant to stop.
GIT_WT_ROOT=""
_git_relpath() {
  p_in="$1"
  case "$p_in" in
    /*) ;;                                   # absolute → resolve below
    *)  p_in="$PWD/$p_in" ;;                 # relative → make absolute, then resolve alike
  esac
  d="${p_in%/*}"; [ -n "$d" ] || d="/"       # dir part + the tail we must re-attach
  tail="${p_in##*/}"
  while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do
    tail="${d##*/}/$tail"; d="${d%/*}"; [ -n "$d" ] || d="/"
  done
  if pfx="$(git -C "$d" rev-parse --show-prefix 2>/dev/null)"; then
    printf '%s\n%s\n' "$(git -C "$d" rev-parse --show-toplevel 2>/dev/null || true)" "$pfx$tail"
  else
    printf '%s\n%s\n' "" "${p_in#"$PWD"/}"   # outside any worktree → legacy behavior
  fi
}

case "$tool" in
  create_file | replace_string_in_file | multi_replace_string_in_file | edit_notebook_file | Write | Edit | MultiEdit | NotebookEdit)
    # Collect every target path this edit touches, across surface variants.
    # NotebookEdit (Claude Code) carries its target as tool_input.notebook_path.
    paths="$(jq -r '
      [ .tool_input.filePath?,
        .tool_input.file_path?,
        .tool_input.notebook_path?,
        (.tool_input.replacements[]?.filePath),
        (.tool_input.edits[]?.file_path) ]
      | map(select(. != null and . != "")) | .[]' <<<"$input")"
    [ -z "$paths" ] && exit 0

    while IFS= read -r p; do
      [ -z "$p" ] && continue
      # Root + relative path, both read back from stdout (see _git_relpath on why the root
      # cannot be a global). GIT_WT_ROOT then aims the banner + immutable-history checks at
      # the tree the path actually lives in, not at whatever the hook's CWD happens to be.
      { IFS= read -r GIT_WT_ROOT; IFS= read -r rel; } <<<"$(_git_relpath "$p")"

      # Frozen entrypoints: never editable by any track (tracks self-register).
      saved_ifs="$IFS"; IFS=:
      for f in ${TRACK_FROZEN_PATHS:-}; do
        [ "$rel" = "$f" ] && { IFS="$saved_ifs";
          deny "frozen entrypoint '$rel' — self-register via your track's own file instead of editing the shared entrypoint"; }
      done
      IFS="$saved_ifs"

      # Deny-by-default: the path MUST match an allowed prefix.
      ok=0
      saved_ifs="$IFS"; IFS=:
      for a in ${TRACK_ALLOWED_PREFIXES:-}; do
        case "$rel" in "$a"*) ok=1 ;; esac
      done
      IFS="$saved_ifs"
      [ "$ok" -eq 1 ] ||
        deny "'$rel' is outside this track's ownership scope (set TRACK_ALLOWED_PREFIXES); editing it would become a merge conflict at integration"

      # Generated files are never hand-edited — re-run the generator (always-on).
      # Test the ORIGINAL path ($p), which resolves regardless of $PWD vs worktree.
      if [ -f "$p" ] && head -3 "$p" 2>/dev/null | grep -q "GENERATED — DO NOT EDIT"; then
        deny "'$rel' is generated (carries a 'GENERATED — DO NOT EDIT' banner) — re-run its generator instead of editing it by hand"
      fi

      # Immutable prefixes: an already-committed file (e.g. an applied migration)
      # is append-only. A brand-new file under the prefix is allowed. Query the
      # worktree the path lives in (GIT_WT_ROOT), not $PWD, so a sibling-worktree
      # branch's history is checked — falling back to $PWD when root is unknown.
      saved_ifs="$IFS"; IFS=:
      for m in ${TRACK_IMMUTABLE_PREFIXES:-}; do
        case "$rel" in
          "$m"*)
            if git -C "${GIT_WT_ROOT:-$PWD}" log --oneline -1 -- "$rel" 2>/dev/null | grep -q .; then
              IFS="$saved_ifs"
              deny "'$rel' is an already-committed artifact under an immutable prefix ($m) — create a NEW file instead of editing it"
            fi ;;
        esac
      done
      IFS="$saved_ifs"
    done <<<"$paths"
    ;;

  run_in_terminal | bash | shell | Bash)
    cmd="$(jq -r '.tool_input.command // .tool_input.bash // empty' <<<"$input")"
    # History rewrites, merges, and gate bypass are ALWAYS denied — even when
    # fast-forward push is opted in below (this catches `git push --force`).
    case "$cmd" in
      *"gh pr merge"* | *"git merge "* | *"git reset --hard"*)
        deny "blocked by autonomy boundary: merging/rewriting history is the merge gate's job (human or merge queue), not the worker's." ;;
    esac
    # `--force` / `--no-verify` are the flags that matter HERE, but neither spelling is
    # git's alone: a raw substring match denies every unrelated tool that happens to take
    # one (`specify integration install claude --force`, `npm ci --force`, `uv pip install
    # --force-reinstall`) and explains itself with a message about rewriting git history
    # that makes no sense for the command being run. That is a false positive with no
    # in-bounds alternative, which is the shape of rule that gets worked around rather
    # than obeyed. Scope the check to the segments that actually invoke git/gh — split on
    # shell separators first, so `foo --force && git push --force` still trips on its
    # SECOND segment and nothing is smuggled through in a compound command.
    while IFS= read -r seg; do
      case "$seg" in
        *"git "* | *"gh "*) ;;
        *) continue ;;
      esac
      case "$seg" in
        *"--force"* | *"--no-verify"*)
          deny "blocked by autonomy boundary: '--force'/'--no-verify' on a git/gh command ('$seg') — merging/rewriting history is the merge gate's job (human or merge queue), not the worker's. Non-git tools that take a --force flag are unaffected." ;;
      esac
    done <<<"$(printf '%s' "$cmd" | tr ';&|\n' '\n\n\n\n')"
    # `git push` lockout — workers normally stop at `gh pr create --draft`. Two
    # carve-outs, and nothing else gets through:
    #
    #   1. TRACK_ALLOW_FF_PUSH — explicit opt-in for a PR-rework flow that updates an
    #      already-published branch. The always-deny block above still bars --force.
    #
    #   2. The FIRST publish of the worker's own branch. `gh pr create` cannot open a PR
    #      for a branch the remote has never seen; non-interactively it fails outright
    #      rather than offering to push. Denying this made the skill's OWN documented
    #      terminal step unreachable, leaving a worker no in-bounds move — on a real run
    #      that pressure produced exactly the predictable outcome: the worker self-granted
    #      TRACK_ALLOW_FF_PUSH, a flag documented for a different purpose, to get unstuck.
    #      A rule with no compliant path does not produce compliance, it produces
    #      workarounds, so the compliant path is now explicit and narrow.
    #
    # The carve-out is deliberately the narrowest thing that reaches `gh pr create`: it
    # publishes ONE branch ONCE. A second push of the same branch is an update and still
    # requires the opt-in, so the rework flag keeps its documented meaning.
    is_first_publish() { # is_first_publish <cmd> — 0 only for a branch-publishing push
      _c="$1"
      # Bulk/destructive push modes are never a publish (--force is denied above).
      case "$_c" in
        *--delete*|*--mirror*|*--all*|*--tags*|*--prune*|*" -d "*) return 1 ;;
      esac
      _wt="${GIT_WT_ROOT:-$PWD}"
      _cur="$(git -C "$_wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
      { [ -n "$_cur" ] && [ "$_cur" != "HEAD" ]; } || return 1
      # Never publish the base/default branch — that is the merge gate's ref, not ours.
      _def="${TRACK_DEFAULT_BRANCH:-}"
      [ -n "$_def" ] || { _b="${TRACK_BASE_REF:-}"; _def="${_b##*/}"; }
      [ -n "$_def" ] || _def="main"
      [ "$_cur" != "$_def" ] || return 1
      _rem="$(git -C "$_wt" config --get "branch.$_cur.remote" 2>/dev/null || echo origin)"
      [ -n "$_rem" ] || _rem=origin
      # Already on the remote → this is an update, not a first publish. Needs the opt-in.
      ! git -C "$_wt" rev-parse --verify --quiet "refs/remotes/$_rem/$_cur" >/dev/null 2>&1 || return 1
      # A refspec, if present, must name THIS branch — no `HEAD:main` style redirection.
      _spec="$(printf '%s' "$_c" | sed -n 's/.*git push//p' | tr ' \t' '\n\n' \
               | grep -v '^-' | grep -v "^${_rem}$" | grep -v '^$' | tail -1 || true)"
      case "$_spec" in
        ""|HEAD|"$_cur"|"HEAD:$_cur"|"$_cur:$_cur") return 0 ;;
        *) return 1 ;;
      esac
    }
    case "$cmd" in
      *"git push"*)
        if [ -n "${TRACK_ALLOW_FF_PUSH:-}" ]; then
          :   # explicit opt-in (PR-rework); --force et al. still denied above
        elif is_first_publish "$cmd"; then
          :   # first publish of this worker's own branch — the path to `gh pr create`
        else
          deny "blocked by autonomy boundary: workers stop at 'gh pr create --draft'. Pushing is the merge gate's job. (Publishing your own branch for the first time is allowed so 'gh pr create' can reach the remote; this push is an update, a different branch, or a bulk/destructive mode. Set TRACK_ALLOW_FF_PUSH=1 for a PR-rework flow that updates an already-published branch.)"
        fi ;;
    esac

    # OPTIONAL destructive-infra guard — irreversible data/infra ops. Off unless
    # TRACK_GUARD_DESTRUCTIVE is set; case-insensitive; tune patterns per stack.
    if [ -n "${TRACK_GUARD_DESTRUCTIVE:-}" ]; then
      shopt -s nocasematch
      case "$cmd" in
        *"drop table"* | *"drop database"* | *"drop schema"* | *truncate*)
          deny "blocked: irreversible schema op in '$cmd'. Express it as a reversible migration, not an ad-hoc DROP/TRUNCATE." ;;
        *flushall* | *flushdb*)
          deny "blocked: Redis FLUSHALL/FLUSHDB wipes shared state. Scope deletions to your own keys instead." ;;
        *"nats stream rm"* | *"nats stream delete"* | *"nats stream purge"* | *"nats consumer rm"* | *"nats consumer delete"*)
          deny "blocked: NATS stream/consumer teardown touches shared infra. Leave topology changes to the platform owner." ;;
        *"rm -rf /"* | *"rm -fr /"* | *"rm -rf ~"* | *"rm -fr ~"*)
          deny "blocked: 'rm -rf' on an absolute or home path. Delete only within the repo/worktree." ;;
      esac
      # Unbounded DELETE (no WHERE) wipes a whole table.
      case "$cmd" in
        *"delete from"*)
          case "$cmd" in
            *where*) : ;;
            *) deny "blocked: 'DELETE FROM' with no WHERE clause wipes the whole table. Add a WHERE filter." ;;
          esac ;;
      esac
      shopt -u nocasematch
    fi
    ;;
esac

exit 0
