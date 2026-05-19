import sqlite3
import os
import json
import uuid
from datetime import datetime
from typing import List, Optional, Dict, Any

DB_PATH = os.path.expanduser("~/projects/funs/building/autonomous-agent/brain/state/kanban.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    body TEXT,
    assignee TEXT,
    status TEXT DEFAULT 'todo', -- todo, ready, running, done, blocked
    priority INTEGER DEFAULT 0,
    tenant TEXT,
    workspace_kind TEXT DEFAULT 'scratch',
    workspace_path TEXT,
    created_by TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,
    result TEXT,
    summary TEXT,
    metadata TEXT, -- JSON blob
    skills TEXT -- JSON list
);

CREATE TABLE IF NOT EXISTS dependencies (
    parent_id TEXT,
    child_id TEXT,
    PRIMARY KEY (parent_id, child_id),
    FOREIGN KEY (parent_id) REFERENCES tasks(id),
    FOREIGN KEY (child_id) REFERENCES tasks(id)
);

CREATE TABLE IF NOT EXISTS comments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT,
    author TEXT,
    body TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);

CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    task_id TEXT,
    kind TEXT,
    payload TEXT, -- JSON blob
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (task_id) REFERENCES tasks(id)
);
"""

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    with get_db() as conn:
        conn.executescript(SCHEMA)

def create_task(title: str, body: str = None, assignee: str = None, 
                parents: List[str] = None, tenant: str = None, 
                priority: int = 0, workspace_kind: str = 'scratch', 
                workspace_path: str = None, created_by: str = 'ama',
                skills: List[str] = None) -> str:
    task_id = str(uuid.uuid4())[:8]
    
    # Check if parents are done to determine if task is 'ready' or 'todo'
    status = 'ready'
    if parents:
        with get_db() as conn:
            for p_id in parents:
                row = conn.execute("SELECT status FROM tasks WHERE id = ?", (p_id,)).fetchone()
                if not row or row['status'] != 'done':
                    status = 'todo'
                    break

    with get_db() as conn:
        conn.execute("""
            INSERT INTO tasks (id, title, body, assignee, status, priority, tenant, 
                             workspace_kind, workspace_path, created_by, skills)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (task_id, title, body, assignee, status, priority, tenant, 
                workspace_kind, workspace_path, created_by, json.dumps(skills or [])))
        
        if parents:
            for p_id in parents:
                conn.execute("INSERT INTO dependencies (parent_id, child_id) VALUES (?, ?)", 
                             (p_id, task_id))
    
    log_event(task_id, "created", {"title": title, "assignee": assignee})
    return task_id

def log_event(task_id: str, kind: str, payload: Dict[str, Any]):
    with get_db() as conn:
        conn.execute("INSERT INTO events (task_id, kind, payload) VALUES (?, ?, ?)",
                     (task_id, kind, json.dumps(payload)))

def list_tasks(status: str = None, assignee: str = None) -> List[Dict[str, Any]]:
    query = "SELECT * FROM tasks WHERE 1=1"
    params = []
    if status:
        query += " AND status = ?"
        params.append(status)
    if assignee:
        query += " AND assignee = ?"
        params.append(assignee)
    
    query += " ORDER BY priority DESC, created_at ASC"
    
    with get_db() as conn:
        rows = conn.execute(query, params).fetchall()
        return [dict(row) for row in rows]

def update_task_status(task_id: str, status: str, result: str = None, summary: str = None, metadata: Dict[str, Any] = None):
    now = datetime.now().isoformat()
    with get_db() as conn:
        if status == 'running':
            conn.execute("UPDATE tasks SET status = ?, started_at = ? WHERE id = ?", (status, now, task_id))
        elif status == 'done':
            conn.execute("""
                UPDATE tasks SET status = ?, completed_at = ?, result = ?, summary = ?, metadata = ? 
                WHERE id = ?
            """, (status, now, result, summary, json.dumps(metadata or {}), task_id))
            # Check children that might now be 'ready'
            promote_children(conn, task_id)
        else:
            conn.execute("UPDATE tasks SET status = ? WHERE id = ?", (status, task_id))
            
    log_event(task_id, "status_change", {"status": status})

def promote_children(conn, parent_id: str):
    # Find all children of this parent
    children = conn.execute("SELECT child_id FROM dependencies WHERE parent_id = ?", (parent_id,)).fetchall()
    for row in children:
        child_id = row['child_id']
        # Check if ALL parents of this child are done
        parents = conn.execute("""
            SELECT t.status FROM tasks t 
            JOIN dependencies d ON t.id = d.parent_id 
            WHERE d.child_id = ?
        """, (child_id,)).fetchall()
        
        if all(p['status'] == 'done' for p in parents):
            conn.execute("UPDATE tasks SET status = 'ready' WHERE id = ? AND status = 'todo'", (child_id,))
            log_event(child_id, "promoted", {"reason": f"parent {parent_id} completed"})

if __name__ == "__main__":
    init_db()
    print("Kanban DB initialized.")
