#!/usr/bin/env python3
"""
setup_notion_db.py — One-shot Notion database schema setup.

Creates all properties required by sync_tasks.py on a blank Notion database
(one that only has the default 'Name' title column). Safe to re-run: existing
properties are left untouched by the Notion API.

Usage (from repo root):
    python3 .claude/skills/notion-sync/scripts/setup_notion_db.py

Requires NOTION_TOKEN and NOTION_DB_ID in .env (or exported as env vars).

Properties created:
    Task ID     — Title      (renames existing 'Name' column)
    Status      — Select     options: Not Started, In Progress, Done
    Phase/Stage — Select     name controlled by NOTION_WORK_BUCKET (default Phase)
    Story       — Select     options auto-created on push
    Description — Rich Text
    Parallel    — Checkbox
    Sprint      — Select     options auto-created on sprint command
"""

import json
import os
import subprocess
import sys

# ── REPO_ROOT: 4 levels up from .claude/skills/notion-sync/scripts/ ─────────
REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../.."))


def load_dotenv(path: str) -> None:
    """Lightweight .env loader — no third-party deps required."""
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


def notion_request(method: str, endpoint: str, payload: dict, token: str) -> dict:
    cmd = [
        "curl", "-s", "-X", method,
        f"https://api.notion.com/v1/{endpoint}",
        "-H", f"Authorization: Bearer {token}",
        "-H", "Notion-Version: 2022-06-28",
        "-H", "Content-Type: application/json",
        "-d", json.dumps(payload),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    return json.loads(result.stdout)


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
    db = notion_request("GET", f"databases/{db_id}", {}, token)
    if db.get("object") != "database":
        print(f"❌ Could not fetch database: {db.get('message', db)}")
        sys.exit(1)

    existing = list(db.get("properties", {}).keys())
    print(f"   Existing properties: {existing}")

    # Work-bucket column name is configurable: "Phase" (default) or "Stage".
    work_bucket = (os.environ.get("NOTION_WORK_BUCKET", "Phase").strip() or "Phase").capitalize()
    if work_bucket not in ("Phase", "Stage"):
        work_bucket = "Phase"
    other_bucket = "Stage" if work_bucket == "Phase" else "Phase"

    # Build the PATCH payload
    props: dict = {}

    # Rename 'Name' → 'Task ID' if it exists under that key
    if "Name" in existing and "Task ID" not in existing:
        props["Name"] = {"name": "Task ID"}
        print("   → Renaming 'Name' to 'Task ID'")

    # If the other bucket name exists but the desired one doesn't, rename it in
    # place (preserves options + data + views). Otherwise create it below.
    renaming_bucket = other_bucket in existing and work_bucket not in existing
    if renaming_bucket:
        props[other_bucket] = {"name": work_bucket}
        print(f"   → Renaming '{other_bucket}' to '{work_bucket}'")

    if "Status" not in existing:
        props["Status"] = {
            "select": {
                "options": [
                    {"name": "Not Started", "color": "gray"},
                    {"name": "In Progress", "color": "yellow"},
                    {"name": "Done", "color": "green"},
                ]
            }
        }
        print("   → Creating 'Status' (Select)")

    for name in (work_bucket, "Story", "Sprint"):
        # Skip the work-bucket column if it is being created via an in-place rename
        if name == work_bucket and renaming_bucket:
            continue
        if name not in existing:
            props[name] = {"select": {"options": []}}
            print(f"   → Creating '{name}' (Select)")

    if "Description" not in existing:
        props["Description"] = {"rich_text": {}}
        print("   → Creating 'Description' (Rich Text)")

    if "Parallel" not in existing:
        props["Parallel"] = {"checkbox": {}}
        print("   → Creating 'Parallel' (Checkbox)")

    if not props:
        print("\n✅ Database already has all required properties — nothing to do.")
        return

    print("\n📝 Applying schema changes…")
    resp = notion_request("PATCH", f"databases/{db_id}", {"properties": props}, token)

    if resp.get("object") == "database":
        final = list(resp["properties"].keys())
        print(f"\n✅ Schema setup complete!")
        print(f"   Properties: {final}")
        print("\nYou can now push tasks:")
        print("   python3 .claude/skills/notion-sync/scripts/sync_tasks.py push --push-status")
    else:
        print(f"\n❌ Error: {resp.get('message', resp)}")
        sys.exit(1)


if __name__ == "__main__":
    main()
