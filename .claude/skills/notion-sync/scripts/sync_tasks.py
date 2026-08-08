#!/usr/bin/env python3
"""
Bidirectional sync between tasks.md ↔ Notion Database.

Usage:
  python3 sync_tasks.py push           # tasks.md → Notion  (upsert, preserves Notion Status)
  python3 sync_tasks.py pull           # Notion → tasks.md  (updates checkboxes from Notion Status)
  python3 sync_tasks.py sync           # full bidirectional  (pull status, then push content)
  python3 sync_tasks.py status         # show sync status without changing anything
  python3 sync_tasks.py sprint 1       # assign phases to Sprint 1
  python3 sync_tasks.py sprint all     # assign all sprints at once
  python3 sync_tasks.py --dry-run ...  # preview any command without writing

Loads NOTION_TOKEN and NOTION_DB_ID from .env at repo root (or environment).

Status mapping:
  Notion "Done"        ↔  tasks.md  "- [x]"
  Notion "In Progress" ↔  tasks.md  "- [-]"
  Notion "Not Started" ↔  tasks.md  "- [ ]"
"""

import json
import os
import re
import subprocess
import sys
import time
from copy import deepcopy

# ── .env loader (no dependencies) ────────────────────────────────────────────
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
            if key not in os.environ:  # env vars take precedence
                os.environ[key] = val


load_dotenv(os.path.join(REPO_ROOT, ".env"))

# ── Config ────────────────────────────────────────────────────────────────────
NOTION_TOKEN = os.environ.get("NOTION_TOKEN", "")
NOTION_DB_ID = os.environ.get("NOTION_DB_ID", "")

TASKS_FILE = os.path.join(REPO_ROOT, "specs/001-contextengine-mvp/tasks.md")

# ── Work-bucket terminology ───────────────────────────────────────────────────
# The Notion column that groups tasks into ordered buckets can be named either
# "Phase" or "Stage". Configure via NOTION_WORK_BUCKET in .env (default "Phase").
# The markdown parser accepts BOTH "## Phase N" and "## Stage N" headers
# regardless of this setting; this only controls the Notion property name and
# the option-label prefix used when pushing.
WORK_BUCKET = (os.environ.get("NOTION_WORK_BUCKET", "Phase").strip() or "Phase").capitalize()
if WORK_BUCKET not in ("Phase", "Stage"):
    WORK_BUCKET = "Phase"

# Bucket number → descriptive suffix (prefix is added from WORK_BUCKET).
BUCKET_SUFFIX = {
    1: "Setup",
    2: "Foundation",
    3: "Ingest (US1)",
    4: "Ask & Answer (US2)",
    5: "Team Workspace (US3)",
    6: "Credit Metering (US4)",
    7: "Debug Panel (US5)",
    8: "Admin Dashboard (US6)",
    9: "Local Agent (US7)",
    10: "Notifications (US8)",
    11: "Polish",
}


def bucket_label(num: int) -> str:
    """Return the full Notion label for a bucket number, e.g. 'Phase 1 – Setup'."""
    suffix = BUCKET_SUFFIX.get(num)
    base = f"{WORK_BUCKET} {num}"
    return f"{base} – {suffix}" if suffix else base


# Maps every "Phase N"/"Stage N" header key to the configured Notion label.
PHASE_MAP = {
    f"{word} {n}": bucket_label(n)
    for n in BUCKET_SUFFIX
    for word in ("Phase", "Stage")
}

STORY_MAP = {
    "US0": "US0 – Cross-cutting",
    "US1": "US1 – Ingest Knowledge",
    "US2": "US2 – Ask & Answer",
    "US3": "US3 – Team Workspace",
    "US4": "US4 – Credit Metering",
    "US5": "US5 – Debug Panel",
    "US6": "US6 – Admin Dashboard",
    "US7": "US7 – Local Agent",
    "US8": "US8 – Notifications",
}

# Status mapping: Notion select name ↔ tasks.md checkbox marker
NOTION_TO_CHECKBOX = {
    "Done": "x",
    "In Progress": "-",
    "Not Started": " ",
}
CHECKBOX_TO_NOTION = {v: k for k, v in NOTION_TO_CHECKBOX.items()}

RATE_LIMIT_DELAY = 0.35  # ~3 req/s (Notion limit)

# Sprint → bucket mapping: which buckets belong to each sprint
SPRINT_PHASE_MAP: dict[str, list[str]] = {
    "Sprint 1": [bucket_label(1), bucket_label(2)],
    "Sprint 2": [bucket_label(3), bucket_label(4)],
    "Sprint 3": [bucket_label(5), bucket_label(6)],
    "Sprint 4": [bucket_label(7), bucket_label(8)],
    "Sprint 5": [bucket_label(9), bucket_label(10), bucket_label(11)],
}
# ──────────────────────────────────────────────────────────────────────────────


# ── Parse tasks.md ────────────────────────────────────────────────────────────

def parse_tasks(filepath: str) -> list[dict]:
    """Parse tasks.md into a list of task dicts with line numbers."""
    with open(filepath) as f:
        lines = f.readlines()

    tasks = []
    current_phase = None

    for line_num, line in enumerate(lines):
        # Accept both "## Phase N" and "## Stage N" headers regardless of the
        # configured WORK_BUCKET; both resolve to the configured Notion label.
        phase_match = re.match(r"^## (?:Stage|Phase) (\d+)", line)
        if phase_match:
            key = f"Phase {phase_match.group(1)}"
            current_phase = PHASE_MAP.get(key, key)
            continue

        task_match = re.match(r"^- \[([ x\-])\] (T\w+)\s+(.*)", line.strip())
        if not task_match:
            continue

        checkbox = task_match.group(1)
        task_id = task_match.group(2)
        rest = task_match.group(3).strip()

        parallel = bool(re.search(r"\[P\]", rest))
        rest = re.sub(r"\[P\]\s*", "", rest)

        story_match = re.search(r"\[(US\d+)\]", rest)
        story = (
            STORY_MAP.get(story_match.group(1), "US0 – Cross-cutting")
            if story_match
            else "US0 – Cross-cutting"
        )
        rest = re.sub(r"\[US\d+\]\s*", "", rest).strip()

        tasks.append(
            {
                "id": task_id,
                "phase": current_phase or bucket_label(1),
                "story": story,
                "parallel": parallel,
                "desc": rest[:2000],
                "checkbox": checkbox,  # ' ', 'x', or '-'
                "line_num": line_num,  # 0-indexed line in file
            }
        )

    return tasks


# ── Notion API helpers (via curl — avoids macOS SSL issues) ───────────────────

def notion_request(
    method: str, endpoint: str, payload: dict | None, token: str
) -> dict:
    """Make a request to the Notion API via curl."""
    cmd = [
        "curl", "-s", "-X", method,
        f"https://api.notion.com/v1/{endpoint}",
        "-H", f"Authorization: Bearer {token}",
        "-H", "Notion-Version: 2022-06-28",
        "-H", "Content-Type: application/json",
    ]
    if payload is not None:
        cmd += ["-d", json.dumps(payload)]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if not result.stdout.strip():
        return {"object": "error", "message": result.stderr[:200]}
    return json.loads(result.stdout)


def fetch_notion_tasks(token: str, db_id: str) -> dict[str, dict]:
    """
    Query all pages in the Notion DB. Returns:
      { "T001": {"page_id": "...", "status": "Done", "phase": "...", ...}, ... }
    Handles pagination.
    """
    tasks: dict[str, dict] = {}
    has_more = True
    start_cursor = None

    while has_more:
        payload: dict = {"page_size": 100}
        if start_cursor:
            payload["start_cursor"] = start_cursor

        resp = notion_request("POST", f"databases/{db_id}/query", payload, token)

        for page in resp.get("results", []):
            props = page.get("properties", {})

            title_arr = props.get("Task ID", {}).get("title", [])
            task_id = title_arr[0]["text"]["content"] if title_arr else ""
            if not task_id:
                continue

            status_sel = props.get("Status", {}).get("select")
            status = status_sel["name"] if status_sel else "Not Started"

            phase_sel = props.get(WORK_BUCKET, {}).get("select")
            phase = phase_sel["name"] if phase_sel else ""

            story_sel = props.get("Story", {}).get("select")
            story = story_sel["name"] if story_sel else ""

            desc_arr = props.get("Description", {}).get("rich_text", [])
            desc = desc_arr[0]["text"]["content"] if desc_arr else ""

            parallel = props.get("Parallel", {}).get("checkbox", False)

            sprint_sel = props.get("Sprint", {}).get("select")
            sprint = sprint_sel["name"] if sprint_sel else ""

            tasks[task_id] = {
                "page_id": page["id"],
                "status": status,
                "phase": phase,
                "story": story,
                "desc": desc,
                "parallel": parallel,
                "sprint": sprint,
            }

        has_more = resp.get("has_more", False)
        start_cursor = resp.get("next_cursor")
        if has_more:
            time.sleep(RATE_LIMIT_DELAY)

    return tasks


# ── Push: tasks.md → Notion ──────────────────────────────────────────────────

def push_to_notion(
    local_tasks: list[dict],
    notion_tasks: dict[str, dict],
    token: str,
    db_id: str,
    dry_run: bool,
    push_status: bool = False,
) -> dict:
    """Push content changes from tasks.md to Notion (upsert).

    By default, preserves Notion Status. Pass push_status=True to also push
    checkbox states (e.g. after agent marks tasks done in tasks.md).
    """
    stats = {"created": 0, "updated": 0, "unchanged": 0, "errors": 0}

    for i, task in enumerate(local_tasks):
        existing = notion_tasks.get(task["id"])

        if existing:
            local_status = CHECKBOX_TO_NOTION.get(task["checkbox"], "Not Started")
            status_changed = push_status and existing["status"] != local_status

            content_changed = (
                existing["phase"] != task["phase"]
                or existing["story"] != task["story"]
                or existing["parallel"] != task["parallel"]
                or existing["desc"] != task["desc"]
            )

            if not content_changed and not status_changed:
                stats["unchanged"] += 1
                continue

            change_parts = []
            if content_changed:
                change_parts.append("content")
            if status_changed:
                change_parts.append(f"status → {local_status}")
            change_label = ", ".join(change_parts)

            if dry_run:
                print(f"  [DRY] ✏️  {task['id']}  would update ({change_label})")
                stats["updated"] += 1
                continue

            props = {
                "Task ID": {"title": [{"text": {"content": task["id"]}}]},
                WORK_BUCKET: {"select": {"name": task["phase"]}},
                "Story": {"select": {"name": task["story"]}},
                "Parallel": {"checkbox": task["parallel"]},
                "Description": {"rich_text": [{"text": {"content": task["desc"]}}]},
            }
            if status_changed:
                props["Status"] = {"select": {"name": local_status}}

            resp = notion_request(
                "PATCH", f"pages/{existing['page_id']}", {"properties": props}, token
            )
            if resp.get("object") == "page":
                stats["updated"] += 1
                print(f"  [{i+1:02d}/{len(local_tasks)}] ✏️  {task['id']}  (updated)")
            else:
                stats["errors"] += 1
                print(f"  [{i+1:02d}/{len(local_tasks)}] ✗  {task['id']}  — {resp.get('message','?')[:120]}")
            time.sleep(RATE_LIMIT_DELAY)

        else:
            # New task → create with status from checkbox
            notion_status = CHECKBOX_TO_NOTION.get(task["checkbox"], "Not Started")
            if dry_run:
                print(f"  [DRY] ✅  {task['id']}  would create (status: {notion_status})")
                stats["created"] += 1
                continue

            props = {
                "Task ID": {"title": [{"text": {"content": task["id"]}}]},
                WORK_BUCKET: {"select": {"name": task["phase"]}},
                "Story": {"select": {"name": task["story"]}},
                "Parallel": {"checkbox": task["parallel"]},
                "Status": {"select": {"name": notion_status}},
                "Description": {"rich_text": [{"text": {"content": task["desc"]}}]},
            }
            resp = notion_request(
                "POST", "pages", {"parent": {"database_id": db_id}, "properties": props}, token
            )
            if resp.get("object") == "page":
                stats["created"] += 1
                print(f"  [{i+1:02d}/{len(local_tasks)}] ✅  {task['id']}  (created)")
            else:
                stats["errors"] += 1
                print(f"  [{i+1:02d}/{len(local_tasks)}] ✗  {task['id']}  — {resp.get('message','?')[:120]}")
            time.sleep(RATE_LIMIT_DELAY)

    return stats


# ── Pull: Notion → tasks.md ──────────────────────────────────────────────────

def pull_from_notion(
    local_tasks: list[dict],
    notion_tasks: dict[str, dict],
    tasks_path: str,
    dry_run: bool,
) -> dict:
    """Pull status changes from Notion back into tasks.md checkboxes."""
    stats = {"updated": 0, "unchanged": 0, "not_in_notion": 0}

    with open(tasks_path) as f:
        lines = f.readlines()

    original_lines = deepcopy(lines)
    changes: list[str] = []

    for task in local_tasks:
        notion_data = notion_tasks.get(task["id"])
        if not notion_data:
            stats["not_in_notion"] += 1
            continue

        notion_status = notion_data["status"]
        expected_checkbox = NOTION_TO_CHECKBOX.get(notion_status, " ")
        current_checkbox = task["checkbox"]

        if current_checkbox == expected_checkbox:
            stats["unchanged"] += 1
            continue

        # Update the line in the file
        line_idx = task["line_num"]
        old_line = lines[line_idx]
        new_line = re.sub(
            r"^(\s*- \[)[ x\-](\])",
            rf"\g<1>{expected_checkbox}\2",
            old_line,
        )
        lines[line_idx] = new_line
        stats["updated"] += 1

        status_label = notion_status
        old_label = CHECKBOX_TO_NOTION.get(current_checkbox, "?")
        changes.append(f"  {task['id']:8s}  {old_label} → {status_label}")

    if changes:
        print(f"\n📥 Status changes from Notion ({len(changes)}):")
        for c in changes:
            print(c)

    if stats["updated"] > 0 and not dry_run:
        with open(tasks_path, "w") as f:
            f.writelines(lines)
        print(f"\n✅ Updated {stats['updated']} checkboxes in tasks.md")
    elif stats["updated"] > 0 and dry_run:
        print(f"\n[DRY RUN] Would update {stats['updated']} checkboxes in tasks.md")
    else:
        print("\n✅ tasks.md already in sync with Notion statuses")

    return stats


# ── Status: show diff ─────────────────────────────────────────────────────────

def show_status(local_tasks: list[dict], notion_tasks: dict[str, dict]) -> None:
    """Show sync status — what's different between tasks.md and Notion."""
    diffs = []
    only_local = []
    only_notion = []

    local_ids = {t["id"] for t in local_tasks}
    notion_ids = set(notion_tasks.keys())

    for task in local_tasks:
        notion_data = notion_tasks.get(task["id"])
        if not notion_data:
            only_local.append(task["id"])
            continue

        local_status = CHECKBOX_TO_NOTION.get(task["checkbox"], "Not Started")
        notion_status = notion_data["status"]
        content_changed = (
            notion_data["phase"] != task["phase"]
            or notion_data["story"] != task["story"]
            or notion_data["parallel"] != task["parallel"]
            or notion_data["desc"] != task["desc"]
        )

        if local_status != notion_status or content_changed:
            diff = {
                "id": task["id"],
                "local_status": local_status,
                "notion_status": notion_status,
            }
            if content_changed:
                diff["content_changed"] = True
            diffs.append(diff)

    for tid in notion_ids - local_ids:
        only_notion.append(tid)

    # Print report
    notion_statuses: dict[str, int] = {}
    for nd in notion_tasks.values():
        s = nd["status"]
        notion_statuses[s] = notion_statuses.get(s, 0) + 1

    print(f"\n{'='*55}")
    print(f"  📊 Sync Status Report")
    print(f"{'='*55}")
    print(f"  Local (tasks.md):  {len(local_tasks)} tasks")
    print(f"  Notion:            {len(notion_tasks)} tasks")
    print(f"\n  Notion status breakdown:")
    for status in ["Not Started", "In Progress", "Done"]:
        count = notion_statuses.get(status, 0)
        bar = "█" * count + "░" * max(0, 20 - count)
        print(f"   {status:<15s}  {bar}  {count}")

    if diffs:
        print(f"\n  ⚡ {len(diffs)} task(s) with differences:")
        for d in diffs[:30]:
            parts = [f"    {d['id']:8s}"]
            if d["local_status"] != d["notion_status"]:
                parts.append(f"status: {d['local_status']} (local) ↔ {d['notion_status']} (notion)")
            if d.get("content_changed"):
                parts.append("+ content differs")
            print("  ".join(parts))
        if len(diffs) > 30:
            print(f"    ... and {len(diffs) - 30} more")
    else:
        print(f"\n  ✅ All tasks in sync!")

    if only_local:
        print(f"\n  📝 Only in tasks.md ({len(only_local)}): {', '.join(only_local[:10])}")
    if only_notion:
        print(f"\n  ☁️  Only in Notion ({len(only_notion)}): {', '.join(only_notion[:10])}")

    print(f"{'='*55}")


# ── Sprint: assign phases → sprints ───────────────────────────────────────────

def assign_sprint(
    sprint_name: str,
    notion_tasks: dict[str, dict],
    token: str,
    dry_run: bool,
) -> dict:
    """Assign all tasks in mapped phases to the given sprint in Notion."""
    phases = SPRINT_PHASE_MAP.get(sprint_name)
    if not phases:
        print(f"ERROR: Unknown sprint '{sprint_name}'. Known: {', '.join(SPRINT_PHASE_MAP.keys())}")
        sys.exit(1)

    to_update = {
        tid: t for tid, t in notion_tasks.items()
        if t["phase"] in phases and t["sprint"] != sprint_name
    }
    already = {
        tid: t for tid, t in notion_tasks.items()
        if t["phase"] in phases and t["sprint"] == sprint_name
    }

    print(f"\n  🏃 {sprint_name}")
    print(f"     Phases: {', '.join(phases)}")
    print(f"     Already assigned: {len(already)}")
    print(f"     To assign: {len(to_update)}")

    if not to_update:
        print(f"     ✅ All tasks already in {sprint_name}")
        return {"updated": 0, "already": len(already), "errors": 0}

    stats = {"updated": 0, "already": len(already), "errors": 0}
    for tid in sorted(to_update.keys()):
        t = to_update[tid]
        if dry_run:
            print(f"     [DRY] {tid:8s}  {t['phase']}  → {sprint_name}")
            stats["updated"] += 1
            continue

        resp = notion_request(
            "PATCH",
            f"pages/{t['page_id']}",
            {"properties": {"Sprint": {"select": {"name": sprint_name}}}},
            token,
        )
        if resp.get("object") == "page":
            stats["updated"] += 1
            print(f"     ✅ {tid:8s}  {t['phase']}")
        else:
            stats["errors"] += 1
            print(f"     ✗  {tid:8s}  — {resp.get('message', '?')[:80]}")
        time.sleep(RATE_LIMIT_DELAY)

    return stats


# ── Main ──────────────────────────────────────────────────────────────────────

USAGE = f"""\
Usage: python3 sync_tasks.py <command> [options]

Commands:
  push              tasks.md → Notion (create/update, preserves Notion status)
  pull              Notion → tasks.md (update checkboxes from Notion status)
  sync              bidirectional      (pull status, then push content + status)
  status            show differences   (read-only, no changes)
  sprint <N|all>    assign buckets to Sprint N (1-5) or all sprints at once

Options:
  --push-status   also push checkbox states to Notion (auto-enabled for sync)
  --dry-run       preview changes without writing anything

Work-bucket column: {WORK_BUCKET}  (set NOTION_WORK_BUCKET=Phase|Stage in .env)
Markdown headers "## Phase N" and "## Stage N" are both accepted on parse.

Sprint → {WORK_BUCKET} mapping:
  Sprint 1: {WORK_BUCKET} 1 (Setup) + {WORK_BUCKET} 2 (Foundation)
  Sprint 2: {WORK_BUCKET} 3 (Ingest US1) + {WORK_BUCKET} 4 (Ask & Answer US2)
  Sprint 3: {WORK_BUCKET} 5 (Team Workspace US3) + {WORK_BUCKET} 6 (Credit Metering US4)
  Sprint 4: {WORK_BUCKET} 7 (Debug Panel US5) + {WORK_BUCKET} 8 (Admin Dashboard US6)
  Sprint 5: {WORK_BUCKET} 9 (Local Agent US7) + {WORK_BUCKET} 10 (Notifications US8) + {WORK_BUCKET} 11 (Polish)

Typical agent workflow:
  1. Agent implements code & marks task done in tasks.md
  2. Run: python3 sync_tasks.py push --push-status
  Or simply: python3 sync_tasks.py sync
"""


def main() -> None:
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    dry_run = "--dry-run" in sys.argv
    push_status = "--push-status" in sys.argv

    if not args or args[0] not in ("push", "pull", "sync", "status", "sprint"):
        print(USAGE)
        sys.exit(1)

    command = args[0]

    if not NOTION_TOKEN:
        print("ERROR: NOTION_TOKEN not set. Add to .env or export it.")
        sys.exit(1)
    if not NOTION_DB_ID:
        print("ERROR: NOTION_DB_ID not set. Add to .env or export it.")
        sys.exit(1)

    tasks_path = os.path.abspath(TASKS_FILE)
    if not os.path.exists(tasks_path):
        print(f"ERROR: tasks.md not found at {tasks_path}")
        sys.exit(1)

    # Parse local
    local_tasks = parse_tasks(tasks_path)
    print(f"📄 Parsed {len(local_tasks)} tasks from tasks.md")

    # Fetch Notion
    print("🔍 Fetching tasks from Notion...")
    notion_tasks = fetch_notion_tasks(NOTION_TOKEN, NOTION_DB_ID)
    print(f"   Found {len(notion_tasks)} tasks in Notion")

    if command == "status":
        show_status(local_tasks, notion_tasks)

    elif command == "pull":
        print(f"\n📥 PULL: Notion → tasks.md {'[DRY RUN]' if dry_run else ''}")
        stats = pull_from_notion(local_tasks, notion_tasks, tasks_path, dry_run)
        print(f"\n  Updated: {stats['updated']}  |  Unchanged: {stats['unchanged']}  |  Not in Notion: {stats['not_in_notion']}")

    elif command == "push":
        mode_label = "+ status " if push_status else ""
        print(f"\n📤 PUSH: tasks.md → Notion {mode_label}{'[DRY RUN]' if dry_run else ''}")
        stats = push_to_notion(local_tasks, notion_tasks, NOTION_TOKEN, NOTION_DB_ID, dry_run, push_status=push_status)
        print(f"\n  Created: {stats['created']}  |  Updated: {stats['updated']}  |  Unchanged: {stats['unchanged']}  |  Errors: {stats['errors']}")
        if stats["errors"]:
            sys.exit(1)

    elif command == "sync":
        print(f"\n🔄 SYNC: bidirectional {'[DRY RUN]' if dry_run else ''}")

        # Step 1: Pull status from Notion → tasks.md
        print("\n── Step 1/2: Pull (Notion → tasks.md) ──")
        pull_stats = pull_from_notion(local_tasks, notion_tasks, tasks_path, dry_run)

        # Re-parse if file changed (so push has correct state)
        if pull_stats["updated"] > 0 and not dry_run:
            local_tasks = parse_tasks(tasks_path)

        # Step 2: Push content + status from tasks.md → Notion
        print("\n── Step 2/2: Push (tasks.md → Notion, including status) ──")
        push_stats = push_to_notion(
            local_tasks, notion_tasks, NOTION_TOKEN, NOTION_DB_ID, dry_run, push_status=True
        )

        print(f"\n{'='*55}")
        print("  🔄 Sync complete:")
        print(f"  Pull: {pull_stats['updated']} status updates → tasks.md")
        print(f"  Push: {push_stats['created']} created, {push_stats['updated']} updated → Notion")
        print(f"{'='*55}")

    elif command == "sprint":
        sprint_arg = args[1] if len(args) > 1 else None
        if not sprint_arg:
            print("ERROR: Specify sprint number (1-5) or 'all'.")
            print(f"  Known sprints: {', '.join(SPRINT_PHASE_MAP.keys())}")
            sys.exit(1)

        if sprint_arg == "all":
            sprints_to_assign = list(SPRINT_PHASE_MAP.keys())
        else:
            sprint_name = f"Sprint {sprint_arg}"
            if sprint_name not in SPRINT_PHASE_MAP:
                print(f"ERROR: Unknown sprint '{sprint_name}'. Known: {', '.join(SPRINT_PHASE_MAP.keys())}")
                sys.exit(1)
            sprints_to_assign = [sprint_name]

        print(f"\n🏃 Sprint Assignment {'[DRY RUN]' if dry_run else ''}")
        total_updated = 0
        total_errors = 0
        for sname in sprints_to_assign:
            stats = assign_sprint(sname, notion_tasks, NOTION_TOKEN, dry_run)
            total_updated += stats["updated"]
            total_errors += stats["errors"]

        print(f"\n{'='*55}")
        print("  🏃 Sprint assignment complete:")
        print(f"  Assigned: {total_updated}  |  Errors: {total_errors}")
        print(f"{'='*55}")
        if total_errors:
            sys.exit(1)


if __name__ == "__main__":
    main()
