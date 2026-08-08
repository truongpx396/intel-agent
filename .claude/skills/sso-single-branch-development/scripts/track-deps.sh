#!/usr/bin/env bash
# track-deps.sh — Dependency version-lock verifier + TTL cache for the
# sso-single-branch-development bundle. Solves two footguns at once:
#
#   1. VERSION DRIFT (the lock). A repo pins the versions of the external tools this
#      skill leans on (git, jq, and optionally superpowers/speckit/go/uv/node) in a
#      COMMITTED manifest — .github/hooks/skill-deps.json — so every checkout/worktree
#      that installs the bundle is checked against the SAME ranges. A tool that is
#      missing, or whose version falls outside the pinned range, is surfaced HERE (at
#      the start gate) instead of blowing up mid-run.
#   2. REDUNDANT HEAVY PROBES (the cache). Resolving a tool's version can be slow
#      (a subprocess per tool, sometimes a network touch). Re-running that on every
#      single preflight is wasteful, so a GOOD result is cached under runs/ (gitignored,
#      machine-local) and reused until it expires (TRACK_DEPS_CACHE_TTL_HOURS, default 72)
#      or the inputs change (PATH or the manifest). Only a fully-OK result is cached —
#      a failing environment is re-checked every time so a fix is picked up immediately.
#
# Why a COMMITTED manifest but a GITIGNORED cache: the manifest is a policy fact shared
# by the whole team (it must travel in git); the cache is a machine-local performance
# artifact and must NOT (caching "go is installed" into a committed file would make a
# teammate's checkout skip the check and inherit a false claim — exactly the mid-run
# failure the lock exists to prevent). Same split as track-env.base.sh vs the run record.
#
# Config (env; sourced from track-env.sh / track-env.base.sh beside this script):
#   TRACK_DEPS_MANIFEST        path to skill-deps.json. Empty ⇒ auto: <hooks dir>/skill-deps.json.
#                              Absent manifest ⇒ NO-OP exit 0 (the lock is opt-in).
#   TRACK_DEPS_CACHE_TTL_HOURS cache lifetime in hours (default 72). 0 ⇒ never cache (always fresh).
#   TRACK_DEPS_STRICT          1 ⇒ an out-of-range version hard-fails (exit 3); 0 (default) ⇒ warn.
#                              A REQUIRED dep that is entirely MISSING hard-fails regardless.
#   RUNS_DIR                   cache home (default "runs"); anchored to the main worktree.
#
# Modes:
#   (default / --verify)  use the cache when valid, else resolve + verify + (re)write cache.
#   --refresh             ignore any cached result and re-resolve (still rewrites the cache).
#   --json                emit the result object as JSON on stdout (implies verify).
#   --print               human summary only (no JSON), same exit semantics.
#
# Exit: 0 = OK (all required deps present; no hard-fail). 3 = lock violation
#       (a required dep missing, or STRICT and an out-of-range version). 2 = usage error.
# Requires: bash, jq. Keep runtime < 2s on a cache hit, < 5s on a cold resolve.
set -eufo pipefail

# --- bootstrap: source the hook presets sitting beside this script (same as preflight) ---
__env_dir="${BASH_SOURCE[0]%/*}"
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
__hooks_dir="$__env_dir"
unset __env_dir

mode="verify"; emit_json=0
for a in "$@"; do
  case "$a" in
    --verify) mode="verify" ;;
    --refresh) mode="refresh" ;;
    --json) emit_json=1 ;;
    --print) emit_json=0 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'track-deps: unknown arg: %s\n' "$a" >&2; exit 2 ;;
  esac
done

err() { printf '%s\n' "track-deps: $1" >&2; }
command -v jq >/dev/null 2>&1 || { err "jq not found."; exit 2; }

# --- resolve the manifest path -----------------------------------------------
manifest="${TRACK_DEPS_MANIFEST:-}"
[ -n "$manifest" ] || manifest="$__hooks_dir/skill-deps.json"
if [ ! -f "$manifest" ]; then
  err "no manifest at $manifest — dependency lock not configured (no-op)."
  [ "$emit_json" = 1 ] && printf '%s\n' '{"schema":1,"configured":false,"ok":true,"results":{}}'
  exit 0
fi
jq empty "$manifest" 2>/dev/null || { err "manifest $manifest is not valid JSON."; exit 2; }

ttl_hours="${TRACK_DEPS_CACHE_TTL_HOURS:-72}"
case "$ttl_hours" in ''|*[!0-9]*) ttl_hours=72 ;; esac
strict="${TRACK_DEPS_STRICT:-0}"; [ "$strict" = "1" ] || strict=0

# --- anchor RUNS_DIR to the main worktree (same rule as preflight) -----------
RUNS_DIR="${RUNS_DIR:-runs}"
case "$RUNS_DIR" in
  /*) ;;
  *)
    __rgcd="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$__rgcd" ]; then
      case "$__rgcd" in /*) ;; *) __rgcd="$PWD/$__rgcd" ;; esac
      __rroot="$(cd "$__rgcd/.." 2>/dev/null && pwd || true)"
      [ -n "$__rroot" ] && RUNS_DIR="$__rroot/$RUNS_DIR"
      unset __rroot
    fi
    unset __rgcd
    ;;
esac
cache="$RUNS_DIR/.deps-cache.json"

# --- helpers -----------------------------------------------------------------
_hash() { if command -v shasum >/dev/null 2>&1; then shasum | cut -d' ' -f1; else sha1sum | cut -d' ' -f1; fi; }
_now_epoch() { date -u +%s; }
# ISO-8601-UTC → epoch, portable across BSD/macOS (date -j -f) and GNU (date -d).
_to_epoch() { date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo ""; }

# _vercmp A B → echoes -1|0|1 (A<B | A==B | A>B). Dotted-numeric only; non-digits stripped.
_vercmp() {
  local a b i x y n; local -a A B
  IFS=. read -r -a A <<<"$(printf '%s' "$1" | tr -cd '0-9.')"
  IFS=. read -r -a B <<<"$(printf '%s' "$2" | tr -cd '0-9.')"
  n=${#A[@]}; [ ${#B[@]} -gt "$n" ] && n=${#B[@]}
  for ((i=0; i<n; i++)); do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    x=$((10#${x:-0})); y=$((10#${y:-0}))
    [ "$x" -gt "$y" ] && { echo 1; return; }
    [ "$x" -lt "$y" ] && { echo -1; return; }
  done
  echo 0
}

# _satisfies VERSION RANGE → echoes 1 (satisfied / empty range) or 0. Space-separated AND-list;
# each term is >= | > | <= | < | = prefix + version, or a bare version (⇒ >=).
_satisfies() {
  local v="$1" range="$2" c op want cmp
  [ -n "$range" ] || { echo 1; return; }
  for c in $range; do
    case "$c" in
      '>='*) op='>='; want="${c#>=}" ;;
      '<='*) op='<='; want="${c#<=}" ;;
      '=='*) op='=';  want="${c#==}" ;;
      '>'*)  op='>';  want="${c#>}" ;;
      '<'*)  op='<';  want="${c#<}" ;;
      '='*)  op='=';  want="${c#=}" ;;
      *)     op='>='; want="$c" ;;
    esac
    [ -n "$want" ] || continue
    cmp="$(_vercmp "$v" "$want")"
    case "$op" in
      '>=') [ "$cmp" -ge 0 ] || { echo 0; return; } ;;
      '>')  [ "$cmp" -gt 0 ] || { echo 0; return; } ;;
      '<=') [ "$cmp" -le 0 ] || { echo 0; return; } ;;
      '<')  [ "$cmp" -lt 0 ] || { echo 0; return; } ;;
      '=')  [ "$cmp" -eq 0 ] || { echo 0; return; } ;;
    esac
  done
  echo 1
}

_extract_ver() { printf '%s' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true; }

path_hash="$(printf '%s' "${PATH:-}" | _hash)"
manifest_hash="$(_hash < "$manifest")"

# --- fast path: a valid, non-expired, matching cache -------------------------
cache_hit=0
if [ "$mode" != "refresh" ] && [ "$ttl_hours" -gt 0 ] && [ -f "$cache" ] && jq empty "$cache" 2>/dev/null; then
  c_schema="$(jq -r '.schema // empty' "$cache" 2>/dev/null || true)"
  c_ph="$(jq -r '.path_hash // empty' "$cache" 2>/dev/null || true)"
  c_mh="$(jq -r '.manifest_hash // empty' "$cache" 2>/dev/null || true)"
  c_ttl="$(jq -r '.ttl_hours // empty' "$cache" 2>/dev/null || true)"
  c_ok="$(jq -r '.ok // false' "$cache" 2>/dev/null || true)"
  c_when="$(jq -r '.resolved_utc // empty' "$cache" 2>/dev/null || true)"
  if [ "$c_schema" = "1" ] && [ "$c_ph" = "$path_hash" ] && [ "$c_mh" = "$manifest_hash" ] \
     && [ "$c_ttl" = "$ttl_hours" ] && [ "$c_ok" = "true" ] && [ -n "$c_when" ]; then
    w_epoch="$(_to_epoch "$c_when")"; now="$(_now_epoch)"
    if [ -n "$w_epoch" ] && [ $((now - w_epoch)) -lt $((ttl_hours * 3600)) ]; then
      cache_hit=1
    fi
  fi
fi

if [ "$cache_hit" = 1 ]; then
  n="$(jq -r '.results | length' "$cache")"
  err "cache hit — $n dep(s) verified $c_when (ttl ${ttl_hours}h, $cache). Use --refresh to re-check."
  [ "$emit_json" = 1 ] && jq -c '.cached = true' "$cache"
  exit 0
fi

# --- cold resolve: probe every declared dependency ---------------------------
results='{}'
ok=true; violations=""; warnings=""
deps="$(jq -r '.dependencies | keys[]' "$manifest" 2>/dev/null || true)"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  range="$(jq -r --arg n "$name" '.dependencies[$n].range // ""' "$manifest")"
  probe="$(jq -r --arg n "$name" '.dependencies[$n].probe // ""' "$manifest")"
  required="$(jq -r --arg n "$name" '.dependencies[$n].required // false' "$manifest")"
  bin="${probe%% *}"; [ -n "$bin" ] || bin="$name"
  present=false; version=""; in_range=true
  if command -v "$bin" >/dev/null 2>&1; then
    out="$( $probe 2>&1 || true )"
    version="$(_extract_ver "$out")"
    [ -n "$version" ] && present=true
  fi
  if [ "$present" = true ] && [ -n "$range" ]; then
    [ "$(_satisfies "$version" "$range")" = 1 ] && in_range=true || in_range=false
  fi
  # classify
  if [ "$present" != true ]; then
    if [ "$required" = "true" ]; then ok=false; violations="$violations $name(missing)";
    else warnings="$warnings $name(missing)"; fi
  elif [ "$in_range" != true ]; then
    if [ "$required" = "true" ] && [ "$strict" = 1 ]; then ok=false; violations="$violations $name($version!~$range)";
    else warnings="$warnings $name($version!~$range)"; fi
  fi
  results="$(printf '%s' "$results" | jq -c \
    --arg n "$name" --argjson pr "$present" --arg v "$version" --arg r "$range" \
    --argjson ir "$in_range" --argjson req "$required" \
    '.[$n] = {present:$pr, version:(if $v=="" then null else $v end), range:$r, in_range:$ir, required:$req}')"
done <<<"$deps"

violations="$(printf '%s' "$violations" | sed 's/^ *//')"
warnings="$(printf '%s' "$warnings" | sed 's/^ *//')"
resolved_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

record="$(jq -nc \
  --argjson results "$results" --argjson ok "$ok" \
  --arg resolved "$resolved_utc" --arg ph "$path_hash" --arg mh "$manifest_hash" \
  --argjson ttl "$ttl_hours" --argjson strict "$([ "$strict" = 1 ] && echo true || echo false)" \
  --arg violations "$violations" --arg warnings "$warnings" \
  '{schema:1, configured:true, ok:$ok, cached:false, resolved_utc:$resolved, path_hash:$ph, manifest_hash:$mh,
    ttl_hours:$ttl, strict:$strict,
    violations:($violations | if .=="" then [] else split(" ") end),
    warnings:($warnings | if .=="" then [] else split(" ") end),
    results:$results}')"

# Cache ONLY a fully-OK result: a failing environment must be re-checked every run so a
# fix is picked up immediately (not masked for up to ttl_hours).
if [ "$ok" = true ] && [ "$ttl_hours" -gt 0 ]; then
  mkdir -p "$RUNS_DIR" 2>/dev/null || true
  if [ -w "$RUNS_DIR" ]; then
    tmp="$(mktemp)"; printf '%s\n' "$record" >"$tmp" && mv "$tmp" "$cache"
  fi
fi

# --- report ------------------------------------------------------------------
if [ "$ok" = true ]; then
  msg="OK — deps verified $resolved_utc"
  [ -n "$warnings" ] && msg="$msg (warnings: $warnings)"
  err "$msg"
else
  err "LOCK VIOLATION — $violations$([ -n "$warnings" ] && printf ' (warnings: %s)' "$warnings")"
fi

[ "$emit_json" = 1 ] && printf '%s\n' "$record"
[ "$ok" = true ] || exit 3
exit 0
