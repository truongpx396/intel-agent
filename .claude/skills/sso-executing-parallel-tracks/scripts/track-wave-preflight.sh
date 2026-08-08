#!/usr/bin/env bash
# track-wave-preflight.sh — Orchestrator-level breadcrumb for one wave.
#
# A wave dispatch artifact (runs/<wave-id>.wave.dispatch) gives the orchestrator
# session durable state that lets it resume fleet position after an interruption,
# derive per-track RUN_IDs deterministically, and close the wave at Step 7 with
# a single completed_utc + final_status stamp.  One wave produces:
#
#   runs/<wave-id>.wave.dispatch         ← this script
#   runs/<wave-id>_<track-id>.json  ×N  ← per-track run records (track-preflight.sh)
#
# Modes:
#   inspect (default) — detect resume-vs-fresh, print human summary + JSON to stdout.
#                       READ-ONLY: writes nothing.  Exit non-zero only on hard errors.
#   --persist         — write runs/<wave-id>.wave.dispatch (idempotent; re-run is no-op).
#   --complete <status> — stamp completed_utc + final_status onto the breadcrumb.
#                         <status> must be: all-success | partial-blocked |
#                         budget-exceeded | aborted.  Write-once.
#
# Inputs (env):
#   WAVE_NUMBER    integer wave index, 1-based. REQUIRED.
#   WAVE_TRACKS    comma-separated track IDs (e.g. "us1,us2,us3"). REQUIRED for --persist.
#   WAVE_ID        override minted id (rare).  Normally derived as:
#                    <UTC-timestamp>_wave<WAVE_NUMBER>   e.g. 2026-07-20T11-30_wave1
#   RUNS_DIR       default "runs".
#   TRACK_BASE_REF base branch/ref being used (recorded for resume integrity check).
#
# Per-track RUN_ID derivation (orchestrator stamps these into each worker's env):
#   RUN_ID for track X = <wave-id>_<X>   e.g. 2026-07-20T11-30_wave1_us1
# This makes the wave membership visible in every downstream filename and log line.
#
# Resume detection: the NEWEST runs/*.wave.dispatch whose wave_number==WAVE_NUMBER.
# Its wave_id is the resume key; all per-track RUN_IDs are reconstructed from
# track_ids[].  The orchestrator hands those to each worker's track-preflight.sh.
#
# Requires: jq, git.  Keep runtime < 5s.
set -eufo pipefail

__env_dir="${BASH_SOURCE[0]%/*}"
if [ -f "$__env_dir/track-env.sh" ];      then . "$__env_dir/track-env.sh";      fi
if [ -f "$__env_dir/track-env.base.sh" ]; then . "$__env_dir/track-env.base.sh"; fi
unset __env_dir

# ── arg parse ──────────────────────────────────────────────────────────────────
mode="inspect"
complete_status=""
for a in "$@"; do
  case "$a" in
    --persist)  mode="persist"  ;;
    --inspect)  mode="inspect"  ;;
    --complete) mode="complete" ;;
    all-success|partial-blocked|budget-exceeded|aborted)
      complete_status="$a" ;;
  esac
done

RUNS_DIR="${RUNS_DIR:-runs}"
wave_num="${WAVE_NUMBER:-}"
wave_tracks="${WAVE_TRACKS:-}"
base_ref="${TRACK_BASE_REF:-${default_branch:-main}}"

err() { printf '%s\n' "wave-preflight: $1" >&2; }
die() { err "$1"; exit 1; }

[ -n "$wave_num" ] || die "WAVE_NUMBER is required (integer, 1-based)."
command -v jq  >/dev/null 2>&1 || die "jq not found."
command -v git >/dev/null 2>&1 || die "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree."

mkdir -p "$RUNS_DIR" 2>/dev/null || true
[ -w "$RUNS_DIR" ] || die "$RUNS_DIR is not writable."

# ── resume detection ──────────────────────────────────────────────────────────
# Find the newest .wave.dispatch whose wave_number matches WAVE_NUMBER.
existing_file=""
existing_wave_id=""
# Use find + sort (lexical = chronological for UTC-timestamp prefixes; portable).
while IFS= read -r f; do
  wn="$(jq -r '.wave_number // empty' "$f" 2>/dev/null)" || continue
  [ "$wn" = "$wave_num" ] || continue
  existing_file="$f"
  existing_wave_id="$(jq -r '.wave_id' "$f")"
done < <(find "$RUNS_DIR" -maxdepth 1 -name '*.wave.dispatch' 2>/dev/null | sort)

# ── derive / recover wave_id ──────────────────────────────────────────────────
if [ -n "${WAVE_ID:-}" ]; then
  wave_id="$WAVE_ID"
elif [ -n "$existing_wave_id" ]; then
  wave_id="$existing_wave_id"     # RESUME: stable, never re-mint
else
  # START: mint a new id
  ts="$(date -u +%Y-%m-%dT%H-%M 2>/dev/null || date -u +%FT%H-%M)"
  wave_id="${ts}_wave${wave_num}"
fi

breadcrumb="${RUNS_DIR}/${wave_id}.wave.dispatch"
is_resume=false
[ -n "$existing_wave_id" ] && is_resume=true

# ── helpers ───────────────────────────────────────────────────────────────────
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%FT%TZ; }
base_sha() { git rev-parse "${base_ref}" 2>/dev/null || echo "unknown"; }

# Build the track_run_ids array from WAVE_TRACKS or from existing breadcrumb.
build_track_run_ids() {
  local tracks_src="$1"    # comma-separated track IDs
  local wid="$2"
  # Output newline-separated "<wid>_<track>" strings.
  echo "$tracks_src" | tr ',' '\n' | while IFS= read -r t; do
    t="${t#"${t%%[! ]*}"}"  # ltrim spaces
    t="${t%"${t##*[! ]}"}"  # rtrim spaces
    [ -n "$t" ] || continue
    printf '%s_%s\n' "$wid" "$t"
  done
}

# ── inspect ───────────────────────────────────────────────────────────────────
if [ "$mode" = "inspect" ]; then
  if $is_resume; then
    cur_status="$(jq -r '.status' "$existing_file")"
    track_ids_json="$(jq -c '.track_run_ids' "$existing_file")"
    echo "=== wave-preflight: RESUME wave ${wave_num} ==="
    printf 'Wave ID   : %s\n' "$wave_id"
    printf 'Status    : %s\n' "$cur_status"
    printf 'Track IDs : %s\n' "$track_ids_json"
    printf 'Breadcrumb: %s\n' "$breadcrumb"
    jq '.' "$existing_file"
  else
    if [ -z "$wave_tracks" ]; then
      die "WAVE_TRACKS is required when starting a new wave (inspect: validating inputs)."
    fi
    _trids_json="$(build_track_run_ids "$wave_tracks" "$wave_id" | jq -R . | jq -s .)"
    echo "=== wave-preflight: START wave ${wave_num} ==="
    printf 'Wave ID         : %s\n' "$wave_id"
    printf 'Base ref        : %s\n' "$base_ref"
    printf 'Tracks          : %s\n' "$wave_tracks"
    printf 'Per-track RUN_IDs:\n'
    build_track_run_ids "$wave_tracks" "$wave_id" | while IFS= read -r rid; do printf '  %s\n' "$rid"; done
    printf 'Breadcrumb (pending --persist): %s\n' "$breadcrumb"
    # Emit parseable JSON on stdout for orchestrator scripting.
    jq -n \
      --arg wave_id "$wave_id" \
      --argjson wave_number "$wave_num" \
      --arg base_ref "$base_ref" \
      --arg base_sha "$(base_sha)" \
      --argjson track_run_ids "$_trids_json" \
      --arg status "pending-persist" \
      '{wave_id:$wave_id, wave_number:$wave_number, base_ref:$base_ref,
        base_sha:$base_sha, track_run_ids:$track_run_ids, status:$status}'
  fi
  exit 0
fi

# ── persist ───────────────────────────────────────────────────────────────────
if [ "$mode" = "persist" ]; then
  if $is_resume; then
    err "RESUME: breadcrumb already exists at ${breadcrumb} — no-op."
    jq '.' "$breadcrumb"
    exit 0
  fi
  [ -n "$wave_tracks" ] || die "WAVE_TRACKS is required for --persist."
  track_run_ids_json="$(build_track_run_ids "$wave_tracks" "$wave_id" | jq -R . | jq -s .)"
  jq -n \
    --arg wave_id "$wave_id" \
    --argjson wave_number "$wave_num" \
    --arg base_ref "$base_ref" \
    --arg base_sha "$(base_sha)" \
    --argjson track_run_ids "$track_run_ids_json" \
    --arg created_utc "$(now_utc)" \
    '{wave_id:$wave_id, wave_number:$wave_number, base_ref:$base_ref,
      base_sha:$base_sha, track_run_ids:$track_run_ids,
      status:"in-progress", created_utc:$created_utc, completed_utc:null,
      final_status:null}' > "$breadcrumb"
  err "persisted: ${breadcrumb}"
  jq '.' "$breadcrumb"
  exit 0
fi

# ── complete ──────────────────────────────────────────────────────────────────
if [ "$mode" = "complete" ]; then
  valid_statuses="all-success partial-blocked budget-exceeded aborted"
  case " $valid_statuses " in
    *" $complete_status "*) ;;
    *) die "complete requires a status: $valid_statuses" ;;
  esac
  [ -f "$breadcrumb" ] || die "no breadcrumb at ${breadcrumb} — run --persist first."

  # Write-once guard on completed_utc.
  already="$(jq -r '.completed_utc // empty' "$breadcrumb")"
  if [ -n "$already" ]; then
    err "already completed at ${already} — no-op."
    jq '.' "$breadcrumb"
    exit 0
  fi

  now="$(now_utc)"
  created="$(jq -r '.created_utc' "$breadcrumb")"
  # Duration in seconds (portable: use date -d on Linux, Python fallback on macOS).
  dur_secs=""
  if date -d "$created" +%s >/dev/null 2>&1; then
    dur_secs="$(( $(date -d "$now" +%s) - $(date -d "$created" +%s) ))"
  else
    dur_secs="$(python3 -c "
from datetime import datetime, timezone
fmt='%Y-%m-%dT%H:%M:%SZ'
a=datetime.strptime('${created}',fmt).replace(tzinfo=timezone.utc)
b=datetime.strptime('${now}',fmt).replace(tzinfo=timezone.utc)
print(int((b-a).total_seconds()))
" 2>/dev/null || echo "null")"
  fi

  updated="$(jq \
    --arg cu "$now" \
    --arg fs "$complete_status" \
    --argjson ds "${dur_secs:-null}" \
    '.completed_utc=$cu | .final_status=$fs | .status=$fs | .duration_secs=$ds' \
    "$breadcrumb")"
  printf '%s\n' "$updated" > "$breadcrumb"
  err "completed: ${breadcrumb} (${complete_status}, ${dur_secs}s)"
  jq '.' "$breadcrumb"
  exit 0
fi

die "unknown mode '${mode}'"
