#!/bin/bash
# Tool: session_search — long-term conversation recall (no LLM).
#
# Three calling shapes (inferred from args, no explicit `mode` parameter):
#
#   1. discovery — pass TOOL_query[, TOOL_session, TOOL_limit, TOOL_window]
#      Returns top N sessions each with snippet, ±window msgs around the
#      match, plus first-3 + last-3 user/assistant bookends.
#
#   2. scroll — pass TOOL_session + TOOL_around_message_id[, TOOL_window]
#      Returns a window of messages centered on the anchor. To page further,
#      re-anchor on the first or last id returned.
#
#   3. browse — no args → recent sessions with 1-line previews.
#
# All three are SQLite/FTS5-backed. No model calls anywhere — replaces the
# previous LLM-summarization path (was 1-5 call_api invocations per search).
# cc-oss / hermes-agent session_search_tool parity.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# Mode dispatch via env vars so we can hand off bytes-with-quotes to python
# without bash-escape hell.
export _SS_QUERY="${TOOL_query:-}"
export _SS_SESSION="${TOOL_session:-${TOOL_session_id:-}}"
export _SS_ANCHOR="${TOOL_around_message_id:-}"
export _SS_LIMIT="${TOOL_limit:-5}"
export _SS_WINDOW="${TOOL_window:-5}"
export _SS_BROWSE_LIMIT="${TOOL_limit:-15}"

python3 - <<'PYEOF'
import os, sys, json, datetime

# Import the helpers from tools/session_db.py — tools/ isn't a package,
# so add it to sys.path and import by module name.
sys.path.insert(0, "tools")
from session_db import (  # type: ignore
    search_messages_with_context, get_message_window,
    get_session_bookends, list_recent_sessions,
)

q = os.environ.get("_SS_QUERY", "").strip()
sid = os.environ.get("_SS_SESSION", "").strip()
anchor = os.environ.get("_SS_ANCHOR", "").strip()


def fmt_ts(ts):
    try:
        return datetime.datetime.fromtimestamp(float(ts)).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return "?"


def fmt_msg(m, max_chars=200):
    role = (m.get("role") or "?").upper()
    content = (m.get("content") or "").strip()
    if not content and m.get("tool_calls"):
        content = f"[tool_call]"
    if len(content) > max_chars:
        content = content[:max_chars] + "…"
    content = content.replace("\n", " ⏎ ")
    tn = m.get("tool_name") or ""
    tag = f" ({tn})" if tn and role == "TOOL" else ""
    return f"  [#{m.get('id','?')}] {role}{tag}: {content}"


# ── Mode 2: SCROLL (session_id + around_message_id) ───────────────────────
if sid and anchor:
    try:
        anchor_id = int(anchor)
    except ValueError:
        print(f"Error: around_message_id must be an integer, got {anchor!r}")
        sys.exit(1)
    try:
        window = max(1, min(int(os.environ.get("_SS_WINDOW", "5")), 30))
    except ValueError:
        window = 5
    msgs = get_message_window(sid, anchor_id, window=window)
    if not msgs:
        print(f"No messages near #{anchor_id} in session {sid}.")
        sys.exit(0)
    first_id = msgs[0]["id"]
    last_id = msgs[-1]["id"]
    print(f"## Window in session `{sid}` — ±{window} around #{anchor_id}")
    print(f"({len(msgs)} msgs, range #{first_id}–#{last_id})\n")
    for m in msgs:
        print(fmt_msg(m, max_chars=300))
    print()
    print(f"_To scroll back: around_message_id={first_id}. Forward: around_message_id={last_id}._")
    sys.exit(0)


# ── Mode 1: DISCOVERY (query) ─────────────────────────────────────────────
if q:
    try:
        limit = max(1, min(int(os.environ.get("_SS_LIMIT", "5")), 10))
    except ValueError:
        limit = 5
    try:
        window = max(0, min(int(os.environ.get("_SS_WINDOW", "5")), 15))
    except ValueError:
        window = 5
    results = search_messages_with_context(q, limit=limit, window=window, session_id=sid)
    if not results:
        print(f"No matches for `{q}`" + (f" in session {sid}" if sid else "") + ".")
        sys.exit(0)

    print(f"# Session search: `{q}` — {len(results)} match(es)\n")
    for i, r in enumerate(results, 1):
        title = r.get("title") or "(untitled)"
        model = r.get("model") or "?"
        ts = fmt_ts(r.get("timestamp"))
        print(f"## {i}. `{r['session_id']}` — {title} · {model} · {ts}")
        if r.get("lineage_root") and r["lineage_root"] != r["session_id"]:
            print(f"_(post-compaction continuation of `{r['lineage_root']}`)_")
        print(f"**Snippet** (msg #{r['message_id']}): {r['snippet']}")
        print(f"**Session size**: {r['msg_count']} msgs")
        # Bookends
        he = r["bookends"]["head"]
        ta = r["bookends"]["tail"]
        if he:
            print("\n**First few:**")
            for m in he:
                print(fmt_msg(m, max_chars=160))
        # Window around match — skip if it overlaps with bookends entirely
        win = r["window"]
        if win:
            print("\n**Around the match:**")
            for m in win:
                print(fmt_msg(m, max_chars=260))
        if ta and not (he and ta[0]["id"] == he[0]["id"]):
            print("\n**Last few:**")
            for m in ta:
                print(fmt_msg(m, max_chars=160))
        print()
        print(f"_To drill deeper: session_search(session_id=\"{r['session_id']}\", around_message_id={r['message_id']})._")
        print()
        print("---")
        print()
    sys.exit(0)


# ── Mode 3: BROWSE (no args) ──────────────────────────────────────────────
try:
    limit = max(1, min(int(os.environ.get("_SS_BROWSE_LIMIT", "15")), 50))
except ValueError:
    limit = 15
rows = list_recent_sessions(limit=limit)
if not rows:
    print("No sessions found.")
    sys.exit(0)
print(f"# Recent sessions ({len(rows)})\n")
for r in rows:
    status = r.get("end_reason") or ("active" if not r.get("ended_at") else "ended")
    print(f"- `{r['id']}` — {r.get('title') or '(untitled)'} · {r.get('model') or '?'} · "
          f"{r.get('message_count', 0)} msgs · {fmt_ts(r.get('updated_at'))} · {status}")
    if r.get("preview"):
        print(f"    > {r['preview']}")
print()
print("_To search: session_search(query=\"...\"). To open one: session_search(session_id=\"...\", around_message_id=<msg_id>)._")
PYEOF
