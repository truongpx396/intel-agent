# Notion Sync – Detailed Workflow Reference

## Environment Setup

### Required Variables

| Variable | Description | Where to Set |
|---|---|---|
| `NOTION_TOKEN` | Notion integration secret (Internal Integration Token) | `.env` or shell environment |
| `NOTION_DB_ID` | The Notion database ID to sync against | `.env` or shell environment |
| `NOTION_WORK_BUCKET` | *(optional)* Work-bucket column name: `Phase` (default) or `Stage` | `.env` or shell environment |

Place both in the repo-root `.env` file (auto-loaded by the script):

```
NOTION_TOKEN=secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
NOTION_DB_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
# Optional — defaults to "Phase" when unset
# NOTION_WORK_BUCKET=Phase
```

### Prerequisites Check

```bash
# Verify .env is present
ls -la .env

# Dry-run status (no writes, no auth required beyond read)
python3 .claude/skills/notion-sync/scripts/sync_tasks.py status
```

---

## Command Reference

### `push` — tasks.md → Notion

Upserts every task from `tasks.md` into the Notion database. Creates missing pages, updates changed content. **Preserves** Notion `Status` by default.

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push
```

With `--push-status`: also writes checkbox states (`[ ]`, `[-]`, `[x]`) to Notion Status:

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status
```

**Fields pushed:** Task ID, work-bucket (`Phase`/`Stage`), Story, Parallel flag, Description, (optionally) Status.

---

### `pull` — Notion → tasks.md

Reads each task's `Status` from Notion and rewrites the corresponding checkbox marker in `tasks.md`.

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py pull
```

**Status mapping:**

| Notion Status | tasks.md marker |
|---|---|
| `Not Started` | `- [ ]` |
| `In Progress` | `- [-]` |
| `Done` | `- [x]` |

---

### `sync` — Bidirectional

Runs pull then push in sequence. Pulls Notion statuses first (re-parses the file), then pushes all content **plus** status back to Notion.

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sync
```

Equivalent to:
```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py pull && \
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status
```

---

### `status` — Read-only Diff

Prints a report of differences between `tasks.md` and Notion. Makes **no changes**.

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py status
```

Output includes:
- Task counts (local vs Notion)
- Notion status breakdown with bar chart
- Tasks with content or status differences
- Tasks only in `tasks.md` (not yet pushed)
- Tasks only in Notion (deleted locally)

---

### `sprint <N|all>` — Assign Sprint Tags

Assigns the Notion `Sprint` select property for all tasks whose work-bucket (`Phase`/`Stage`) belongs to the given sprint. Uses the mapping below.

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint 1
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint all
```

**Sprint → Work-bucket Mapping** (labels below use the default `Phase`; with `NOTION_WORK_BUCKET=Stage` the word becomes `Stage`):

| Sprint | Buckets |
|---|---|
| Sprint 1 | Phase 1 – Setup, Phase 2 – Foundation |
| Sprint 2 | Phase 3 – Ingest (US1), Phase 4 – Ask & Answer (US2) |
| Sprint 3 | Phase 5 – Team Workspace (US3), Phase 6 – Credit Metering (US4) |
| Sprint 4 | Phase 7 – Debug Panel (US5), Phase 8 – Admin Dashboard (US6) |
| Sprint 5 | Phase 9 – Local Agent (US7), Phase 10 – Notifications (US8), Phase 11 – Polish |

---

### `--dry-run` — Preview Without Writing

Append `--dry-run` to any command to preview what would happen without making any writes:

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --dry-run
python3 .claude/skills/notion-sync/scripts/sync_tasks.py pull --dry-run
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sync --dry-run
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint all --dry-run
```

---

## Typical Agent Workflow

**Scenario: Agent finishes implementing a task and marks it done in `tasks.md`.**

```bash
# 1. Mark done in tasks.md (agent edits the file)
#    - [x] T042  Implement ingestion pipeline webhook [US1]

# 2. Push status and content to Notion
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status

# Or, do a full bidirectional sync (pulls any Notion updates first)
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sync
```

**Scenario: PM updated statuses in Notion, agent needs latest state in `tasks.md`.**

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py pull
```

---

## tasks.md Task Format

The script parses tasks under `## Phase N` headings (`## Stage N` headings are also accepted):

```markdown
## Phase 1

- [ ] T001  Create the three-runtime directory structure
- [-] T002  [P] Initialize Go module in backend-go/go.mod
- [x] T003  [P] Initialize Python project in backend-python/pyproject.toml [US1]
```

**Markers:**
- `[P]` — Parallel task (Notion `Parallel` checkbox = true)
- `[USN]` — Story tag (e.g. `[US1]` → `US1 – Ingest Knowledge`)

Tasks not under a `## Phase N` / `## Stage N` heading are assigned bucket 1 (e.g. `Phase 1 – Setup`) by default. The bucket word written to Notion is controlled by `NOTION_WORK_BUCKET` (default `Phase`), regardless of which heading word the source file uses.

---

## Notion Database Schema

The target Notion database must have these properties:

| Property | Type | Notes |
|---|---|---|
| `Task ID` | Title | e.g. `T001` — rename the default `Name` column |
| `Status` | Select | Options: `Not Started` (gray), `In Progress` (yellow), `Done` (green) |
| `Phase` *(or `Stage`)* | Select | e.g. `Phase 1 – Setup` — column name set by `NOTION_WORK_BUCKET` (default `Phase`); options auto-created on push |
| `Story` | Select | e.g. `US1 – Ingest Knowledge` — options auto-created on push |
| `Description` | Rich Text | Task description (up to 2000 chars) |
| `Parallel` | Checkbox | Whether task can run in parallel |
| `Sprint` | Select | e.g. `Sprint 1` — options auto-created on sprint assignment |

### One-Command Schema Setup (New Database)

If starting from a blank Notion database (only has `Name` column), run the
setup script to create all required properties and rename `Name` → `Task ID`:

```bash
python3 .claude/skills/notion-sync/scripts/setup_notion_db.py
```

This script:
1. Reads `NOTION_TOKEN`, `NOTION_DB_ID`, and optional `NOTION_WORK_BUCKET` from `.env`
2. Renames the existing `Name` (Title) column to `Task ID`
3. Creates `Status` (Select) with preset options: `Not Started`, `In Progress`, `Done`
4. Creates the work-bucket column (`Phase` by default, or `Stage`), `Story`, `Sprint` as empty Select properties. If the *other* variant already exists (e.g. a `Stage` column when the configured name is `Phase`), it is renamed in place to preserve options + data + views
5. Creates `Description` as Rich Text
6. Creates `Parallel` as Checkbox
7. Prints the final list of properties on success

After running setup, proceed with the normal push workflow.

### Manual Setup (via Notion UI)

Alternatively, create each property manually in the Notion database:
1. Open the database → click `+` to add a property
2. Rename `Name` → `Task ID` (keep as **Title** type)
3. Add `Status` as **Select** → add options: `Not Started`, `In Progress`, `Done`
4. Add `Phase` (or `Stage`, to match `NOTION_WORK_BUCKET`) as **Select** (leave options empty — auto-filled on push)
5. Add `Story` as **Select** (leave options empty — auto-filled on push)
6. Add `Description` as **Text (Rich Text)**
7. Add `Parallel` as **Checkbox**
8. Add `Sprint` as **Select** (leave options empty — auto-filled on sprint command)

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `ERROR: NOTION_TOKEN not set` | Missing `.env` or env var | Add `NOTION_TOKEN=secret_...` to `.env` |
| `ERROR: NOTION_DB_ID not set` | Missing `.env` or env var | Add `NOTION_DB_ID=...` to `.env` |
| `ERROR: tasks.md not found` | Wrong working directory | Run from repo root, or check `TASKS_FILE` path in script |
| `401 Unauthorized` from Notion | Token is invalid or expired | Regenerate integration token in Notion settings |
| `404` on DB query | Wrong `NOTION_DB_ID` or integration not connected to DB | Share DB with the integration in Notion |
| `Task ID is not a property that exists` | Notion DB missing required columns | Run `setup_notion_db.py` (see Schema Setup above) |
| `Could not find database with ID` | Integration not connected to DB | In Notion: open the DB → `•••` → Connections → Add your integration |
| Tasks parsed as 0 | Malformed `tasks.md` (missing `## Phase N` / `## Stage N` or wrong checkbox format) | Ensure tasks follow `- [x] TYYY description` format |
| Rate limit errors | Too many rapid requests | Script enforces 0.35s delay; if still hitting limits, run again |
| `REPO_ROOT` resolves incorrectly | Script run from inside `.github/` subtree | Always run from the repo root (the folder containing `specs/` and `.env`) |
| `Group-by property "X" not found` | `group_by.property_id` requires internal ID, not name | The script uses `2022-06-28` to fetch property IDs — this is expected behavior |
| `Properties found: []` in views script | New API version returns properties differently | Script now fetches properties using `2022-06-28` and views using `2026-03-11` |

### REPO_ROOT Note

The sync script computes `REPO_ROOT` relative to its own file location
(`.claude/skills/notion-sync/scripts/` → 4 levels up = repo root). If you
move the script, update the `../` count in `REPO_ROOT` at the top of
`sync_tasks.py` accordingly.

---

## Recommended Notion Views

All views are created automatically via the `setup_notion_views.py` script:

```bash
python3 .claude/skills/notion-sync/scripts/setup_notion_views.py
```

The script is idempotent — it skips views that already exist. Requires API
version `2025-09-03` or later (`POST /v1/views`).

> **Note:** The Notion public API **now supports** creating views programmatically
> since version `2025-09-03`. The script uses `2026-03-11` for view creation
> and `2022-06-28` for property ID resolution (returns them reliably).

### How to Add a View Manually (Fallback)

If the script fails or you want to recreate a single view:

1. Open your Notion database
2. Click `+ Add a view` (next to the existing view tabs)
3. Type the view name → choose the layout type
4. Configure **Group** and/or **Filter** as described below
5. Click **Done**

### View Configurations (from screenshots)

#### Kanban Board
| Setting | Value |
|---|---|
| **Layout** | Board |
| **Group** | `Status` |
| **Filter** | `Sprint` *(filter by a specific sprint if desired)* |
| **Sub-group** | *(none)* |

Setup: `+ Add a view` → name `Kanban Board` → Board → Group: `Status`

---

#### Sprint Backlog
| Setting | Value |
|---|---|
| **Layout** | Board |
| **Group** | work-bucket (`Phase`/`Stage`) |
| **Filter** | `Status` *(e.g. filter to `Not Started` + `In Progress`)* |
| **Sub-group** | *(none)* |

Setup: `+ Add a view` → name `Sprint Backlog` → Board → Group: the work-bucket column (`Phase` by default, or `Stage`)

---

#### Sprint
| Setting | Value |
|---|---|
| **Layout** | Table |
| **Group** | *(none)* |
| **Quick filter** | `Sprint` — change the value to switch between sprints |

Setup: `+ Add a view` → name `Sprint` → Table → Quick filter: `Sprint`

To see a specific sprint, click the Sprint pill in the filter bar and select the desired value.

---

#### By Story
| Setting | Value |
|---|---|
| **Layout** | Board |
| **Group** | `Story` |
| **Filter** | *(none)* |
| **Sub-group** | *(none)* |

Setup: `+ Add a view` → name `By Story` → Board → Group: `Story`

---

#### Done
| Setting | Value |
|---|---|
| **Layout** | Table |
| **Group** | *(none)* |
| **Filter** | `Status` is `Done` |

Setup: `+ Add a view` → name `Done` → Table → Filter: `Status` = `Done`

---

### Summary Table

| View Name | Layout | Group | Filter / Quick Filter |
|---|---|---|---|
| Default view | Table | *(none)* | *(none)* |
| Kanban Board | Board | `Status` | Quick filter: `Sprint` |
| Sprint Backlog | Board | work-bucket (`Phase`/`Stage`) | Quick filter: `Status` |
| Sprint | Table | *(none)* | Quick filter: `Sprint` (change to see each sprint) |
| By Story | Board | `Story` | *(none)* |
| Done | Table | *(none)* | Filter: `Status` = `Done` |
