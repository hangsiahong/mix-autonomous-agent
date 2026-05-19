#!/usr/bin/env python3
"""
SQLite session database for AMA harness.
Hermes-pattern: durable metadata, compression lineage, FTS search.

Usage:
  session_db.py create  <session_id> [user_id] [model]
  session_db.py end     <session_id> <reason>           (reset|compression|idle|stop)
  session_db.py update  <session_id> [--tokens IN OUT] [--title T] [--model M]
  session_db.py link    <session_id> <parent_session_id> (compression lineage)
  session_db.py sync    <session_id> <history_json_file>  (mirror JSON → SQLite)
  session_db.py list    [--limit N]
  session_db.py lineage <session_id>
  session_db.py search  <query> [--limit N]
  session_db.py stats
"""
import sqlite3, json, sys, os, time, re, argparse
from pathlib import Path

DB_PATH = os.environ.get("SESSION_DB_PATH",
    os.path.join(os.path.dirname(__file__), "..", "brain", "state", "sessions.db"))
DB_PATH = str(Path(DB_PATH).resolve())

# ── Schema ────────────────────────────────────────────────────────────────────

SCHEMA = """
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS sessions (
    id              TEXT PRIMARY KEY,
    user_id         TEXT,
    model           TEXT,
    parent_session_id TEXT REFERENCES sessions(id),
    started_at      REAL NOT NULL DEFAULT (unixepoch()),
    updated_at      REAL NOT NULL DEFAULT (unixepoch()),
    ended_at        REAL,
    end_reason      TEXT,
    message_count   INTEGER NOT NULL DEFAULT 0,
    tool_call_count INTEGER NOT NULL DEFAULT 0,
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    title           TEXT
);
CREATE INDEX IF NOT EXISTS idx_sessions_updated  ON sessions(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_sessions_parent   ON sessions(parent_session_id);

CREATE TABLE IF NOT EXISTS messages (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    role        TEXT NOT NULL,
    content     TEXT,
    tool_calls  TEXT,
    tool_name   TEXT,
    timestamp   REAL NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, timestamp);

CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
    content,
    tool_name,
    content='messages',
    content_rowid='id'
);

CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
    INSERT INTO messages_fts(rowid, content, tool_name)
    VALUES (new.id, coalesce(new.content,''), coalesce(new.tool_name,''));
END;
CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, tool_name)
    VALUES ('delete', old.id, coalesce(old.content,''), coalesce(old.tool_name,''));
    INSERT INTO messages_fts(rowid, content, tool_name)
    VALUES (new.id, coalesce(new.content,''), coalesce(new.tool_name,''));
END;
CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
    INSERT INTO messages_fts(messages_fts, rowid, content, tool_name)
    VALUES ('delete', old.id, coalesce(old.content,''), coalesce(old.tool_name,''));
END;
"""

# ── Connection ────────────────────────────────────────────────────────────────

def _connect() -> sqlite3.Connection:
    Path(DB_PATH).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn

def _retry_execute(conn, sql, params=()):
    """Execute with jitter-retry on SQLITE_BUSY (WAL contention)."""
    import random
    for attempt in range(15):
        try:
            return conn.execute(sql, params)
        except sqlite3.OperationalError as e:
            if "locked" in str(e) and attempt < 14:
                time.sleep(random.uniform(0.02, 0.15))
            else:
                raise

# ── Session API ───────────────────────────────────────────────────────────────

def create_session(session_id: str, user_id: str = "", model: str = "") -> None:
    with _connect() as conn:
        # Upsert: create if not exists, else update timestamps
        _retry_execute(conn, """
            INSERT INTO sessions(id, user_id, model, started_at, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                updated_at = excluded.updated_at,
                model = CASE WHEN excluded.model != '' THEN excluded.model ELSE model END
        """, (session_id, user_id or "", model or "", time.time(), time.time()))
        conn.commit()

def end_session(session_id: str, reason: str) -> None:
    with _connect() as conn:
        _retry_execute(conn, """
            UPDATE sessions
            SET ended_at = ?, end_reason = ?, updated_at = ?
            WHERE id = ? AND ended_at IS NULL
        """, (time.time(), reason, time.time(), session_id))
        conn.commit()

def update_session(session_id: str, input_tokens: int = 0, output_tokens: int = 0,
                   title: str = "", model: str = "") -> None:
    with _connect() as conn:
        if input_tokens or output_tokens:
            _retry_execute(conn, """
                UPDATE sessions SET
                    input_tokens  = input_tokens  + ?,
                    output_tokens = output_tokens + ?,
                    updated_at    = ?
                WHERE id = ?
            """, (input_tokens, output_tokens, time.time(), session_id))
        if title:
            _retry_execute(conn, "UPDATE sessions SET title=?, updated_at=? WHERE id=?",
                           (title, time.time(), session_id))
        if model:
            _retry_execute(conn, "UPDATE sessions SET model=?, updated_at=? WHERE id=?",
                           (model, time.time(), session_id))
        conn.commit()

def link_parent(session_id: str, parent_id: str) -> None:
    """Set compression lineage: session_id was created by compressing parent_id."""
    with _connect() as conn:
        _retry_execute(conn, "UPDATE sessions SET parent_session_id=? WHERE id=?",
                       (parent_id, session_id))
        conn.commit()

def sync_from_json(session_id: str, history_path: str) -> None:
    """Mirror a JSON history file into the messages table (idempotent)."""
    try:
        history = json.load(open(history_path))
    except Exception as e:
        print(f"sync: cannot read {history_path}: {e}", file=sys.stderr)
        return

    create_session(session_id)  # ensure row exists
    with _connect() as conn:
        # Clear existing and re-insert (replace strategy)
        _retry_execute(conn, "DELETE FROM messages WHERE session_id=?", (session_id,))
        tool_calls = msg_count = 0
        for msg in history:
            role = msg.get("role", "")
            content = msg.get("content")
            if isinstance(content, list):
                content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
            tc = msg.get("tool_calls")
            tc_json = json.dumps(tc, separators=(",", ":")) if tc else None
            tool_name = msg.get("name") or (
                (tc[0].get("function", {}).get("name") if tc and tc[0].get("function") else None)
                if tc else None
            )
            _retry_execute(conn, """
                INSERT INTO messages(session_id, role, content, tool_calls, tool_name, timestamp)
                VALUES (?,?,?,?,?,?)
            """, (session_id, role, content or "", tc_json, tool_name or "", time.time()))
            msg_count += 1
            if tc:
                tool_calls += len(tc)
        _retry_execute(conn, """
            UPDATE sessions SET message_count=?, tool_call_count=?, updated_at=? WHERE id=?
        """, (msg_count, tool_calls, time.time(), session_id))
        conn.commit()
    print(f"sync: {msg_count} messages synced for {session_id}")

def list_sessions(limit: int = 20) -> list:
    with _connect() as conn:
        rows = _retry_execute(conn, """
            SELECT id, title, model, user_id, message_count, input_tokens, output_tokens,
                   started_at, updated_at, ended_at, end_reason, parent_session_id
            FROM sessions ORDER BY updated_at DESC LIMIT ?
        """, (limit,)).fetchall()
    return [dict(r) for r in rows]

def session_lineage(session_id: str) -> list:
    """Walk parent_session_id chain from this session back to root."""
    result = []
    visited = set()
    current = session_id
    with _connect() as conn:
        while current and current not in visited:
            visited.add(current)
            row = _retry_execute(conn, """
                SELECT id, title, model, parent_session_id, started_at, ended_at,
                       end_reason, message_count, input_tokens, output_tokens
                FROM sessions WHERE id=?
            """, (current,)).fetchone()
            if not row:
                break
            result.append(dict(row))
            current = row["parent_session_id"]
    return result

def search_messages(query: str, limit: int = 10) -> list:
    """FTS5 search across all sessions."""
    with _connect() as conn:
        # Sanitize query for FTS5 (escape special chars)
        safe_q = re.sub(r'[^\w\s]', ' ', query).strip()
        if not safe_q:
            return []
        try:
            rows = _retry_execute(conn, """
                SELECT m.session_id, m.role, m.content, m.tool_name, m.timestamp,
                       s.title, s.model,
                       rank
                FROM messages_fts
                JOIN messages m ON messages_fts.rowid = m.id
                JOIN sessions s ON m.session_id = s.id
                WHERE messages_fts MATCH ?
                ORDER BY rank LIMIT ?
            """, (safe_q, limit)).fetchall()
        except sqlite3.OperationalError:
            # FTS query syntax error — fall back to LIKE
            rows = _retry_execute(conn, """
                SELECT m.session_id, m.role, m.content, m.tool_name, m.timestamp,
                       s.title, s.model, 0 as rank
                FROM messages m JOIN sessions s ON m.session_id = s.id
                WHERE m.content LIKE ? OR m.tool_name LIKE ?
                ORDER BY m.timestamp DESC LIMIT ?
            """, (f"%{query}%", f"%{query}%", limit)).fetchall()
    return [dict(r) for r in rows]

def db_stats() -> dict:
    with _connect() as conn:
        n_sessions  = _retry_execute(conn, "SELECT COUNT(*) FROM sessions").fetchone()[0]
        n_messages  = _retry_execute(conn, "SELECT COUNT(*) FROM messages").fetchone()[0]
        n_active    = _retry_execute(conn, "SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL").fetchone()[0]
        total_in    = _retry_execute(conn, "SELECT SUM(input_tokens) FROM sessions").fetchone()[0] or 0
        total_out   = _retry_execute(conn, "SELECT SUM(output_tokens) FROM sessions").fetchone()[0] or 0
    return dict(sessions=n_sessions, messages=n_messages, active=n_active,
                total_input_tokens=total_in, total_output_tokens=total_out)

# ── CLI ───────────────────────────────────────────────────────────────────────

def _fmt_ts(ts):
    if not ts:
        return "-"
    import datetime
    return datetime.datetime.fromtimestamp(float(ts)).strftime("%m-%d %H:%M")

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "create":
        sid = sys.argv[2]
        uid = sys.argv[3] if len(sys.argv) > 3 else ""
        mod = sys.argv[4] if len(sys.argv) > 4 else ""
        create_session(sid, uid, mod)
        print(f"session created: {sid}")

    elif cmd == "end":
        sid, reason = sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "unknown"
        end_session(sid, reason)
        print(f"session ended: {sid} ({reason})")

    elif cmd == "update":
        sid = sys.argv[2]
        ap = argparse.ArgumentParser()
        ap.add_argument("--tokens", nargs=2, type=int, default=None)
        ap.add_argument("--title", default="")
        ap.add_argument("--model", default="")
        args, _ = ap.parse_known_args(sys.argv[3:])
        inp, out = args.tokens if args.tokens else (0, 0)
        update_session(sid, inp, out, args.title, args.model)
        print(f"session updated: {sid}")

    elif cmd == "link":
        sid, parent = sys.argv[2], sys.argv[3]
        link_parent(sid, parent)
        print(f"lineage: {sid} ← {parent}")

    elif cmd == "sync":
        sid, hist_file = sys.argv[2], sys.argv[3]
        sync_from_json(sid, hist_file)

    elif cmd == "list":
        ap = argparse.ArgumentParser()
        ap.add_argument("--limit", type=int, default=20)
        args, _ = ap.parse_known_args(sys.argv[2:])
        rows = list_sessions(args.limit)
        if not rows:
            print("No sessions found.")
            return
        print(f"{'ID':<30} {'TITLE':<25} {'MODEL':<20} {'MSGS':>4} {'TOKENS':>8} {'UPDATED':<14} {'STATUS'}")
        print("-" * 110)
        for r in rows:
            status = r.get("end_reason") or ("active" if not r.get("ended_at") else "ended")
            tokens = (r.get("input_tokens") or 0) + (r.get("output_tokens") or 0)
            title = (r.get("title") or "-")[:24]
            model = (r.get("model") or "-")[:19]
            print(f"{r['id']:<30} {title:<25} {model:<20} {r.get('message_count',0):>4} "
                  f"{tokens:>8,} {_fmt_ts(r.get('updated_at')):<14} {status}")

    elif cmd == "lineage":
        sid = sys.argv[2]
        chain = session_lineage(sid)
        if not chain:
            print(f"Session {sid} not found.")
            return
        print(f"Lineage chain for {sid} ({len(chain)} session(s)):")
        for i, r in enumerate(chain):
            prefix = "└─" if i == len(chain) - 1 else "├─"
            tokens = (r.get("input_tokens") or 0) + (r.get("output_tokens") or 0)
            print(f"  {prefix} {r['id']} | {r.get('title') or '(untitled)'} | "
                  f"{r.get('message_count',0)} msgs | {tokens:,} tokens | "
                  f"ended: {r.get('end_reason') or 'active'}")

    elif cmd == "search":
        if len(sys.argv) < 3:
            print("Usage: session_db.py search <query> [--limit N]")
            sys.exit(1)
        ap = argparse.ArgumentParser()
        ap.add_argument("--limit", type=int, default=10)
        args, rest = ap.parse_known_args(sys.argv[3:])
        # query is everything after "search" except --limit args
        query = " ".join(w for w in sys.argv[2:] if not w.startswith("--") and w not in str(args.limit))
        query = sys.argv[2]  # first positional is query
        results = search_messages(query, args.limit)
        if not results:
            print("No matches found.")
            return
        for r in results:
            ts = _fmt_ts(r.get("timestamp"))
            session = r.get("session_id", "?")
            role = r.get("role", "?")
            title = r.get("title") or session
            content = (r.get("content") or "")[:200].replace("\n", " ")
            print(f"[{ts}] {title} ({role}): {content}")

    elif cmd == "stats":
        s = db_stats()
        print(f"Sessions: {s['sessions']} total, {s['active']} active")
        print(f"Messages: {s['messages']:,}")
        print(f"Tokens:   {s['total_input_tokens']:,} in + {s['total_output_tokens']:,} out "
              f"= {s['total_input_tokens']+s['total_output_tokens']:,} total")

    else:
        print(f"Unknown command: {cmd}")
        print(__doc__)
        sys.exit(1)

if __name__ == "__main__":
    main()
