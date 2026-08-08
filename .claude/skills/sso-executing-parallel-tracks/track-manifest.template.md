# Parallel Tracks Orchestrator Manifest — <PROJECT NAME>

Orchestrator-level configuration for the `sso-executing-parallel-tracks` skill.
This file holds **only** project-wide defaults and shared constraints — nothing
specific to any individual track. Per-track details (branch, worktree path, task
list, owned paths) live in the **wave dispatch file** generated at Step 0.

Keep this file checked in at `.github/tracks/manifest.md`. The skill auto-creates
it on first run if absent.

---

## Orchestrator Defaults

- **default_branch**: `main`
- **worktree_root**: `..` (worktrees created as siblings, e.g. `../<repo>-<track_id>`)
- **docker_namespace_pattern**: `<repo>_<track_id>` (exported as `COMPOSE_PROJECT_NAME`)
- **max_concurrent_tracks**: `2`  <!-- raise only if the Docker host has headroom -->
- **runs_dir**: `runs/` (git-ignored; run records live here)
- **notify_webhook**: `<optional Slack/Discord URL, or leave blank to disable>`

> **Mechanical ceilings** are set in `.github/hooks/track-env.base.sh`, not here:
> `TRACK_MAX_TOOL_CALLS` (tool-call proxy for the iteration ceiling) and
> `TRACK_MAX_TOKEN_ESTIMATE` (token-estimate ceiling; blocks stop + writes `status=budget-exceeded`
> when exceeded; set to `0` to disable).

---

## Commands

| Purpose | Command |
|---|---|
| lint | `<e.g. make lint>` |
| unit test | `<e.g. make test>` |
| integration test | `<e.g. go test -tags=integration ./... ; pytest -m integration>` |
| e2e | `<e.g. npx playwright test>` |
| regenerate Go lockfile | `go mod tidy` |
| regenerate Python lockfile | `uv lock` |
| open PR | `gh pr create --fill --base <default_branch>` |

## Evidence pack (required to claim done)

The rows a worker MUST produce fresh, passing output for before finishing — the
mechanical form of “missing rows = not done.” The skill ships the *gate*; this table
supplies the stack-specific *content*. Each row is a `kind` label + the command
pattern that satisfies it. `track-evidence.sh` tags matching runs with the label;
`track-evidence-gate.sh` blocks the stop until every **required** kind has a fresh
(current-tree) passing entry.

| kind | command pattern (ERE) | required when… | path glob (selects this kind) |
|---|---|---|---|
| `go-test` | `<e.g. go test -race .*\./\.\.\.>` | any `.go` change | `*.go` |
| `py` | `<e.g. uv run pytest>` | any `.py` change | `*.py` |
| `ts` | `<e.g. tsc --noEmit>` | any `.ts/.tsx` change | `*.ts` ; `*.tsx` |
| `pg-explain` | `<e.g. EXPLAIN \(ANALYZE>` | query/migration changes | `migrations/*` ; `*/queries/*.sql` |
| `nats` | `<e.g. nats consumer info>` | producer/consumer changes | `*/events/*` ; `*/nats/*` |
| `redis` | `<e.g. redis-cli TTL>` | new Redis interactions | `*/cache/*` ; `*/redis/*` |

- **TRACK_EVIDENCE_KINDS** = the `kind:pattern` (command-ERE) pairs above, `;`-joined.
- **TRACK_EVIDENCE_RULES** = the `glob:kind` path→kind selector pairs, `;`-joined,
  e.g. `*.go:go-test;*.py:py;*.tsx:ts;*.ts:ts;migrations/*:pg-explain`.
- **TRACK_REQUIRED_EVIDENCE** (optional floor) = kinds required on every diff regardless
  of paths, comma-joined. Leave empty to rely purely on the rules.
- **TRACK_FAIL_PATTERN** (optional) = stack-specific failure markers the generic
  default misses.

Requirements are **diff-conditional**: a kind is required only when the branch's
diff touches a path matching its glob — so a frontend-only task demands `ts`, never
`pg-explain`.

---

## Frozen entrypoints (self-registration required)

Files that must NOT be edited per track; tracks register via their own module/router file.

- `<e.g. backend-go/cmd/api/main.go — iterates module registry>`
- `<e.g. backend-python/src/app.py — iterates APIRouter list>`

---

## Ownership map (shared resources)

| Shared resource | Owner | Rule for everyone else |
|---|---|---|
| dependency manifest (`go.mod` / `pyproject.toml`) | one track per language this wave | others request via owner; never edit another language's manifest |
| lockfiles (`go.sum` / `uv.lock`) | the PR being merged | NEVER hand-merge — regenerate after rebase |
| `<shared types/enums file>` | append-only | add symbols; never edit the middle |

---

## Invariants to assert in review

Release-blockers the code-quality reviewer must confirm on every relevant diff.

- `<e.g. access control deny-by-default + zero-above-clearance (SC-001)>`
- `<e.g. kernel/ must never import internal/>`

---

## Hook environment (derived — do not invent values)

Every value is derived from a field in this manifest or from the wave dispatch
file. Export per-track vars inside each worker's launch; global vars are identical
across all workers in a wave.

| Env var | Scope | Hook | Derived from |
|---|---|---|---|
| `TRACK_ALLOWED_PREFIXES` | **per-track** | `track-guard.sh` | the track's `owns_paths` in the **wave dispatch file** (colon-separated) |
| `TRACK_FROZEN_PATHS` | global | `track-guard.sh` | **Frozen entrypoints** list (colon-separated) |
| `RUN_ID` | **per-track** | evidence/meter/trace/notify | run-id minted at dispatch (`<UTC-timestamp>_<track_id>`) |
| `RUNS_DIR` | global | evidence/meter/trace/notify | **Defaults → runs_dir** |
| `TRACK_TEST_CMD_PATTERN` | global | `track-evidence.sh` | ERE OR-ing the **Commands** unit + integration entries |
| `TRACK_EVIDENCE_KINDS` | global | `track-evidence.sh` | **Evidence pack** `kind:pattern` pairs, `;`-joined |
| `TRACK_EVIDENCE_RULES` | global | `track-evidence-gate.sh` | **Evidence pack** `glob:kind` pairs, `;`-joined |
| `TRACK_REQUIRED_EVIDENCE` | global | `track-evidence-gate.sh` | **Evidence pack** always-on floor kinds, comma-joined |
| `TRACK_FAIL_PATTERN` | global | `track-evidence-gate.sh` | **Evidence pack** stack-specific failure markers |
| `TRACK_MAX_TOOL_CALLS` | global | `track-meter.sh` | set in `track-env.base.sh` (tool-call ceiling proxy) |
| `TRACK_NOTIFY_WEBHOOK` | global | `track-notify.sh` | **Defaults → notify_webhook** |
