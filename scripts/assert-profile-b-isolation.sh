#!/usr/bin/env bash
# assert-profile-b-isolation.sh — prove the standalone profile is actually standalone.
#
# `make smoke` proves the runtime PRODUCES a cited answer. That alone does not
# prove it did so WITHOUT Qdrant and NATS — a smoke test passes just as green
# when a stray client is bound and quietly serving traffic. This script asserts
# the negative, which is the half of the claim that rots silently.
#
# Contract: specs/001-agent-runtime/contracts/agent-runtime.md
#   "the smoke (T060f) proves the deployed shape runs cited answers with
#    no Qdrant and no NATS"
set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE_FILE="deploy/compose.profile-b.yml"
fail=0

note() { printf '  %s\n' "$1"; }
bad()  { printf 'FAIL  %s\n' "$1" >&2; fail=$((fail + 1)); }

echo "Profile-B isolation assertions:"

# 1. No forbidden SERVICE in the compose topology.
if [ -f "$COMPOSE_FILE" ]; then
  if docker compose -f "$COMPOSE_FILE" config --services 2>/dev/null \
     | grep -qiE '^(qdrant|nats)$'; then
    bad "compose topology declares a qdrant/nats service"
  else
    note "compose topology: no qdrant, no nats"
  fi
else
  bad "missing $COMPOSE_FILE"
fi

# 2. No forbidden CLIENT importable in the running environment. An import that
#    resolves means a dependency edge exists, whether or not it was exercised.
if [ -d src ]; then
  if uv run python -c "
import importlib.util as u, sys
found = [m for m in ('qdrant_client', 'nats') if u.find_spec(m) is not None]
print(','.join(found))
sys.exit(1 if found else 0)
" 2>/dev/null; then
    note "python env: qdrant_client and nats not importable"
  else
    bad "a forbidden client (qdrant_client / nats) is installed in the Profile-B env"
  fi
fi

# 3. No forbidden ENDPOINT configured. A URL in the environment is a loaded gun
#    even if this particular run never fired it.
if env | grep -qiE '^(QDRANT|NATS)_'; then
  bad "environment carries QDRANT_*/NATS_* configuration"
else
  note "environment: no QDRANT_*/NATS_* variables"
fi

if [ "$fail" -gt 0 ]; then
  printf '\n%d isolation assertion(s) failed — this is a release blocker, not a flake.\n' "$fail" >&2
  exit 1
fi

echo "OK — the standalone profile is genuinely standalone."
