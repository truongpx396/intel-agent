#!/usr/bin/env bash
# check-links.sh — verify every RELATIVE markdown link in this repo resolves.
#
# Why this is a CI gate and not a nicety: the contracts here were moved out of
# aisat-intel by `git filter-repo`, and they carried ~40 relative links written
# against the OLD tree (../plan.md, ./llm-gateway.md, ../../draft-plan.md, ...).
# A link that silently 404s is how an extracted spec rots into fiction. This
# script is the mechanical check that the extraction stayed honest.
#
# Checks relative targets only. Absolute URLs (http/https), mailto:, and bare
# in-page anchors (#foo) are out of scope.
set -euo pipefail

cd "$(dirname "$0")/.."

fail=0
checked=0

while IFS= read -r md; do
  # Pull the target out of every ](...) link on the page.
  while IFS= read -r target; do
    [ -z "$target" ] && continue
    case "$target" in
      http://*|https://*|mailto:*|"#"*) continue ;;
    esac
    # Strip any #anchor — we verify the file exists, not the heading.
    path="${target%%#*}"
    [ -z "$path" ] && continue
    resolved="$(cd "$(dirname "$md")" && printf '%s' "$(pwd)/$path")"
    checked=$((checked + 1))
    if [ ! -e "$resolved" ]; then
      printf 'BROKEN  %s\n          -> %s\n' "$md" "$target" >&2
      fail=$((fail + 1))
    fi
  done < <(grep -oE '\]\([^)]+\)' "$md" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' || true)
done < <(find . -name '*.md' \
  -not -path './.git/*' \
  -not -path './.claude/skills/*' \
  -not -path './.github/instructions/*' \
  -not -path './.github/agents/*' \
  -not -path './.github/prompts/*' \
  -not -path './.specify/templates/*' \
  -print)
# Excluded above: vendored guidance docs whose ](...) fragments are ILLUSTRATIVE
# examples ("./scripts/helper.py"), not links into this repo. They are upstream
# artifacts we sync rather than author, so linting them produces only noise.

if [ "$fail" -gt 0 ]; then
  printf '\n%d broken relative link(s) out of %d checked.\n' "$fail" "$checked" >&2
  exit 1
fi

printf 'OK — %d relative link(s) resolve.\n' "$checked"
