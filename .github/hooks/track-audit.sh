#!/usr/bin/env bash
# track-audit.sh — pre-completion discipline audit. Answers "did this run actually
# follow the pipeline?" from DURABLE ARTIFACTS ONLY (run record + governance bundle +
# git diff), never from the model's account of itself.
#
# WHY THIS EXISTS
#   The hooks enforce the mechanical gates (paths, forbidden commands, counters) and the
#   evidence gate enforces freshness. Neither can see whether the run was DISCIPLINED:
#   was governance read before the first subagent, was the RED suite actually red, was
#   the reviewer a different agent than the maker, did the phases advance at all. Those
#   invariants lived only in tests/prompt-level-checklist.md — a document that has to be
#   remembered to be worth anything. This script runs the subset of that checklist which
#   is genuinely derivable, in about a second, so a "done" claim can be gated on it.
#
# THE HONESTY RULE (read before adding a check)
#   This script MUST NOT imply it verified something it cannot. Every check here is
#   derived from an artifact; everything else is printed under MANUAL as an explicit
#   "not checked here — audit by hand" list. A green audit that quietly skipped the hard
#   half is worse than no audit, because it manufactures exactly the false confidence
#   the pipeline exists to prevent. When in doubt, WARN or move it to MANUAL — never
#   invent a PASS.
#
# VERDICTS
#   FAIL — a durable artifact contradicts the pipeline contract. Exits 2 (blocks).
#   WARN — suspicious, or unverifiable on this surface. Never blocks; always printed.
#   PASS — an artifact positively confirms the check.
#   MANUAL — deliberately not mechanizable; listed so it cannot be silently forgotten.
#
# TWO MODES — deliberately split
#   CLI (default)   Always available. Run it by hand any time, and at the draft-PR
#                   boundary before `gh pr create`. Exits 2 on FAIL.
#   --hook          Stop-hook mode: OPT-IN via TRACK_AUDIT=1, honors stop_hook_active,
#                   and blocks with {decision:"block", reason} like the other Stop gates.
#   The split matters. Auditing on every Stop by default would break the bundle's
#   no-op-until-configured contract: a repo that adopts the hooks but not the governance
#   discipline would suddenly be unable to end a session. The CLI is free; the blocking
#   gate is a choice you make.
#
# Usage (no-op unless RUN_ID is set or recoverable from a breadcrumb):
#   track-audit.sh            human-readable report; exit 2 if any FAIL
#   track-audit.sh --json     same verdicts as JSON, for tooling / CI
#   track-audit.sh --warn-only  never exit non-zero (report, don't block)
#   track-audit.sh --hook     Stop-hook mode (requires TRACK_AUDIT=1)
#
# Env: RUN_ID, RUNS_DIR, TRACK_BASE_REF, TRACK_DEFAULT_BRANCH, TRACK_FAIL_PATTERN,
#      TRACK_TRUST_BOUNDARY_PATTERN, TRACK_AUDIT (enables --hook blocking)
# Requires: jq, git. Keep runtime < 5s.
set -eufo pipefail

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

mode_out="text"; blocking=1; hook_mode=0
for a in "$@"; do
  case "$a" in
    --json) mode_out="json" ;;
    --warn-only) blocking=0 ;;
    --hook) hook_mode=1 ;;
  esac
done

# Stop-hook mode: opt-in, and never loop. Both guards come first so an unconfigured
# repo pays nothing and a blocked stop can still eventually end.
if [ "$hook_mode" -eq 1 ]; then
  [ -n "${TRACK_AUDIT:-}" ] || exit 0
  if [ -t 0 ]; then hook_input=""; else hook_input="$(cat 2>/dev/null || true)"; fi
  active="$(jq -r '.stop_hook_active // false' <<<"${hook_input:-\{\}}" 2>/dev/null || echo false)"
  [ "$active" = "true" ] && exit 0
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

# Self-recover RUN_ID from the newest breadcrumb, same contract as track-reconcile.sh.
if [ -z "${RUN_ID:-}" ]; then
  newest=""; newest_mt=0
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    mt="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
    [ "$mt" -gt "$newest_mt" ] && { newest_mt="$mt"; newest="$f"; }
  done <<<"$(find "$RUNS_DIR" -maxdepth 1 -type f -name '*.dispatch' 2>/dev/null || true)"
  [ -n "$newest" ] && RUN_ID="$(jq -r '.run_id // empty' "$newest" 2>/dev/null || true)"
fi
[ -n "${RUN_ID:-}" ] || exit 0

rec="$RUNS_DIR/$RUN_ID.json"
[ -f "$rec" ] || { printf 'track-audit: no run record at %s — nothing to audit.\n' "$rec" >&2; exit 0; }

# --- verdict accumulator ------------------------------------------------------------
results=""   # id<TAB>verdict<TAB>message
n_pass=0; n_warn=0; n_fail=0
add() { # add <id> <verdict> <message>
  results="$results$1	$2	$3
"
  case "$2" in PASS) n_pass=$((n_pass+1));; WARN) n_warn=$((n_warn+1));; FAIL) n_fail=$((n_fail+1));; esac
}

j() { jq -r "$1" "$rec" 2>/dev/null || true; }

# Selects a subagent dispatch out of trace[]. track-trace.sh stamps kind:"subagent" and
# copies the RAW hook_event_name into .event ("SubagentStop", "subagentStart", …), so the
# earlier `.event=="start" or .event=="stop"` test matched NOTHING on any real surface —
# every check built on it degraded to "no subagent activity in trace[]" even on runs that
# dispatched a dozen. Match the kind tag first, keeping the event-name spellings as a
# fallback for records written before that tag existed.
SUBAGENT_SEL='select(((.kind // "") == "subagent")
  or ((((.event // "") | ascii_downcase)) as $e
      | ($e | test("subagent")) or $e == "start" or $e == "stop"))'

# Remediation per check id. Kept as a lookup rather than a field on every add() call
# because the fix depends on WHICH invariant broke, not on the instance. These strings
# are rendered into the PR body by track-report.sh, so a reviewer seeing a ⚠️ also sees
# what would clear it — a finding with no next step just becomes noise everyone scrolls past.
remediation_for() {
  case "$1" in
    G1) printf 'Run governance discovery (references/governance.md), write the distilled bundle to runs/<RUN_ID>.governance.md, then: track-note.sh governance <path>' ;;
    G2) printf 'Read the missing .github/instructions/* file(s) and add their binding constraints to the bundle, then re-pin it.' ;;
    G3) printf 'Governance must be discovered and pinned BEFORE any subagent is dispatched. Re-run the affected dispatches with the bundle content embedded in each brief.' ;;
    G4) printf 'Read security-and-owasp.instructions.md, add its relevant constraints to the bundle, and re-review the trust-boundary diff against them.' ;;
    G5) printf 'The bundle names the file but distils nothing from it. Re-read the matched instruction file and write its binding constraints under that heading as concrete bullets (`pin image tags, never :latest`, not `follow container best practice`), then re-pin the bundle.' ;;
    G6) printf 'Embed the bundle CONTENT in every maker/reviewer brief — the constraint lines themselves, sliced to the cluster, never the filenames. Re-dispatch the affected briefs. A dispatch that genuinely needs no governance (read-only research) must say so in the brief: "GOVERNANCE: n/a — <why>". If the finding is that the hook is unwired, run install-hooks.sh --apply.' ;;
    I1) printf 'Isolate the work first: run using-git-worktrees to place it in a dedicated worktree on its own branch. Never work on the default branch; branch-in-place is allowed only when using-git-worktrees routes there AND that limitation was surfaced.' ;;
    I2) printf 'Re-run track-preflight.sh --persist for this track so the breadcrumb records the branch actually in use, or move the work to the approved branch. Do not let the approved plan and the real work diverge.' ;;
    I3) printf 'Run track-reconcile.sh at session start and after any compaction, and act on its resume_action. If it never runs, wire it to SessionStart (install-hooks.sh) — position must come from durable state, never from re-reading the worktree.' ;;
    I4) printf 'After ANY compaction, re-read the pinned governance bundle from disk BEFORE dispatching the next subagent — a post-compaction brief built from memory carries constraints the compaction already dropped. If the finding is that the hook is unwired, run install-hooks.sh --apply so track-compact.sh records compactions and bundle re-reads.' ;;
    P1|P2) printf 'Stamp each gate boundary as you cross it: track-note.sh phase <mode> <step>. Without it a compacted session cannot re-anchor.' ;;
    M1) printf 'The stage-1/stage-2 reviewer must be a subagent distinct from the implementer. Re-review with a fresh agent if one agent did both.' ;;
    T1) printf 'Story mode requires the RED suite to fail BEFORE implementation. Confirm the tests were authored first; if they were not, this is not TDD.' ;;
    T2) printf 'Never green a frozen test by weakening it. Restore the assertion / remove the skip, and route a genuinely wrong test back through its review gate.' ;;
    E1) printf 'Freeze edits, then re-run EVERY required evidence kind back-to-back so all captures share one fingerprint (the convergence gate).' ;;
    E2) printf 'Re-run the suite and capture the full output. A truncated pass-looking response satisfies the evidence gate without proving anything.' ;;
    F1) printf 'Record the terminal state before finishing: track-note.sh status <success|blocked|no-progress|budget-exceeded> "<blocker>" "<next step>".' ;;
    *)  printf '' ;;
  esac
}

run_mode="$(j '.phase.mode // ""')"
run_status="$(j '.status // ""')"

# --- diff surface -------------------------------------------------------------------
base="${TRACK_BASE_REF:-}"
[ -n "$base" ] || base="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
changed=""
if [ -n "$base" ] && git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  changed="$(git diff --name-only "$base"...HEAD 2>/dev/null || true)"
fi
changed="$(printf '%s\n%s\n%s\n' "$changed" \
  "$(git diff --name-only HEAD 2>/dev/null || true)" \
  "$(git ls-files --others --exclude-standard 2>/dev/null || true)" | sed '/^$/d' | sort -u)"

# ════════════════════════════════════════════════════════════════════════════════════
# GOVERNANCE — the gate whose failure ships credentials
# ════════════════════════════════════════════════════════════════════════════════════

gov_path="$(j '.governance_bundle.path // ""')"
gov_sha_rec="$(j '.governance_bundle.sha // ""')"
# Pin HISTORY (track-note.sh appends one entry per `note governance`). Older records predate
# the field, so fall back to the single current pin — a one-entry history behaves identically.
n_stamps="$(j '.governance_stamps | length // 0')"; n_stamps="${n_stamps:-0}"
[ "$n_stamps" = "null" ] && n_stamps=0

if [ -z "$gov_path" ]; then
  add G1 FAIL "no governance bundle pinned — run governance discovery, persist it, then 'track-note.sh governance <path>'"
elif [ ! -f "$gov_path" ]; then
  add G1 FAIL "governance bundle '$gov_path' is recorded but MISSING from disk — every brief built from it is unreproducible"
else
  gov_sha_now="$( { if command -v shasum >/dev/null 2>&1; then shasum "$gov_path"; else sha1sum "$gov_path"; fi; } | cut -d' ' -f1)"
  # Re-pinning is the SANCTIONED way to widen a bundle mid-core, so the sha is compared against
  # the LATEST pin, not the first. An edited-but-never-re-pinned bundle still WARNs: that is the
  # case where briefs went out against constraints nobody recorded.
  if [ "$gov_sha_now" != "$gov_sha_rec" ]; then
    add G1 WARN "governance bundle changed after it was pinned (sha ${gov_sha_rec:0:8} → ${gov_sha_now:0:8}) — re-pin it ('track-note.sh governance <path>') so the record matches what the briefs carried"
  elif [ "$n_stamps" -gt 1 ]; then
    # Which dispatches were briefed from which bundle version is knowable when track-brief.sh
    # is wired — it stamps bundle_sha on every brief — so name it rather than leaving the
    # reviewer to guess whether the re-pin came before or after the fan-out.
    stale_briefs="$(jq -r --arg s "$gov_sha_rec" \
      '[.briefs[]? | select((.bundle_sha // "") != "" and .bundle_sha != $s)] | length' "$rec" 2>/dev/null || echo 0)"
    stale_briefs="${stale_briefs:-0}"; [ "$stale_briefs" = "null" ] && stale_briefs=0
    if [ "$stale_briefs" -gt 0 ]; then
      add G1 PASS "governance bundle re-pinned $n_stamps times and matches its latest pin; $stale_briefs brief(s) were built from an earlier version (expected when a later cluster widened the matched set — confirm those clusters did not need the added constraints)"
    else
      add G1 PASS "governance bundle re-pinned $n_stamps times and matches its latest pin; every recorded brief was built from that version"
    fi
  else
    add G1 PASS "governance bundle present and unchanged since it was pinned"
  fi
fi

# G2 — does the bundle actually cover the instruction files this diff pulls in?
# Parses applyTo globs from .github/instructions/* and matches them against the diff.
# A bundle that never mentions a matched file is a bundle that was not really discovered.
instr_dir=".github/instructions"
matched_instr=""    # every basename whose applyTo matched — reused by G5 below
if [ -f "${gov_path:-/nonexistent}" ] && [ -d "$instr_dir" ] && [ -n "$changed" ]; then
  missing_instr=""
  while IFS= read -r ifile; do
    [ -n "$ifile" ] || continue
    globs="$(sed -n 's/^applyTo:[[:space:]]*//p' "$ifile" 2>/dev/null | head -1 | tr -d "'\"")"
    [ -n "$globs" ] || continue
    matched=0
    saved_ifs="$IFS"; IFS=,
    for g in $globs; do
      g="$(printf '%s' "$g" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$g" ] || continue
      gg="${g#\*\*/}"
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        # shellcheck disable=SC2254
        case "$p" in $g|$gg) matched=1; break ;; esac
      done <<<"$changed"
      [ "$matched" -eq 1 ] && break
    done
    IFS="$saved_ifs"
    [ "$matched" -eq 1 ] || continue
    base_name="$(basename "$ifile")"
    matched_instr="$matched_instr$base_name
"
    grep -q "$base_name" "$gov_path" 2>/dev/null || missing_instr="$missing_instr $base_name"
  done <<<"$(find "$instr_dir" -maxdepth 1 -type f -name '*.instructions.md' 2>/dev/null | sort)"
  missing_instr="$(printf '%s' "$missing_instr" | sed 's/^ *//')"
  if [ -n "$missing_instr" ]; then
    add G2 FAIL "governance bundle never mentions instruction file(s) whose applyTo matches this diff:$missing_instr"
  else
    add G2 PASS "governance bundle covers every applyTo-matched instruction file for this diff"
  fi
else
  add G2 WARN "could not cross-check bundle coverage (no bundle, no ${instr_dir}/, or empty diff)"
fi

# G5 — does each matched file's bundle section carry actual CONSTRAINTS?
#
# G2 is a substring test: it proves the basename appears somewhere in the bundle. A heading
# with nothing under it, or one hollow "follow the guidelines" bullet, satisfies it exactly as
# well as a distilled section does — so a bundle can pass coverage while transferring nothing
# to any brief. G5 reads the section body: a matched file needs a HEADING that names it and at
# least TRACK_GOV_MIN_BULLETS substantive bullets beneath it, where "substantive" means long
# enough to be an instruction rather than a pointer.
#
# Deliberately not a judgement of quality — no regex knows whether "pin image tags" is the
# right constraint for this diff. It bounds the floor: something actionable is there to embed.
gov_min_bullets="${TRACK_GOV_MIN_BULLETS:-2}"
if [ -f "${gov_path:-/nonexistent}" ] && [ -n "$matched_instr" ]; then
  hollow=""
  while IFS= read -r base_name; do
    [ -n "$base_name" ] || continue
    n_bullets="$(awk -v want="$base_name" '
      # Section = a markdown heading naming the file, up to the next heading of any level.
      /^#{1,6}[[:space:]]/ { inside = (index($0, want) > 0) ? 1 : 0; next }
      inside && /^[[:space:]]*[-*][[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*[-*][[:space:]]+/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        if (length(line) >= 12) n++
      }
      END { print n + 0 }' "$gov_path" 2>/dev/null || echo 0)"
    n_bullets="${n_bullets:-0}"
    [ "$n_bullets" -ge "$gov_min_bullets" ] || hollow="$hollow ${base_name}(${n_bullets})"
  done <<<"$matched_instr"
  hollow="$(printf '%s' "$hollow" | sed 's/^ *//')"
  if [ -n "$hollow" ]; then
    add G5 FAIL "bundle section(s) name a matched instruction file but carry fewer than $gov_min_bullets actionable constraints — a heading with no content embeds nothing: $hollow"
  else
    add G5 PASS "every applyTo-matched instruction file has a bundle section with ≥$gov_min_bullets distilled constraints"
  fi
else
  add G5 WARN "could not cross-check bundle substance (no bundle on disk, or no instruction file matched this diff)"
fi

# G3 — was EVERY subagent dispatch preceded by a governance pin?
# A brief built before discovery is a brief with no constraints in it.
#
# This asks the per-dispatch question, not "first pin vs first dispatch". The older form read
# `governance_bundle.t`, which track-note.sh OVERWRITES, so a legitimate mid-core re-pin —
# the correct response to a later cluster widening the matched set — moved that timestamp past
# the first dispatch and failed the run for doing the right thing. Reading the append-only
# `governance_stamps[]` history instead, the invariant is: for every dispatch there exists a
# pin at or before it. Equivalent to the old check on a single-pin run; accurate on a re-pinned
# one.
#
# ONLY ONE SIDE OF THIS COMPARISON IS HOOK-OBSERVED. `trace[]` is written by
# track-trace.sh and the model cannot author it, but `governance_bundle.t` is written by
# the model via track-note.sh and carries `self_reported: true`. Lowering it satisfies G3
# unconditionally — and on a real run a worker did edit that stamp and reported G3 as
# having confirmed the ordering. The verdict now names which side supported it, because a
# check advertised as artifact-derived while resting on a model-written field is worse
# than no check: it launders a claim into a fact.
#
# governance_reads[] IS hook-observed (track-compact.sh, PostToolUse), so a read of the
# pinned bundle before the first dispatch is real corroboration. It is not always present
# — it only fires once a bundle is pinned and a later tool call names it — so its absence
# downgrades the wording, never the verdict.
first_sub_t="$(j "[.trace[]? | $SUBAGENT_SEL | .t] | sort | first // \"\"")"
# Earliest pin, from the history when present and the overwritten field otherwise. A
# governance-labelled phase stamp counts too: it is the same act, recorded by a different call.
gov_t="$(j '[(.governance_stamps[]?.t), (.governance_bundle.t // empty)]
            | map(select(. != null and . != "")) | sort | first // ""')"
gov_phase_t="$(j '[.phase_log[]? | select(.step | test("governance"; "i")) | .t] | first // ""')"
[ -n "$gov_phase_t" ] && [ -z "$gov_t" ] && gov_t="$gov_phase_t"
[ -n "$gov_phase_t" ] && [ -n "$gov_t" ] && [ "$gov_phase_t" \< "$gov_t" ] && gov_t="$gov_phase_t"
gov_read_t="$(j '[.governance_reads[]?.t] | sort | first // ""')"
# Dispatches with NO pin at or before them. Equal timestamps count as covered: these stamps
# have one-second resolution, and pinning then dispatching immediately lands in the same second
# routinely — testing for strict "earlier" would fail exactly the runs that did it fastest.
ungoverned_dispatches="$(jq -r --arg gp "$gov_phase_t" "
  def times(f): [f] | map(select(. != null and . != \"\")) | sort;
  ( times(.governance_stamps[]?.t) + times(.governance_bundle.t // empty)
    + (if \$gp == \"\" then [] else [\$gp] end) | sort ) as \$stamps
  | times(.trace[]? | $SUBAGENT_SEL | .t) as \$d
  | [ \$d[] as \$dt
      | select( ([\$stamps[] | select(. <= \$dt)] | length) == 0 )
      | \$dt ]
  | .[0:5] | join(\", \")" "$rec" 2>/dev/null || true)"
if [ -z "$first_sub_t" ]; then
  add G3 WARN "no subagent activity in trace[] — either none was dispatched, or the trace hook is not wired"
elif [ -z "$gov_t" ]; then
  add G3 FAIL "subagents were dispatched but governance was never stamped — briefs cannot have carried the bundle"
elif [ -n "$ungoverned_dispatches" ]; then
  add G3 FAIL "subagent(s) dispatched with NO governance pin at or before them: $ungoverned_dispatches (earliest pin: $gov_t)"
elif [ -n "$gov_read_t" ] && [ ! "$gov_read_t" \> "$first_sub_t" ]; then
  add G3 PASS "every subagent dispatch was preceded by a governance pin, corroborated by a hook-observed bundle read at $gov_read_t"
else
  add G3 PASS "every subagent dispatch was preceded by a governance pin — on the model's own stamps, with no hook-observed bundle read before the first dispatch to corroborate them"
fi

# G4 — trust-boundary surface must pull in the security instructions.
tb_re="${TRACK_TRUST_BOUNDARY_PATTERN:-auth|secret|token|credential|password|login|session|crypto|migrations/|docker-compose|Dockerfile|\.env|nginx|caddy|proxy}"
if printf '%s\n' "$changed" | grep -Eqi "$tb_re"; then
  if [ -f "${gov_path:-/nonexistent}" ] && grep -qi 'security-and-owasp' "$gov_path" 2>/dev/null; then
    add G4 PASS "trust-boundary surface touched; bundle includes security-and-owasp"
  else
    add G4 FAIL "diff touches a trust boundary but the governance bundle never mentions security-and-owasp"
  fi
else
  add G4 PASS "no trust-boundary paths in the diff (security add-on not required)"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# ISOLATION & RESUME — the early bracket. Without these, a run that never isolated and
# never reconciled audits perfectly clean: every later gate can pass while the work was
# done straight on the default branch. "Never start on main" is one of this skill's
# loudest rules and it had no post-hoc check at all.
# ════════════════════════════════════════════════════════════════════════════════════

cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
# Default branch. NOT derivable from $base: when TRACK_BASE_REF is unset, $base falls back
# to the branch's own upstream (origin/<this-branch>), so stripping the remote prefix yields
# the CURRENT branch — and I1 then fails every correctly-isolated run for being "on the
# default branch". Ask the repo instead, and only trust $base when it was set explicitly.
def_branch="${TRACK_DEFAULT_BRANCH:-}"
[ -n "$def_branch" ] || def_branch="${TRACK_BASE_REF:+${TRACK_BASE_REF##*/}}"
if [ -z "$def_branch" ]; then
  def_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  def_branch="${def_branch##*/}"
fi
[ -n "$def_branch" ] || def_branch="$(git config --get init.defaultBranch 2>/dev/null || true)"
[ -n "$def_branch" ] || def_branch="main"

# I1 — worked on the default branch at all? That is the failure Step 3 exists to prevent.
# A linked worktree is the expected form; branch-in-place is permitted ONLY as the
# documented fallback, so it warns rather than fails.
in_worktree=0
if [ "$(git rev-parse --git-dir 2>/dev/null || echo a)" != "$(git rev-parse --git-common-dir 2>/dev/null || echo b)" ]; then
  in_worktree=1
fi
if [ -n "$cur_branch" ] && [ "$cur_branch" = "$def_branch" ]; then
  add I1 FAIL "work is on '$cur_branch', the default branch — the run never isolated (Step 3 exists to prevent exactly this)"
elif [ "$in_worktree" -eq 1 ]; then
  add I1 PASS "isolated in a linked worktree on branch '$cur_branch'"
elif [ -n "$cur_branch" ]; then
  add I1 WARN "on branch '$cur_branch' but NOT in a linked worktree — branch-in-place is allowed only as the documented using-git-worktrees fallback, after surfacing it"
else
  add I1 WARN "could not determine the current branch — isolation unverifiable"
fi

# I2 — did the work land where the human approved? The breadcrumb records the branch that
# was confirmed at preflight; drifting off it means the approved plan and the actual work
# diverged silently.
bc_branch=""
bc_file="$RUNS_DIR/$RUN_ID.dispatch"
[ -f "$bc_file" ] && bc_branch="$(jq -r '.branch // empty' "$bc_file" 2>/dev/null || true)"
if [ -z "$bc_branch" ]; then
  add I2 WARN "no preflight breadcrumb for this run — the start gate was skipped, or RUNS_DIR differs from the one used at preflight"
elif [ -n "$cur_branch" ] && [ "$bc_branch" != "$cur_branch" ]; then
  add I2 WARN "breadcrumb approved branch '$bc_branch' but the work is on '$cur_branch'"
else
  add I2 PASS "work is on the branch confirmed at preflight ('$bc_branch')"
fi

# I3 — reconcile leaves a `last_reconcile` stamp. Absent means either it never ran (the
# run rebuilt position by reading the worktree, which the resume invariant forbids) or the
# SessionStart hook is not wired. Both are worth surfacing; neither is provably fatal.
if [ "$(j '.last_reconcile.t // ""')" != "" ]; then
  add I3 PASS "reconcile ran and re-anchored from durable state"
else
  add I3 WARN "no reconcile on record — either the SessionStart hook is unwired, or the run never re-anchored from durable state after a resume/compaction"
fi

# I4 — THE COMPACTION GATE. A compaction happens inside a live session, so no SessionStart
# fires and nothing re-injects the governance excerpts every brief depends on. The failure
# is invisible by construction: post-compaction briefs thin out while the model still
# reports full compliance. track-compact.sh records both halves as hook-observed facts
# (compactions[] and governance_reads[]), which turns the invariant into arithmetic:
# between every compaction and the NEXT subagent dispatch there must be a bundle re-read.
# Both timestamps are hook-written — the model authors neither — so this sits in the same
# tier as G3, not with the self-reported phase stamps.
compact_wired=0
for _f in .claude/settings.json .github/hooks/track-hooks.json .vscode/hooks.json; do
  [ -f "$_f" ] && grep -q 'track-compact' "$_f" 2>/dev/null && { compact_wired=1; break; }
done
n_compact="$(j '.compactions | length // 0')"; n_compact="${n_compact:-0}"
[ "$n_compact" = "null" ] && n_compact=0

if [ "$n_compact" -eq 0 ]; then
  if [ "$compact_wired" -eq 1 ]; then
    add I4 PASS "no compaction during this run (track-compact.sh is wired, so this is a real negative — not an unobserved one)"
  else
    add I4 WARN "compaction resilience unverifiable — track-compact.sh is not wired, so a compaction would leave no trace and the post-compaction re-read cannot be checked"
  fi
elif [ -z "$gov_path" ]; then
  add I4 WARN "$n_compact compaction(s) recorded but no governance bundle was ever pinned — there is no path a re-read could be recognised against (see G1)"
else
  # For each compaction: find the first subagent dispatch after it, then require a bundle
  # read strictly between the two. No dispatch after a compaction is fine — nothing was
  # briefed, so nothing could have been briefed thin.
  violations="$(jq -r '
    def times(f): [f] | map(select(. != null and . != "")) | sort;
    (times(.compactions[]?.t))      as $c |
    (times(.governance_reads[]?.t)) as $r |
    (times(.trace[]? | '"$SUBAGENT_SEL"' | .t)) as $d |
    [ $c[] as $ct
      | ([$d[] | select(. > $ct)] | first) as $next
      | select($next != null)
      | select( ([$r[] | select(. > $ct and . < $next)] | length) == 0 )
      | "\($ct)→\($next)" ]
    | join(", ")' "$rec" 2>/dev/null || true)"
  # How many compactions were actually followed by a dispatch? A compaction with nothing
  # briefed after it passes for a different reason than one that re-read the bundle, and
  # saying "each was followed by a re-read" when nothing was dispatched would overstate.
  n_briefed="$(jq -r '
    def times(f): [f] | map(select(. != null and . != "")) | sort;
    (times(.compactions[]?.t)) as $c |
    (times(.trace[]? | '"$SUBAGENT_SEL"' | .t)) as $d |
    [ $c[] as $ct | select( ([$d[] | select(. > $ct)] | length) > 0 ) ] | length' "$rec" 2>/dev/null || echo 0)"
  n_briefed="${n_briefed:-0}"; [ "$n_briefed" = "null" ] && n_briefed=0
  # The re-read proves the bundle came back into context; it does not prove the next brief then
  # used it. track-brief.sh closes that join: the FIRST brief recorded after each compaction is
  # hook-observed, so "was the re-read actually spent on the next brief?" is decidable — a thin
  # brief there is a re-read that changed nothing, which is the exact shape of the silent
  # post-compaction degradation this gate exists to catch.
  post_compact_thin="$(jq -r '
    def times(f): [f] | map(select(. != null and . != "")) | sort;
    (times(.compactions[]?.t)) as $c |
    [ $c[] as $ct
      | ([.briefs[]? | select((.t // "") > $ct)] | first) as $b
      | select($b != null and $b.thin == true)
      | "\($ct)→\($b.t)" ]
    | join(", ")' "$rec" 2>/dev/null || true)"
  if [ -n "$violations" ]; then
    add I4 FAIL "a subagent was dispatched after a compaction with NO bundle re-read in between ($violations) — that brief cannot have carried the governance constraints"
  elif [ -n "$post_compact_thin" ]; then
    add I4 FAIL "the first brief after a compaction carried NONE of the bundle's constraints ($post_compact_thin) — the bundle was re-read but the brief was still built from dropped context"
  elif [ "$n_briefed" -eq 0 ]; then
    add I4 PASS "$n_compact compaction(s), none followed by a subagent dispatch — no brief could have been built from dropped context"
  else
    add I4 PASS "$n_compact compaction(s); each of the $n_briefed followed by a dispatch had a governance-bundle re-read in between"
  fi
fi

# G6 — THE LAST HOP. Did the briefs actually CARRY the bundle's constraints?
#
# Every other governance check is a proxy for this one: G1 that the bundle exists, G2 that it
# covers the diff, G5 that its sections have content, G3 that it was pinned before dispatch, I4
# that it was re-read after a compaction. None of them could see the brief, so the audit's
# NOT-CHECKED list carried the load-bearing step as a human read ("A5 — open a real dispatch and
# look"). track-brief.sh sees it: a PreToolUse hook on the dispatch tool receives the brief text
# and counts how many of the bundle's constraint lines appear in it, before the subagent starts.
#
# Zero constraint lines with a bundle pinned is the failure A5 was written for — the brief passed
# filenames. A brief that carried some but fewer than the threshold is a WARN, not a FAIL: a
# fan-out brief embeds only its own cluster's sections, and no hook can tell a correct slice from
# a lazy one. An explicit `GOVERNANCE: n/a — <why>` line clears a dispatch that genuinely needs
# none (read-only research), on the bundle's own "state ABSENT, never no-op by omission" rule.
brief_wired=0
for _f in .claude/settings.json .github/hooks/track-hooks.json .vscode/hooks.json; do
  [ -f "$_f" ] && grep -q 'track-brief' "$_f" 2>/dev/null && { brief_wired=1; break; }
done
n_briefs="$(j '.briefs | length // 0')"; n_briefs="${n_briefs:-0}"
[ "$n_briefs" = "null" ] && n_briefs=0
n_dispatch="$(j "[.trace[]? | $SUBAGENT_SEL | .t] | length // 0")"; n_dispatch="${n_dispatch:-0}"
[ "$n_dispatch" = "null" ] && n_dispatch=0

if [ "$n_briefs" -eq 0 ]; then
  if [ "$brief_wired" -eq 0 ]; then
    add G6 WARN "brief content unverifiable — track-brief.sh is not wired, so nothing observed whether any brief carried the bundle (run install-hooks.sh --apply)"
  elif [ "$n_dispatch" -eq 0 ]; then
    add G6 PASS "no dispatches to check (track-brief.sh is wired, so this is a real negative)"
  else
    add G6 WARN "track-brief.sh is wired but recorded no brief for $n_dispatch dispatch(es) — this surface's dispatch tool may use a name or payload field the hook does not recognise; brief content is unverified"
  fi
elif [ -z "$gov_path" ]; then
  add G6 WARN "$n_briefs brief(s) recorded but no governance bundle was ever pinned — there was no content to carry (see G1)"
else
  n_thin="$(j '[.briefs[]? | select(.thin == true)] | length')"; n_thin="${n_thin:-0}"
  n_low="$(j '[.briefs[]? | select(.below_min == true)] | length')"; n_low="${n_low:-0}"
  n_na="$(j '[.briefs[]? | select(.declared_na == true)] | length')"; n_na="${n_na:-0}"
  thin_at="$(j '[.briefs[]? | select(.thin == true) | .t] | .[0:5] | join(", ")')"
  n_ok=$((n_briefs - n_thin - n_na))
  if [ "$n_thin" -gt 0 ]; then
    add G6 FAIL "$n_thin of $n_briefs brief(s) carried NONE of the bundle's constraints and declared no 'GOVERNANCE: n/a' ($thin_at) — those dispatches passed filenames, not content"
  elif [ "$n_low" -gt 0 ]; then
    add G6 WARN "every brief carried some governance content, but $n_low of $n_briefs carried fewer lines than the threshold — expected for a narrow cluster slice, worth confirming the right sections were sliced"
  elif [ "$n_na" -gt 0 ]; then
    add G6 PASS "$n_ok brief(s) carried bundle constraints; $n_na explicitly declared 'GOVERNANCE: n/a'"
  else
    add G6 PASS "all $n_briefs brief(s) carried the bundle's constraints as content (hook-observed at dispatch time)"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════════
# POSITION — did the run advance through its gates, or jump straight to the end?
# ════════════════════════════════════════════════════════════════════════════════════

phase_count="$(j '.phase_log | length // 0')"; phase_count="${phase_count:-0}"
[ "$phase_count" = "null" ] && phase_count=0
if [ "$phase_count" -eq 0 ]; then
  add P1 FAIL "no phase ever stamped — this run has no durable position and cannot be resumed after a compaction"
else
  add P1 PASS "$phase_count phase stamp(s) recorded"
fi

# P2 — the canonical gate sequence per core. Substring-matched, so 'red-review-us1'
# still counts; a missing gate is a WARN because a legitimately tiny run may collapse
# steps, but a silent jump from guard to converge is exactly what this surfaces.
case "$run_mode" in
  scaffold) expected="governance generate apply review converge" ;;
  story)    expected="governance red-batch red-review green converge" ;;
  refactor) expected="governance pin-green transform converge" ;;
  *)        expected="" ;;
esac
if [ -n "$expected" ] && [ "$phase_count" -gt 0 ]; then
  seen="$(j '[.phase_log[]?.step] | join(" ")')"
  gaps=""
  for g in $expected; do
    printf '%s' "$seen" | grep -qi -- "$g" || gaps="$gaps $g"
  done
  gaps="$(printf '%s' "$gaps" | sed 's/^ *//')"
  if [ -n "$gaps" ]; then
    add P2 WARN "mode '$run_mode' has no phase stamp for:$gaps (collapsed steps, or a skipped gate)"
  else
    add P2 PASS "phase log covers every canonical gate for $run_mode mode"
  fi
else
  add P2 WARN "no execution core recorded in .phase.mode — cannot check the gate sequence"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# MAKER / CHECKER — the reviewer must not be the implementer
# ════════════════════════════════════════════════════════════════════════════════════

sub_ids="$(j '[.trace[]? | .agent_id // empty] | unique | length')"; sub_ids="${sub_ids:-0}"
[ "$sub_ids" = "null" ] && sub_ids=0
sub_types="$(j '[.trace[]? | .agent_type // empty] | unique | length')"; sub_types="${sub_types:-0}"
[ "$sub_types" = "null" ] && sub_types=0
if [ "$sub_ids" -ge 2 ]; then
  add M1 PASS "$sub_ids distinct subagent ids in trace[] (maker/checker separation is possible)"
elif [ "$sub_ids" -eq 1 ]; then
  add M1 WARN "only 1 distinct subagent id — one agent may have both authored and reviewed"
else
  add M1 WARN "trace[] records no subagent ids (Claude Code's SubagentStop payload omits them; unverifiable on this surface)"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# TEST DISCIPLINE — the strongest mechanical signal available
# ════════════════════════════════════════════════════════════════════════════════════

fail_re="${TRACK_FAIL_PATTERN:-}"
[ -n "$fail_re" ] || fail_re='\bFAIL\b|FAILED|panic:|Traceback|error TS[0-9]|\bERROR\b|✖|exit code [1-9]|[1-9][0-9]* (failed|error)'
ev_count="$(j '.evidence | length // 0')"; ev_count="${ev_count:-0}"
[ "$ev_count" = "null" ] && ev_count=0

# T1 — story mode claims TDD. If the RED suite really ran, a FAILING capture exists in
# evidence[] at an earlier fingerprint than the passing one. No red ever recorded means
# either the tests never ran red, or they were written after the code.
if [ "$run_mode" = "story" ]; then
  if [ "$ev_count" -eq 0 ]; then
    add T1 WARN "story mode but evidence[] is empty — cannot confirm the RED suite ever ran"
  else
    red_seen=0
    while IFS= read -r resp; do
      [ -n "$resp" ] || continue
      printf '%s' "$resp" | grep -Eq "$fail_re" && { red_seen=1; break; }
    done <<<"$(jq -r '.evidence[]?.response // empty' "$rec" 2>/dev/null || true)"
    if [ "$red_seen" -eq 1 ]; then
      add T1 PASS "a failing capture is on record — the RED phase genuinely ran red before green"
    else
      add T1 WARN "story mode with $ev_count capture(s) but none ever failed — tests may have been written after the implementation"
    fi
  fi
elif [ "$run_mode" = "refactor" ]; then
  add T1 PASS "refactor mode is keep-green — no RED capture expected"
else
  add T1 PASS "scaffold mode — no test obligation (the guard cleared it)"
fi

# T2 — a weakened test is a false green in every mode. Scan the diff for the markers.
if [ -n "$base" ] && git rev-parse --verify -q "$base" >/dev/null 2>&1; then
  test_files="$(printf '%s\n' "$changed" | grep -Ei '(^|/)(test|tests|spec|__tests__)/|_test\.|\.test\.|\.spec\.' || true)"
  if [ -n "$test_files" ]; then
    weakened="$(git diff "$base"...HEAD -- $test_files 2>/dev/null \
      | grep -E '^\+.*(\.skip|\bskip\(|@skip|xit\(|xdescribe\(|t\.Skip\(|pytest\.mark\.skip|@Ignore|\.only\()' || true)"
    removed_asserts="$(git diff "$base"...HEAD -- $test_files 2>/dev/null \
      | grep -cE '^-.*(assert|expect|require\.|should\.)' || true)"
    if [ -n "$weakened" ]; then
      add T2 WARN "a skip/only marker was ADDED to a test file — confirm it is not a frozen test being greened by weakening"
    elif [ "${removed_asserts:-0}" -gt 0 ]; then
      add T2 WARN "${removed_asserts} assertion line(s) removed from test files — confirm each was a legitimate rewrite, not a deletion to reach green"
    else
      add T2 PASS "no skip markers added and no assertions removed from test files"
    fi
  else
    add T2 PASS "no test files in the diff"
  fi
else
  add T2 WARN "no usable TRACK_BASE_REF — cannot diff test files for weakening"
fi

# ════════════════════════════════════════════════════════════════════════════════════
# EVIDENCE
# ════════════════════════════════════════════════════════════════════════════════════

# E1 — the convergence gate: every kind's LATEST capture must share one fingerprint.
if [ "$ev_count" -eq 0 ]; then
  add E1 WARN "evidence[] is empty — nothing was captured, so nothing is proven"
else
  distinct_fp="$(jq -r '[.evidence[]? | {k:.kind, f:.fingerprint}] | group_by(.k) | map(last.f) | unique | length' "$rec" 2>/dev/null || echo 1)"
  if [ "${distinct_fp:-1}" -gt 1 ]; then
    add E1 FAIL "the latest captures span $distinct_fp different fingerprints — the lanes never converged on one final tree"
  else
    add E1 PASS "every kind's latest capture shares one fingerprint (converged)"
  fi
fi

# E2 — a truncated PASS-looking response satisfies the gate without proving anything:
# the gate only asserts a fingerprint match plus the absence of a failure marker, and
# absence-of-marker is trivially true for a truncated string. Short FAILING captures are
# not flagged — a terse failure is normal, and it can never fake its way past the gate.
if [ "$ev_count" -gt 0 ]; then
  short=0
  while IFS= read -r resp; do
    [ -n "$resp" ] || continue
    printf '%s' "$resp" | grep -Eq "$fail_re" && continue   # a failure, not a false green
    [ "${#resp}" -lt 40 ] && short=$((short+1))
  done <<<"$(jq -r '.evidence[]? | (.response // "") | gsub("\n"; " ")' "$rec" 2>/dev/null || true)"
  if [ "$short" -gt 0 ]; then
    add E2 WARN "$short passing capture(s) under 40 chars — too short to prove a suite ran, and the gate cannot tell the difference; read the real output"
  else
    add E2 PASS "passing captures are substantial enough to be worth reading"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════════
# TERMINAL STATE
# ════════════════════════════════════════════════════════════════════════════════════

if [ -z "$run_status" ]; then
  add F1 WARN "no terminal status recorded — write one with 'track-note.sh status <state>' before claiming done"
elif [ "$run_status" = "success" ]; then
  add F1 PASS "terminal status: success"
else
  blocker="$(j '.blocker // ""')"
  if [ -n "$blocker" ]; then
    add F1 PASS "terminal status '$run_status' with a recorded blocker — correctly NOT a success"
  else
    add F1 WARN "terminal status '$run_status' but no blocker recorded — the next session has nothing to route on"
  fi
fi

# ════════════════════════════════════════════════════════════════════════════════════
# Report
# ════════════════════════════════════════════════════════════════════════════════════

MANUAL_ITEMS="A5|the governance a brief carried was the RIGHT governance — G6 counts bundle constraint lines present in the brief text, it cannot tell whether the sections sliced to that cluster were the ones binding its files
A6b|feature-context sections (spec/plan/research/contracts) were scoped to this run's task IDs/user-story tags, not transcribed wholesale from the whole feature
C2|in scaffold mode the controller applied subagent output, never authored it itself
C3|review applied the governance rubric, not a generic 'looks good'
D1|the RED batch failed for the RIGHT reason (unmet expectation, not a typo/import error)
D3|characterization tests passed at baseline (a baseline failure is a wrong test)
E3|no completion was claimed before its creating command returned"

if [ "$hook_mode" -eq 1 ]; then
  # Stop-hook contract: block with the failing lines as the reason, so the agent
  # receives something actionable rather than "audit failed". Silent when clean —
  # a passing gate emits no positive marker, same as the evidence gate.
  if [ "$n_fail" -gt 0 ]; then
    detail=""
    while IFS="$(printf '\t')" read -r id verdict msg; do
      [ "${verdict:-}" = "FAIL" ] || continue
      detail="$detail  - $id: $msg
    fix: $(remediation_for "$id")
"
    done <<<"$results"
    reason="Discipline audit FAILED — do not claim done or open a PR until these are resolved:
${detail}Run 'track-audit.sh' for the full report (including the items it cannot check)."
    jq -nc --arg r "$reason" '{decision:"block", reason:$r}'
  fi
  exit 0
fi

if [ "$mode_out" = "json" ]; then
  # Attach remediation to every non-PASS row so consumers (track-report.sh → the PR body)
  # can show a reviewer what would clear each finding.
  enriched=""
  while IFS="$(printf '\t')" read -r id verdict msg; do
    [ -n "${id:-}" ] || continue
    fix=""
    [ "$verdict" != "PASS" ] && fix="$(remediation_for "$id")"
    enriched="$enriched$id	$verdict	$msg	$fix
"
  done <<<"$results"
  printf '%s' "$enriched" | jq -R -s --arg run "$RUN_ID" --arg m "$run_mode" \
    --argjson p "$n_pass" --argjson w "$n_warn" --argjson f "$n_fail" \
    --arg manual "$MANUAL_ITEMS" '
    {run_id:$run, mode:$m,
     checks: (split("\n") | map(select(length>0)) | map(split("\t")
              | {id:.[0], verdict:.[1], message:.[2], remediation:(.[3] // "")})),
     summary:{pass:$p, warn:$w, fail:$f},
     blocked: ($f > 0),
     manual: ($manual | split("\n") | map(select(length>0)) | map(split("|") | {id:.[0], check:.[1]}))}'
else
  {
    printf 'TRACK AUDIT — %s' "$RUN_ID"
    [ -n "$run_mode" ] && printf '  (core: %s)' "$run_mode"
    printf '\n\n'
    while IFS="$(printf '\t')" read -r id verdict msg; do
      [ -n "${id:-}" ] || continue
      case "$verdict" in
        PASS) icon="  ✓ " ;;
        WARN) icon="  ⚠ " ;;
        FAIL) icon="  ✗ " ;;
        *)    icon="  ? " ;;
      esac
      printf '%s%-4s %s\n' "$icon" "$id" "$msg"
      if [ "$verdict" != "PASS" ]; then
        fix="$(remediation_for "$id")"
        [ -n "$fix" ] && printf '       ↳ fix: %s\n' "$fix"
      fi
    done <<<"$results"
    printf '\n  NOT CHECKED HERE — the highest-value items no artifact can settle.\n'
    printf '  Full list (13 human-only checks): tests/prompt-level-checklist.md\n'
    while IFS='|' read -r mid mtxt; do
      [ -n "${mid:-}" ] || continue
      printf '    %-4s %s\n' "$mid" "$mtxt"
    done <<<"$MANUAL_ITEMS"
    printf '\n  %d passed · %d warning(s) · %d failure(s)' "$n_pass" "$n_warn" "$n_fail"
    if [ "$n_fail" -gt 0 ]; then
      printf '  →  BLOCKED: fix the ✗ items before claiming done or opening a PR.\n'
    else
      printf '  →  no blocking failures.\n'
      printf '  A clean audit is necessary, not sufficient — the MANUAL items are where\n'
      printf '  the remaining risk lives.\n'
    fi
  } >&2
fi

[ "$blocking" -eq 1 ] && [ "$n_fail" -gt 0 ] && exit 2
exit 0
