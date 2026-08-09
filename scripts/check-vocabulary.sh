#!/usr/bin/env bash
# check-vocabulary.sh — keep this repo readable without the repo it came from.
#
# intel-agent was extracted from aisat-intel, and the moved contracts originally
# spoke that host's vocabulary: workspace_id, effective_access_level, BFF, <ws>,
# SC-0xx, FR-0xx. Every one of those is a small "go read the other repo" tax on a
# developer building against these contracts, and they creep back one edit at a
# time. This makes the boundary mechanical instead of a matter of remembering.
#
# THE RULE (contracts/agent-graph.md, Reading conventions):
#   Normative prose uses the domain-agnostic vocabulary: tenant, principal,
#   agent_role, claims. A reference-host example is allowed ONLY when marked
#   "*reference host:*" on the same line -- an illustration, never a requirement.
set -euo pipefail

cd "$(dirname "$0")/.."

# Author-owned specs only. Vendored guidance under .claude/ and .github/ is
# synced from upstream, not written here.
FILES=$(find specs README.md -name '*.md' 2>/dev/null)

# Terms that are meaningless outside the reference host.
BANNED='workspace_id|effective_access_level|SingleAxisPolicy|credit_ledger|Casdoor|<ws>|\bAISAT\b'
# Old requirement series. Local ones are AR-xxx and SC-Axx.
STALE_IDS='\bFR-[0-9]{3}|\bSC-[0-9]{3}'

fail=0
report() { printf '  %s:%s\n      %s\n' "$1" "$2" "$3" >&2; fail=$((fail + 1)); }

for f in $FILES; do
  while IFS=: read -r ln text; do
    [ -z "${ln:-}" ] && continue
    # Allowed when the line marks itself as a reference-host illustration,
    # or is the conventions note that defines the rule.
    lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *'*reference host:*'*|*'reading conventions'*) continue ;;
    esac
    report "$f" "$ln" "$(printf '%.120s' "$text")"
  done < <(grep -nE "$BANNED" "$f" 2>/dev/null || true)

  while IFS=: read -r ln text; do
    [ -z "${ln:-}" ] && continue
    # The traceability tables in spec.md and tasks.md exist precisely to map
    # old ids to new ones, so they are the one place old ids belong.
    case "$f" in */spec.md|*/tasks.md) continue ;; esac
    case "$text" in *'aisat-intel'*) continue ;; esac
    report "$f" "$ln" "$(printf '%.120s' "$text")"
  done < <(grep -nE "$STALE_IDS" "$f" 2>/dev/null || true)
done

if [ "$fail" -gt 0 ]; then
  cat >&2 <<'EOF'

Reference-host vocabulary leaked into normative prose.

Fix by either:
  1. using the domain-agnostic term (tenant / principal / agent_role / claims), or
  2. marking the line as an illustration with "*reference host:*", e.g.
       ... the store's tenant session context (*reference host:* `app.workspace_id`)

Old requirement ids (FR-xxx / SC-xxx) belong only in the traceability tables of
spec.md and tasks.md. Elsewhere use the local AR-xxx / SC-Axx series.
EOF
  exit 1
fi

echo "OK — no reference-host vocabulary in normative prose."
