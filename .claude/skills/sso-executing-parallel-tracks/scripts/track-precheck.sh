#!/usr/bin/env bash
# track-precheck.sh — Precheck gate (PARALLEL-ONLY): assert that N tracks' file /
# migration ownership prefixes are MUTUALLY DISJOINT before fan-out. Overlap here is a
# guaranteed merge conflict later, so this STOPS the wave deterministically rather than
# letting the collision surface across N runaway workers at integration time.
#
# This mechanizes Step 1's "non-overlapping ownership" check the same way track-guard.sh
# mechanizes per-worktree ownership. Two tracks overlap iff some concrete path would be
# admitted by BOTH tracks' guards — i.e. one track's prefix is a string-prefix of the
# other's, the exact `case "$rel" in "$a"*)` rule the guard uses. Migration ranges are
# covered by the same rule when expressed as prefixes (e.g. "migrations/0007_").
#
# Input (stdin): a JSON array of tracks, each { "id": <slug>, "prefixes": <colon-list> }.
# `prefixes` is the SAME colon-separated string each worker receives as
# TRACK_ALLOWED_PREFIXES, so the precheck asserts on exactly what the guards enforce:
#   [ {"id":"us1","prefixes":"internal/ingest:migrations/0007_"},
#     {"id":"us2","prefixes":"internal/notify:migrations/0008_"} ]
#
# Output (stdout): a JSON report
#   { ok, tracks, collisions:[{a,b,a_prefix,b_prefix}], config_errors:[...] }.
# Exit 0 when disjoint and well-formed (fan-out may proceed); exit 2 on ANY collision,
# duplicate track id, or empty-ownership track (fail-closed — the orchestrator STOPS and
# asks the human back with the specific collision, per Step 1).
#
# Read-only; mutates nothing. Requires: jq. Keep runtime < 5s.
set -eufo pipefail   # -f: no globbing — prefixes are literal strings, never patterns.

command -v jq >/dev/null 2>&1 || { echo '{"ok":false,"error":"jq not found"}'; exit 2; }

input="$(cat)"
[ -n "${input//[[:space:]]/}" ] || { echo '{"ok":false,"error":"no input"}'; exit 2; }
echo "$input" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo '{"ok":false,"error":"input is not a JSON array"}'; exit 2; }

n="$(echo "$input" | jq 'length')"

# Load tracks into parallel arrays: ids[i] / prefs[i] (prefs = colon-separated list).
ids=(); prefs=()
while IFS="$(printf '\t')" read -r id pfx; do
  [ -n "$id" ] || continue
  ids+=("$id"); prefs+=("$pfx")
done < <(echo "$input" | jq -r '.[] | [.id, (.prefixes // "")] | @tsv')

count="${#ids[@]}"

trim() { printf '%s' "$1" | sed 's/^ *//; s/ *$//'; }

# Config guard 1 — every track must own ≥1 prefix. A track that can edit nothing is a
# misconfiguration (its guard would fail-closed deny-all), not a valid member of a wave.
config_err=""
for ((i=0; i<count; i++)); do
  [ -n "${prefs[$i]// /}" ] || config_err="$config_err ${ids[$i]}(no-prefixes)"
done

# Config guard 2 — duplicate track ids collapse two waves into one id space; reject.
dup="$(printf '%s\n' "${ids[@]:-}" | sed '/^$/d' | sort | uniq -d | tr '\n' ' ')"
[ -n "${dup// /}" ] && for d in $dup; do config_err="$config_err ${d}(duplicate-id)"; done

# first_overlap A B — echo "x<TAB>y" of the first overlapping prefix pair; return 0 if a
# pair overlaps (one is a string-prefix of the other), else return 1. Mirrors the guard.
first_overlap() {
  local a="$1" b="$2" x y saved="$IFS"
  IFS=:; set -- $a; local -a AA=("$@"); IFS="$saved"
  IFS=:; set -- $b; local -a BB=("$@"); IFS="$saved"
  for x in "${AA[@]:-}"; do
    [ -n "$x" ] || continue
    for y in "${BB[@]:-}"; do
      [ -n "$y" ] || continue
      case "$x" in "$y"*) printf '%s\t%s' "$y" "$x"; return 0 ;; esac
      case "$y" in "$x"*) printf '%s\t%s' "$x" "$y"; return 0 ;; esac
    done
  done
  return 1
}

# Pairwise scan (i<j only — never compare a track with itself).
coll_json='[]'
for ((i=0; i<count; i++)); do
  for ((j=i+1; j<count; j++)); do
    if pair="$(first_overlap "${prefs[$i]}" "${prefs[$j]}")"; then
      ap="${pair%%$(printf '\t')*}"; bp="${pair#*$(printf '\t')}"
      coll_json="$(echo "$coll_json" | jq -c \
        --arg a "${ids[$i]}" --arg b "${ids[$j]}" --arg ap "$ap" --arg bp "$bp" \
        '. + [{a:$a, b:$b, a_prefix:$ap, b_prefix:$bp}]')"
    fi
  done
done

ncoll="$(echo "$coll_json" | jq 'length')"
config_err="$(trim "$config_err")"
ok=true
{ [ "$ncoll" -eq 0 ] && [ -z "$config_err" ]; } || ok=false

jq -nc \
  --argjson ok "$ok" \
  --argjson tracks "$count" \
  --argjson collisions "$coll_json" \
  --arg cfg "$config_err" \
  '{ok:$ok, tracks:$tracks, collisions:$collisions,
    config_errors:($cfg | if . == "" then [] else split(" ") end)}'

[ "$ok" = true ] && exit 0 || exit 2
