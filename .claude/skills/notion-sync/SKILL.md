---
name: notion-sync
description: Bidirectional sync between tasks.md and a Notion database. Use when asked to push tasks to Notion, pull Notion statuses into tasks.md, sync task progress, assign sprints, or check sync status between local markdown task files and Notion. Supports push, pull, bidirectional sync, status diff, sprint assignment, and dry-run previews.
---

# Notion Sync

Keeps `specs/*/tasks.md` and a Notion database in sync via a Python script that uses the Notion REST API (no extra dependencies — calls `curl` under the hood).

## When to Use This Skill

- User asks to **push tasks to Notion** after implementing or updating `tasks.md`
- User asks to **pull Notion statuses** back into `tasks.md` checkboxes
- User asks to **sync tasks** or keep Notion up to date
- User asks to **check what's out of sync** between `tasks.md` and Notion
- User asks to **assign sprints** to Notion task pages
- User wants a **dry-run preview** of any sync operation
- Agent finishes a task and needs to mark it done in both places

## Prerequisites

1. **Python 3.9+** available in the environment (`python3 --version`)
2. **`curl`** available (`curl --version`)
3. **`.env` at repo root** (or exported environment variables) containing:
   ```
   NOTION_TOKEN=secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   NOTION_DB_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   # Optional — work-bucket column name: "Phase" (default) or "Stage"
   # NOTION_WORK_BUCKET=Phase
   ```
4. The Notion integration must be **connected to the target database** (share the DB with the integration in Notion → `•••` → Connections → Add your integration)
5. The Notion database must have the **required schema** (7 properties). See Step 0 below.
6. `tasks.md` must exist at `specs/001-contextengine-mvp/tasks.md` with the standard format:
   ```markdown
   ## Phase 1
   - [ ] T001  Task description [US1]
   ```
   > Both `## Phase N` and `## Stage N` headings are accepted on parse. The
   > matching Notion column name is controlled by `NOTION_WORK_BUCKET`
   > (default `Phase`).

> **REPO_ROOT note:** The script resolves paths 4 levels up from its own location
> (`.claude/skills/notion-sync/scripts/` → repo root). Always run commands from
> the repo root directory (the folder containing `specs/` and `.env`).

## Quick Reference

| Command | What It Does |
|---|---|
| `push` | `tasks.md` → Notion (upsert content, preserve Notion status) |
| `push --push-status` | `tasks.md` → Notion (upsert content **and** status) |
| `pull` | Notion → `tasks.md` (update checkboxes from Notion Status) |
| `sync` | Pull status first, then push content + status (full bidirectional) |
| `status` | Read-only diff report (no writes) |
| `sprint <N\|all>` | Assign `Sprint` field in Notion based on work-bucket mapping |
| `--dry-run` | Preview any command without writing anything |

## Step-by-Step Workflows

### 0. First-Time Setup — Create Notion DB Schema

If the Notion database is new (blank or only has a `Name` column), run the
setup script **once** to create all required properties:

```bash
python3 .claude/skills/notion-sync/scripts/setup_notion_db.py
```

This creates: `Task ID` (Title), `Status` (Select w/ options), the work-bucket
column (`Phase` by default, or `Stage` if `NOTION_WORK_BUCKET=Stage`) (Select),
`Story` (Select), `Description` (Rich Text), `Parallel` (Checkbox), `Sprint` (Select).
If the database already has the *other* variant (e.g. a `Stage` column when the
configured name is `Phase`), it is renamed in place to preserve options + data + views.

See [Notion Database Schema](./references/workflow.md#notion-database-schema) for the
full property table, manual setup steps, and troubleshooting.

### 1. Check Current Sync State

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py status
```

Always run this first to understand what's out of sync before making changes.

### 2. Push Local Changes to Notion

After editing `tasks.md` (new tasks, updated descriptions, or marking tasks done):

```bash
# Push content only (preserves Notion status)
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push

# Push content AND status (when you've marked tasks done in tasks.md)
python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status
```

### 3. Pull Notion Status into tasks.md

After a PM or teammate updates statuses in Notion:

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py pull
```

### 4. Full Bidirectional Sync (Recommended After Sprints)

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sync
```

Runs pull (Notion → tasks.md), re-parses, then push with status (tasks.md → Notion).

### 5. Assign Sprints

```bash
# Assign a single sprint
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint 1

# Assign all sprints at once
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint all
```

### 6. Dry-Run Any Command

```bash
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sync --dry-run
python3 .claude/skills/notion-sync/scripts/sync_tasks.py sprint all --dry-run
```

## Typical Agent Flow

When an agent finishes implementing a task:

1. Edit `tasks.md` to mark the task done: `- [x] T042  ...`
2. Run: `python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status`
3. Verify with: `python3 .claude/skills/notion-sync/scripts/sync_tasks.py status`

### 7. Set Up Notion Views (One Command)

Create all recommended views programmatically:

```bash
python3 .claude/skills/notion-sync/scripts/setup_notion_views.py
```

This creates all 5 views (idempotent — skips any that already exist):

| View Name | Layout | Group | Filter / Quick Filter |
|---|---|---|---|
| Kanban Board | Board | `Status` | Quick filter: `Sprint` |
| Sprint Backlog | Board | work-bucket (`Phase`/`Stage`) | Quick filter: `Status` |
| Sprint | Table | — | Quick filter: `Sprint` (change per sprint) |
| By Story | Board | `Story` | — |
| Done | Table | — | Filter: `Status` = `Done` |

> **API version note:** Requires Notion API `2025-09-03` or later.
> The script uses `2026-03-11` for view creation and `2022-06-28` for property
> ID resolution (which returns them reliably).

See [Recommended Notion Views](./references/workflow.md#recommended-notion-views) for
full per-view settings and manual setup fallback.

## References

- [Full Workflow & Troubleshooting Guide](./references/workflow.md) — Detailed command docs, environment setup, tasks.md format, DB schema setup, view setup, troubleshooting table
- [Sync Script](./scripts/sync_tasks.py) — The Python script (no third-party deps; uses `curl` for Notion API calls)
- [DB Setup Script](./scripts/setup_notion_db.py) — One-shot script to create all required Notion DB properties on a blank database
- [Views Setup Script](./scripts/setup_notion_views.py) — Creates all 9 recommended views via `POST /v1/views` (requires API v2025-09-03+)
