import json
import os
from typing import Dict, Any, List, Optional
from tools.kanban.db import (
    get_db, create_task, update_task_status, list_tasks, log_event
)

def _ok(**fields: Any) -> str:
    return json.dumps({"ok": True, **fields})

def _error(msg: str) -> str:
    return json.dumps({"ok": False, "error": msg})

def handle_kanban_show(task_id: str) -> str:
    """Read a task's full state and dependencies."""
    try:
        with get_db() as conn:
            task = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
            if not task:
                return _error(f"Task {task_id} not found")
            
            task_dict = dict(task)
            
            # Get dependencies
            parents = conn.execute("SELECT parent_id FROM dependencies WHERE child_id = ?", (task_id,)).fetchall()
            children = conn.execute("SELECT child_id FROM dependencies WHERE parent_id = ?", (task_id,)).fetchall()
            
            # Get comments
            comments = conn.execute("SELECT * FROM comments WHERE task_id = ? ORDER BY created_at DESC", (task_id,)).fetchall()
            
            return json.dumps({
                "ok": True,
                "task": task_dict,
                "parents": [p['parent_id'] for p in parents],
                "children": [c['child_id'] for c in children],
                "comments": [dict(c) for c in comments]
            })
    except Exception as e:
        return _error(str(e))

def handle_kanban_create(title: str, assignee: str, body: str = None, parents: List[str] = None, priority: int = 0) -> str:
    """Create a new task."""
    try:
        tid = create_task(
            title=title,
            body=body,
            assignee=assignee,
            parents=parents,
            priority=priority,
            created_by=os.environ.get("HERMES_PROFILE", "ama")
        )
        return _ok(task_id=tid)
    except Exception as e:
        return _error(str(e))

def handle_kanban_complete(task_id: str, summary: str, metadata: Dict[str, Any] = None) -> str:
    """Mark a task as done."""
    try:
        update_task_status(task_id, "done", summary=summary, metadata=metadata)
        return _ok(task_id=task_id, status="done")
    except Exception as e:
        return _error(str(e))

def handle_kanban_block(task_id: str, reason: str) -> str:
    """Block a task with a reason."""
    try:
        update_task_status(task_id, "blocked")
        with get_db() as conn:
            conn.execute("INSERT INTO comments (task_id, author, body) VALUES (?, ?, ?)",
                         (task_id, "system", f"BLOCKED: {reason}"))
        return _ok(task_id=task_id, status="blocked")
    except Exception as e:
        return _error(str(e))
