#!/bin/bash
# task — persistent task list (SQLite-backed, cross-session).
#
# Inputs (TOOL_* env vars set by 13_tool_execution.sh):
#   TOOL_action       — required: create | list | get | update | delete
#   TOOL_subject      — create: required
#   TOOL_description  — create: optional
#   TOOL_active_form  — create: optional, "Refactoring auth" etc.
#   TOOL_task_id      — get / update / delete: required
#   TOOL_status       — update: new status (pending|in_progress|completed|failed|deleted)
#   TOOL_owner        — update: optional reassignment
#   TOOL_metadata     — create / update: JSON object (merged on update; key=null deletes)
#   TOOL_filter_status — list: optional filter
#   TOOL_SESSION_ID   — implicit, set by run_tool
#
# Output: human-readable summary (model reads this) + the tool record JSON.
# All write paths go through tools/task_manager.py.

set -e

if [[ -z "$TOOL_action" ]]; then
    echo "Error: 'action' is required (create | list | get | update | delete)."
    exit 1
fi

if [[ -z "$TOOL_SESSION_ID" ]]; then
    echo "Error: TOOL_SESSION_ID not set."
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# All branches funnel into python — passing args via env to avoid quoting hell
# (subject/description can contain quotes, backticks, newlines).
case "$TOOL_action" in
    create)
        if [[ -z "$TOOL_subject" ]]; then
            echo "Error: 'subject' is required for create."
            exit 1
        fi
        TASK_SID="$TOOL_SESSION_ID" \
        TASK_SUBJECT="$TOOL_subject" \
        TASK_DESC="${TOOL_description:-}" \
        TASK_AF="${TOOL_active_form:-}" \
        TASK_META="${TOOL_metadata:-{}}" \
        python3 -c '
import os, json, sys
sys.path.insert(0, "tools")
from task_manager import create_task, render_short
md = {}
try:
    md = json.loads(os.environ["TASK_META"] or "{}")
except Exception: pass
t = create_task(
    os.environ["TASK_SID"],
    os.environ["TASK_SUBJECT"],
    os.environ.get("TASK_DESC") or None,
    os.environ.get("TASK_AF") or None,
    md,
)
print(f"Created: {render_short(t)}")
print(f"Use action=update with task_id={t["id"]} to change status as you work.")
'
        ;;
    list)
        TASK_SID="$TOOL_SESSION_ID" \
        TASK_STATUS="${TOOL_filter_status:-}" \
        python3 -c '
import os, sys
sys.path.insert(0, "tools")
from task_manager import list_tasks, render_short
status = os.environ["TASK_STATUS"] or None
tasks = list_tasks(session_id=os.environ["TASK_SID"], status=status)
if not tasks:
    print("No tasks for this session.")
else:
    by_status = {}
    for t in tasks:
        by_status.setdefault(t["status"], []).append(t)
    # Show open ones first, then completed
    for status_key in ("in_progress", "pending", "failed", "completed"):
        rows = by_status.get(status_key, [])
        if not rows: continue
        print(f"### {status_key.replace(chr(95),chr(32)).title()} ({len(rows)})")
        for t in rows:
            print(f"  {render_short(t)}")
'
        ;;
    get)
        if [[ -z "$TOOL_task_id" ]]; then
            echo "Error: 'task_id' is required for get."
            exit 1
        fi
        TASK_ID="$TOOL_task_id" python3 -c '
import os, sys
sys.path.insert(0, "tools")
from task_manager import get_task, render_full
t = get_task(int(os.environ["TASK_ID"]))
if not t:
    print(f"Task #{os.environ["TASK_ID"]} not found.")
else:
    print(render_full(t))
'
        ;;
    update)
        if [[ -z "$TOOL_task_id" ]]; then
            echo "Error: 'task_id' is required for update."
            exit 1
        fi
        TASK_ID="$TOOL_task_id" \
        TASK_STATUS="${TOOL_status:-}" \
        TASK_SUBJECT="${TOOL_subject:-}" \
        TASK_DESC="${TOOL_description:-}" \
        TASK_AF="${TOOL_active_form:-}" \
        TASK_OWNER="${TOOL_owner:-}" \
        TASK_META="${TOOL_metadata:-}" \
        python3 -c '
import os, json, sys
sys.path.insert(0, "tools")
from task_manager import update_task, render_short
fields = {}
for env_k, field_k in (("TASK_STATUS","status"),("TASK_SUBJECT","subject"),
                       ("TASK_DESC","description"),("TASK_AF","active_form"),
                       ("TASK_OWNER","owner")):
    v = os.environ.get(env_k,"")
    if v: fields[field_k] = v
md = os.environ.get("TASK_META","")
if md:
    try: fields["metadata"] = json.loads(md)
    except Exception: pass
try:
    t = update_task(int(os.environ["TASK_ID"]), **fields)
except ValueError as e:
    print(f"Error: {e}")
    sys.exit(1)
if not t:
    print(f"Task #{os.environ["TASK_ID"]} not found.")
else:
    print(f"Updated: {render_short(t)}")
'
        ;;
    delete)
        if [[ -z "$TOOL_task_id" ]]; then
            echo "Error: 'task_id' is required for delete."
            exit 1
        fi
        TASK_ID="$TOOL_task_id" python3 -c '
import os, sys
sys.path.insert(0, "tools")
from task_manager import delete_task, render_short
t = delete_task(int(os.environ["TASK_ID"]))
if not t:
    print(f"Task #{os.environ["TASK_ID"]} not found.")
else:
    print(f"Deleted: {render_short(t)}")
'
        ;;
    *)
        echo "Error: unknown action '$TOOL_action'. Must be one of: create, list, get, update, delete."
        exit 1
        ;;
esac
