#!/usr/bin/env python3
"""
task_manager — persistent, cross-session structured task list (cc-oss style).

Differs from the existing `todo` tool in three ways:
  1. **SQLite-backed** at brain/state/tasks.db — survives /new and bot restarts.
  2. **Status workflow**: pending → in_progress → completed (or failed/deleted),
     not just done/undone. Lets the agent show "Refactoring X" via `active_form`.
  3. **Cross-session listing**: `list_tasks()` with no session filter returns
     everything still open across the whole bot, so a user can `/tasks` after
     starting a fresh session and pick up where they left off.

Schema is deliberately small. Dependency tracking (blocks/blockedBy from cc-oss)
is left out until there's evidence the model uses it.
"""
import json
import os
import sqlite3
import sys
import time

DB_PATH = "brain/state/tasks.db"

VALID_STATUSES = {"pending", "in_progress", "completed", "failed", "deleted"}
TERMINAL_STATUSES = {"completed", "failed", "deleted"}

_SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT,
    subject         TEXT NOT NULL,
    description     TEXT,
    active_form     TEXT,
    status          TEXT NOT NULL DEFAULT 'pending',
    owner           TEXT,
    metadata_json   TEXT DEFAULT '{}',
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_session_status ON tasks(session_id, status);
CREATE INDEX IF NOT EXISTS idx_status_updated ON tasks(status, updated_at DESC);
"""


def _connect() -> sqlite3.Connection:
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    return conn


def _row_to_dict(row: sqlite3.Row) -> dict:
    d = dict(row)
    if d.get("metadata_json"):
        try:
            d["metadata"] = json.loads(d["metadata_json"])
        except Exception:
            d["metadata"] = {}
    d.pop("metadata_json", None)
    return d


# ── CRUD ──────────────────────────────────────────────────────────────────────


def create_task(
    session_id: str,
    subject: str,
    description: str = None,
    active_form: str = None,
    metadata: dict = None,
) -> dict:
    if not subject or not subject.strip():
        raise ValueError("subject is required")
    now = int(time.time())
    with _connect() as conn:
        cur = conn.execute(
            "INSERT INTO tasks (session_id, subject, description, active_form, "
            "status, metadata_json, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, 'pending', ?, ?, ?)",
            (
                session_id,
                subject.strip(),
                (description or "").strip(),
                (active_form or "").strip() or None,
                json.dumps(metadata or {}),
                now,
                now,
            ),
        )
        task_id = cur.lastrowid
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    return _row_to_dict(row)


def get_task(task_id: int) -> dict | None:
    with _connect() as conn:
        row = conn.execute("SELECT * FROM tasks WHERE id = ?", (int(task_id),)).fetchone()
    return _row_to_dict(row) if row else None


def list_tasks(
    session_id: str = None,
    status: str = None,
    include_deleted: bool = False,
    limit: int = 50,
) -> list:
    where = []
    params: list = []
    if session_id:
        where.append("session_id = ?")
        params.append(session_id)
    if status:
        where.append("status = ?")
        params.append(status)
    elif not include_deleted:
        where.append("status != 'deleted'")
    sql = "SELECT * FROM tasks"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY status = 'completed', updated_at DESC LIMIT ?"
    params.append(int(limit))
    with _connect() as conn:
        rows = conn.execute(sql, params).fetchall()
    return [_row_to_dict(r) for r in rows]


def update_task(task_id: int, **fields) -> dict | None:
    """Update a subset of mutable fields. Unknown fields are silently ignored
    so the wrapper script doesn't have to gate-keep what the model sends."""
    allowed = {"subject", "description", "active_form", "status", "owner", "metadata"}
    sets = []
    params: list = []
    for k, v in fields.items():
        if k not in allowed or v is None:
            continue
        if k == "status":
            if v not in VALID_STATUSES:
                raise ValueError(
                    f"invalid status {v!r}; must be one of {sorted(VALID_STATUSES)}"
                )
            sets.append("status = ?")
            params.append(v)
        elif k == "metadata":
            # Merge into existing metadata rather than replace, mirroring
            # cc-oss's TaskUpdate semantics (set key=null to delete).
            existing = (get_task(task_id) or {}).get("metadata", {})
            for mk, mv in (v or {}).items():
                if mv is None:
                    existing.pop(mk, None)
                else:
                    existing[mk] = mv
            sets.append("metadata_json = ?")
            params.append(json.dumps(existing))
        else:
            sets.append(f"{k} = ?")
            params.append(v)
    if not sets:
        return get_task(task_id)
    sets.append("updated_at = ?")
    params.append(int(time.time()))
    params.append(int(task_id))
    with _connect() as conn:
        conn.execute(
            f"UPDATE tasks SET {', '.join(sets)} WHERE id = ?",
            params,
        )
    return get_task(task_id)


def delete_task(task_id: int) -> dict | None:
    return update_task(task_id, status="deleted")


# ── Rendering helpers ─────────────────────────────────────────────────────────

_STATUS_EMOJI = {
    "pending": "○",
    "in_progress": "◐",
    "completed": "✓",
    "failed": "✗",
    "deleted": "—",
}


def render_short(task: dict) -> str:
    """One-line summary for list views and context injection."""
    em = _STATUS_EMOJI.get(task.get("status", "?"), "·")
    label = task.get("subject", "")[:80]
    return f"{em} #{task['id']} {label}"


def render_full(task: dict) -> str:
    """Multi-line render for `get` and slash command output."""
    lines = [
        f"**#{task['id']}** {task.get('subject','')}",
        f"Status: `{task.get('status','?')}` · Updated: <t:{task.get('updated_at',0)}:R>",
    ]
    if task.get("active_form"):
        lines.append(f"Active form: _{task['active_form']}_")
    if task.get("description"):
        lines.append("")
        lines.append(task["description"])
    if task.get("metadata"):
        lines.append("")
        lines.append(f"Metadata: `{json.dumps(task['metadata'])}`")
    return "\n".join(lines)


def context_block(session_id: str, max_items: int = 5) -> str:
    """Render the per-turn `## Active Tasks` block injected by 24_agent_loop.sh.

    Shows only this session's pending + in_progress tasks. Empty string if
    nothing is open — caller skips the header in that case.
    """
    open_tasks = list_tasks(session_id=session_id, status="in_progress") + list_tasks(
        session_id=session_id, status="pending"
    )
    # Dedupe (status filter is OR'd above; SQL won't dup but be safe)
    seen: set = set()
    rendered = []
    for t in open_tasks:
        if t["id"] in seen:
            continue
        seen.add(t["id"])
        rendered.append(render_short(t))
        if len(rendered) >= max_items:
            break
    return "\n".join(rendered)


# ── CLI ───────────────────────────────────────────────────────────────────────


def _print_json(obj) -> None:
    print(json.dumps(obj, indent=2, default=str))


def _cli():
    if len(sys.argv) < 2:
        sys.exit("usage: task_manager.py <create|list|get|update|delete|context> ...")
    cmd = sys.argv[1]
    if cmd == "create":
        # create <sid> <subject> [description] [active_form] [metadata_json]
        sid = sys.argv[2]
        subject = sys.argv[3]
        desc = sys.argv[4] if len(sys.argv) > 4 else None
        af = sys.argv[5] if len(sys.argv) > 5 else None
        md = json.loads(sys.argv[6]) if len(sys.argv) > 6 else None
        _print_json(create_task(sid, subject, desc, af, md))
    elif cmd == "list":
        # list [sid] [status]
        sid = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] != "_" else None
        status = sys.argv[3] if len(sys.argv) > 3 else None
        _print_json(list_tasks(session_id=sid, status=status))
    elif cmd == "get":
        _print_json(get_task(int(sys.argv[2])))
    elif cmd == "update":
        # update <task_id> <field_json>
        task_id = int(sys.argv[2])
        fields = json.loads(sys.argv[3])
        _print_json(update_task(task_id, **fields))
    elif cmd == "delete":
        _print_json(delete_task(int(sys.argv[2])))
    elif cmd == "context":
        # Print one-line summaries for context injection
        print(context_block(sys.argv[2]))
    else:
        sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    _cli()
