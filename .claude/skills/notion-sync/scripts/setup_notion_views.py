#!/usr/bin/env python3
"""
setup_notion_views.py — Programmatically create all recommended Notion views.

Requires API version 2025-09-03 or later (this script uses 2026-03-11).
Creates views based on exact settings confirmed from the Notion UI:

    Kanban Board  — Board  | Group: Status  | Filter: Sprint (quick filter)
    Sprint Backlog — Board  | Group: work-bucket (Phase/Stage) | Filter: Status (quick filter)
    Sprint 1      — Table  | Filter: Sprint = "Sprint 1"
    Sprint        — Table  | Quick filter: Sprint (change per sprint as needed)
    By Story      — Board  | Group: Story
    Done          — Table  | Filter: Status = "Done"

Usage (from repo root):
    python3 .claude/skills/notion-sync/scripts/setup_notion_views.py

Requires NOTION_TOKEN and NOTION_DB_ID in .env (or exported as env vars).
Idempotent: skips views whose names already exist.

Notion API docs: https://developers.notion.com/reference/create-view
"""

import json
import os
import subprocess
import sys

NOTION_VERSION = "2026-03-11"
NOTION_VERSION_PROPS = "2022-06-28"  # older version returns properties reliably

# ── REPO_ROOT: 4 levels up from .claude/skills/notion-sync/scripts/ ─────────
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))


def load_dotenv(path: str) -> None:
    if not os.path.isfile(path):
        return
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key, val = key.strip(), val.strip().strip("\"'")
            if key not in os.environ:
                os.environ[key] = val


def notion_request(method: str, endpoint: str, payload: dict | None, token: str, version: str = NOTION_VERSION) -> dict:
    cmd = [
        "curl", "-s", "-X", method,
        f"https://api.notion.com/v1/{endpoint}",
        "-H", f"Authorization: Bearer {token}",
        "-H", f"Notion-Version: {version}",
        "-H", "Content-Type: application/json",
    ]
    if payload is not None:
        cmd += ["-d", json.dumps(payload)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(result.stdout)


def get_property_ids(db: dict) -> dict[str, str]:
    """Return a map of property name → property ID from the DB object."""
    return {
        name: prop.get("id", name)
        for name, prop in db.get("properties", {}).items()
    }


def get_data_source_id(db: dict) -> str:
    """Extract the first data_source_id from the database object."""
    sources = db.get("data_sources", [])
    if not sources:
        raise ValueError(
            "No data_sources found on database. "
            "Ensure the database was fetched with a recent API version."
        )
    return sources[0]["id"]


def main() -> None:
    load_dotenv(os.path.join(REPO_ROOT, ".env"))

    token = os.environ.get("NOTION_TOKEN", "")
    db_id = os.environ.get("NOTION_DB_ID", "")

    if not token:
        print("ERROR: NOTION_TOKEN not set. Add to .env or export it.")
        sys.exit(1)
    if not db_id:
        print("ERROR: NOTION_DB_ID not set. Add to .env or export it.")
        sys.exit(1)

    print(f"🔍 Fetching database {db_id[:8]}…")
    # Use newer version for data_sources; older version for properties (returns them reliably)
    db = notion_request("GET", f"databases/{db_id}", None, token)
    db_props = notion_request("GET", f"databases/{db_id}", None, token, version=NOTION_VERSION_PROPS)
    if db.get("object") != "database":
        print(f"❌ Could not fetch database: {db.get('message', db)}")
        sys.exit(1)

    props = get_property_ids(db_props)
    print(f"   Properties found: {list(props.keys())}")

    # Work-bucket column name is configurable: "Phase" (default) or "Stage".
    # Fall back to whichever variant actually exists in the database.
    work_bucket = (os.environ.get("NOTION_WORK_BUCKET", "Phase").strip() or "Phase").capitalize()
    if work_bucket not in ("Phase", "Stage"):
        work_bucket = "Phase"
    if work_bucket not in props:
        work_bucket = "Stage" if "Stage" in props else ("Phase" if "Phase" in props else work_bucket)

    try:
        data_source_id = get_data_source_id(db)
        print(f"   Data source ID: {data_source_id[:8]}…")
    except ValueError as e:
        print(f"❌ {e}")
        sys.exit(1)

    # ── View definitions (from confirmed Notion UI screenshots) ───────────────
    status_id = props.get("Status", "Status")
    phase_id  = props.get(work_bucket, work_bucket)
    story_id  = props.get("Story",  "Story")
    sprint_id = props.get("Sprint", "Sprint")

    # All property IDs in preferred display order for cards/columns
    all_prop_ids = [
        props.get("Task ID",     "Task ID"),
        props.get("Description", "Description"),
        props.get(work_bucket,   work_bucket),
        props.get("Sprint",      "Sprint"),
        props.get("Status",      "Status"),
        props.get("Story",       "Story"),
        props.get("Parallel",    "Parallel"),
    ]

    def visible_props(exclude_id: str | None = None) -> list[dict]:
        """All properties visible=True, except the group-by property (hidden)."""
        return [
            {"property_id": pid, "visible": pid != exclude_id}
            for pid in all_prop_ids
        ]

    views = [
        # ── Kanban Board: Board grouped by Status, Sprint as quick filter ─────
        {
            "name": "Kanban Board",
            "type": "board",
            "configuration": {
                "type": "board",
                "group_by": {
                    "type": "select",
                    "property_id": status_id,
                    "sort": {"type": "manual"},
                },
                "properties": visible_props(exclude_id=status_id),
            },
            "quick_filters": {
                "Sprint": {"select": {"equals": "Sprint 1"}},
            },
        },
        # ── Sprint Backlog: Board grouped by work-bucket, Status as quick filter ──
        {
            "name": "Sprint Backlog",
            "type": "board",
            "configuration": {
                "type": "board",
                "group_by": {
                    "type": "select",
                    "property_id": phase_id,
                    "sort": {"type": "manual"},
                },
                "properties": visible_props(exclude_id=phase_id),
            },
            "quick_filters": {
                "Status": {"select": {"equals": "Not Started"}},
            },
        },
        # ── Sprint: single Table with Sprint as a quick filter ─────────────────
        {
            "name": "Sprint",
            "type": "table",
            "configuration": {
                "type": "table",
                "properties": visible_props(),
            },
            "quick_filters": {
                "Sprint": {"select": {"equals": "Sprint 1"}},
            },
        },
        # ── By Story: Board grouped by Story ─────────────────────────────────
        {
            "name": "By Story",
            "type": "board",
            "configuration": {
                "type": "board",
                "group_by": {
                    "type": "select",
                    "property_id": story_id,
                    "sort": {"type": "manual"},
                },                "properties": visible_props(exclude_id=story_id),            },
        },
        # ── Done: Table filtered to Status = Done ─────────────────────────────
        {
            "name": "Done",
            "type": "table",            "configuration": {
                "type": "table",
                "properties": visible_props(),
            },            "filter": {
                "property": status_id,
                "select": {"equals": "Done"},
            },
        },
    ]

    # ── Fetch existing views with their IDs for upsert ───────────────────────
    existing_resp = notion_request("GET", f"views?database_id={db_id}", None, token)
    existing_views: dict[str, str] = {}  # name → view_id
    for v in existing_resp.get("results", []):
        detail = notion_request("GET", f"views/{v['id']}", None, token)
        existing_views[detail.get("name", "")] = v["id"]
    print(f"   Existing views: {list(existing_views.keys()) or '(none)'}\n")

    # ── Upsert views ──────────────────────────────────────────────────────────
    print("📐 Upserting views…")
    created = 0
    updated = 0
    errors  = 0

    for view_def in views:
        name = view_def["name"]

        if name in existing_views:
            # PATCH to apply property visibility + configuration
            view_id = existing_views[name]
            patch: dict = {}
            if "configuration" in view_def:
                patch["configuration"] = view_def["configuration"]
            if "filter" in view_def:
                patch["filter"] = view_def["filter"]
            if "quick_filters" in view_def:
                patch["quick_filters"] = view_def["quick_filters"]

            if not patch:
                print(f"  ⏭  {name}  (no changes)")
                continue

            resp = notion_request("PATCH", f"views/{view_id}", patch, token)
            if resp.get("object") == "view":
                print(f"  ✏️   {name}  (updated)")
                updated += 1
            else:
                print(f"  ❌  {name}  — {resp.get('message', resp)[:120]}")
                errors += 1
            continue

        # CREATE new view
        payload: dict = {
            "database_id":    db_id,
            "data_source_id": data_source_id,
            "name":  name,
            "type":  view_def["type"],
        }
        if "configuration" in view_def:
            payload["configuration"] = view_def["configuration"]
        if "filter" in view_def:
            payload["filter"] = view_def["filter"]
        if "quick_filters" in view_def:
            payload["quick_filters"] = view_def["quick_filters"]

        resp = notion_request("POST", "views", payload, token)
        if resp.get("object") == "view":
            print(f"  ✅  {name}  ({view_def['type']})")
            created += 1
        else:
            print(f"  ❌  {name}  — {resp.get('message', resp)[:120]}")
            errors += 1

    print(f"\n{'='*55}")
    print(f"  Views: {created} created  |  {updated} updated  |  {errors} errors")
    print(f"{'='*55}")

    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
