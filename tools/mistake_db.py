#!/usr/bin/env python3
"""
tools/mistake_db.py — Per-user conversation mistake recall.

When the user corrects the agent ("no, I meant X" / "not that" / "actually Y"),
that pair (user phrasing → wrong interpretation → correction → lesson) is
stored. On future turns, the user's new phrasing is embedded and matched
against stored mistakes; close matches are surfaced as a `## Prior
Correction` block in the per-turn context, so the cheap model doesn't repeat
the same misreading.

Storage: SQLite at brain/state/mistakes.db. Embeddings via
tools/memory_helper.py:get_embedding (Vertex text-embedding-004 — same path
the rest of the system uses).

Public API:
    record_mistake(user_id, session_id, user_phrasing, agent_did,
                   actual_want, lesson) -> int
    recall_similar(user_id, query, top_k=2, min_sim=0.78) -> list[dict]
    stats() -> dict

CLI:
    python3 tools/mistake_db.py recall --user-id <id> --query "..."
    python3 tools/mistake_db.py stats
"""
from __future__ import annotations

import argparse
import json
import math
import os
import pickle
import sqlite3
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
DB_PATH = DIR / "brain" / "state" / "mistakes.db"

sys.path.insert(0, str(DIR / "tools"))


_SCHEMA = """
CREATE TABLE IF NOT EXISTS mistakes (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id         TEXT,
    session_id      TEXT,
    user_phrasing   TEXT NOT NULL,
    agent_did       TEXT,
    actual_want     TEXT,
    lesson          TEXT,
    embedding       BLOB,
    created_at      INTEGER NOT NULL,
    recalled_count  INTEGER DEFAULT 0,
    last_recalled   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_user      ON mistakes(user_id);
CREATE INDEX IF NOT EXISTS idx_created   ON mistakes(created_at DESC);
"""


def _connect() -> sqlite3.Connection:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.executescript(_SCHEMA)
    return conn


def _embed(text: str) -> list[float]:
    """Embed via existing memory_helper. Returns [] on any failure."""
    try:
        import memory_helper  # type: ignore
        v = memory_helper.get_embedding(text[:2000])
        if isinstance(v, list) and v:
            return v
    except Exception:
        pass
    return []


def _cosine(a: list[float], b: list[float]) -> float:
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(x * x for x in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def record_mistake(
    user_id: str,
    session_id: str,
    user_phrasing: str,
    agent_did: str,
    actual_want: str,
    lesson: str,
) -> int:
    if not user_phrasing or not user_phrasing.strip():
        return -1
    vec = _embed(user_phrasing)
    blob = pickle.dumps(vec) if vec else None
    conn = _connect()
    try:
        cur = conn.execute(
            "INSERT INTO mistakes (user_id, session_id, user_phrasing, agent_did, "
            "actual_want, lesson, embedding, created_at) VALUES (?,?,?,?,?,?,?,?)",
            (
                user_id or "",
                session_id or "",
                user_phrasing.strip()[:1000],
                (agent_did or "").strip()[:600],
                (actual_want or "").strip()[:600],
                (lesson or "").strip()[:400],
                blob,
                int(time.time()),
            ),
        )
        conn.commit()
        return cur.lastrowid or -1
    finally:
        conn.close()


def recall_similar(
    user_id: str,
    query: str,
    top_k: int = 2,
    min_sim: float = 0.78,
) -> list[dict]:
    """
    Return up to top_k mistakes whose stored phrasing is semantically close to
    `query`. Only mistakes for this user_id are considered. Empty list if
    embeddings unavailable or nothing matches above min_sim.
    """
    if not query or not query.strip():
        return []
    qvec = _embed(query)
    if not qvec:
        return []

    conn = _connect()
    try:
        rows = conn.execute(
            "SELECT id, user_phrasing, agent_did, actual_want, lesson, embedding, "
            "recalled_count, created_at "
            "FROM mistakes WHERE user_id = ? OR ? = '' ORDER BY created_at DESC LIMIT 200",
            (user_id, user_id),
        ).fetchall()
    finally:
        conn.close()

    scored: list[tuple[float, sqlite3.Row]] = []
    for r in rows:
        blob = r["embedding"]
        if not blob:
            continue
        try:
            v = pickle.loads(blob)
        except Exception:
            continue
        sim = _cosine(qvec, v)
        if sim >= min_sim:
            scored.append((sim, r))

    scored.sort(key=lambda x: -x[0])
    hits = scored[:top_k]
    if not hits:
        return []

    # Bump recall stats
    ids = [r["id"] for _, r in hits]
    if ids:
        conn = _connect()
        try:
            conn.executemany(
                "UPDATE mistakes SET recalled_count = recalled_count + 1, "
                "last_recalled = ? WHERE id = ?",
                [(int(time.time()), i) for i in ids],
            )
            conn.commit()
        finally:
            conn.close()

    return [
        {
            "id": r["id"],
            "similarity": round(s, 3),
            "user_phrasing": r["user_phrasing"],
            "agent_did": r["agent_did"],
            "actual_want": r["actual_want"],
            "lesson": r["lesson"],
            "age_days": (int(time.time()) - int(r["created_at"])) // 86400,
        }
        for s, r in hits
    ]


def stats() -> dict:
    conn = _connect()
    try:
        total = conn.execute("SELECT COUNT(*) AS n FROM mistakes").fetchone()["n"]
        users = conn.execute("SELECT COUNT(DISTINCT user_id) AS n FROM mistakes").fetchone()["n"]
        recent = conn.execute(
            "SELECT user_phrasing, lesson, created_at FROM mistakes "
            "ORDER BY created_at DESC LIMIT 5"
        ).fetchall()
        return {
            "total": total,
            "users": users,
            "recent": [dict(r) for r in recent],
        }
    finally:
        conn.close()


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    rc = sub.add_parser("recall")
    rc.add_argument("--user-id", required=True)
    rc.add_argument("--query", required=True)
    rc.add_argument("--top-k", type=int, default=2)
    rc.add_argument("--min-sim", type=float, default=0.78)

    rec = sub.add_parser("record")
    rec.add_argument("--user-id", default="")
    rec.add_argument("--session-id", default="")
    rec.add_argument("--user-phrasing", required=True)
    rec.add_argument("--agent-did", default="")
    rec.add_argument("--actual-want", default="")
    rec.add_argument("--lesson", default="")

    sub.add_parser("stats")

    args = p.parse_args()
    if args.cmd == "recall":
        hits = recall_similar(args.user_id, args.query, args.top_k, args.min_sim)
        print(json.dumps(hits, indent=2))
    elif args.cmd == "record":
        new_id = record_mistake(
            args.user_id, args.session_id, args.user_phrasing,
            args.agent_did, args.actual_want, args.lesson,
        )
        print(json.dumps({"id": new_id}))
    elif args.cmd == "stats":
        print(json.dumps(stats(), indent=2, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
