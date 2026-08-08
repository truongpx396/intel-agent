# track-env.base.sh — repo-wide COMMITTED hook preset (single-branch-development bundle).
# Auto-seeded by install-hooks.sh from the detected repo stack. SAFE TO EDIT + COMMIT.
#
# Context: spec-driven repo — active plan: specs/001-contextengine-mvp/plan.md (project constitution)
# Stack: Go 1.23 (backend-go/) · Python 3.12 (backend-python/) · React 19/TS (frontend/)
# Detected toolchain: go · uv · node/npm
# Detected toolchain: <none detected>
#
# TWO CATEGORIES (the tag is documentation, not part of the name):
#   [TASK-DERIVED] preflight proposes per run; confirm at Step 1. Left EMPTY here so an
#                  unedited copy fails LOUD (guard denies all edits) — never silently wrong.
#   [REPO-POLICY]  repo-wide constant; set once, do not regenerate per run.
# Precedence: exported env > worktree track-env.sh > this file > script default.

# --- guard: writable scope + frozen entrypoints [TASK-DERIVED — set per run] -
export TRACK_ALLOWED_PREFIXES="${TRACK_ALLOWED_PREFIXES:-}"          # colon-separated path prefixes this branch may edit. EMPTY ⇒ guard fails closed.
export TRACK_FROZEN_PATHS="${TRACK_FROZEN_PATHS:-}"                  # exact files no branch may edit (leave empty on bootstrap).
export TRACK_IMMUTABLE_PREFIXES="${TRACK_IMMUTABLE_PREFIXES:-migrations/}"  # [REPO-POLICY] committed files here are append-only.
export TRACK_GUARD_DESTRUCTIVE="${TRACK_GUARD_DESTRUCTIVE:-1}"       # [REPO-POLICY] deny DROP/TRUNCATE/FLUSHALL/rm -rf.
export TRACK_ALLOW_FF_PUSH="${TRACK_ALLOW_FF_PUSH:-}"               # [REPO-POLICY] 1 ONLY for a PR-rework flow.

# --- run state ---------------------------------------------------------------
export RUNS_DIR="${RUNS_DIR:-runs}"                        # [REPO-POLICY] run record dir — MUST be gitignored.

# --- preflight ---------------------------------------------------------------
export PREFLIGHT_REQUIRE_GH="${PREFLIGHT_REQUIRE_GH:-1}"            # [REPO-POLICY] require authenticated gh (0 to waive on setup runs).
export PREFLIGHT_REQUIRE_TOOLCHAIN="${PREFLIGHT_REQUIRE_TOOLCHAIN:-}" # [TASK-DERIVED] per-task bins on PATH (e.g. go,uv,node — set per run at preflight).

# --- evidence gate (CATALOG seeded from detected stack — [REPO-POLICY]) -------
export TRACK_EVIDENCE_KINDS="${TRACK_EVIDENCE_KINDS:-go-test:go test;py:uv run pytest;ts:npx tsc --noEmit}"  # label:pattern pack.
export TRACK_EVIDENCE_RULES="${TRACK_EVIDENCE_RULES:-backend-go/**/*.go:go-test;backend-python/**/*.py:py;frontend/**/*.ts:ts;frontend/**/*.tsx:ts;backend-go/migrations/*:pg-explain}"  # diff-path glob → required kind.
export TRACK_REQUIRED_EVIDENCE="${TRACK_REQUIRED_EVIDENCE:-}"        # [TASK-DERIVED] kinds required on EVERY diff (floor); empty = rules-only.
export TRACK_BASE_REF="${TRACK_BASE_REF:-origin/main}"                 # [REPO-POLICY] real base or a committed diff looks empty and passes silently.

# --- ceilings / hardening ----------------------------------------------------
export TRACK_MAX_TOOL_CALLS="${TRACK_MAX_TOOL_CALLS:-200}"          # [REPO-POLICY] tool-call hard stop.
export TRACK_SENTINEL="${TRACK_SENTINEL:-1}"                        # [REPO-POLICY] scan staged diff for secrets/leftovers.
export TRACK_MAX_TOKEN_ESTIMATE="${TRACK_MAX_TOKEN_ESTIMATE:-200000}"         # [REPO-POLICY] token-estimate ceiling; blocks stop + sets status=budget-exceeded when exceeded. Set to 0 to disable.

# --- notify (optional) -------------------------------------------------------
export TRACK_NOTIFY_WEBHOOK="${TRACK_NOTIFY_WEBHOOK:-}"             # [REPO-POLICY] terminal-state webhook; empty = no notify.
