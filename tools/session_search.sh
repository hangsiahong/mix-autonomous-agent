#!/bin/bash
# Tool: session_search
# Search past conversation history (hermes-style): multi-term match, context windows, LLM summary.

query="${TOOL_query}"
session="${TOOL_session:-}"
limit="${TOOL_limit:-3}"

if [[ -z "$query" ]]; then
    echo "Error: 'query' is required."
    exit 1
fi

# Load env for LLM summary call
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

python3 - <<PYEOF
import json, os, sys, re, subprocess, glob, tempfile

query = os.environ.get("TOOL_query", "")
session_filter = os.environ.get("TOOL_session", "")
limit = int(os.environ.get("TOOL_limit", "3"))
limit = max(1, min(limit, 5))
script_dir = "$SCRIPT_DIR"

state_dir = os.path.join(script_dir, "brain", "state")

# ── Find history files ─────────────────────────────────────────────────
if session_filter:
    files = [os.path.join(state_dir, f"history_{session_filter}.json")]
else:
    # Search both active sessions and archived ones (post-/new)
    files = sorted(glob.glob(os.path.join(state_dir, "history_*.json")))
    files += sorted(glob.glob(os.path.join(state_dir, "sessions", "history_*.json")))

if not files:
    print("No session history found.")
    sys.exit(0)

# ── Search & rank ──────────────────────────────────────────────────────
terms = [t.strip().lower() for t in query.lower().split() if t.strip()]

def score_and_extract(path):
    try:
        with open(path) as f:
            history = json.load(f)
    except Exception:
        return None

    full_parts = []
    match_count = 0
    for msg in history:
        role = msg.get("role", "?")
        content = msg.get("content", "")
        if isinstance(content, list):
            content = " ".join(p.get("text", "") for p in content if isinstance(p, dict))
        if not content:
            continue
        lo = content.lower()
        hits = sum(lo.count(t) for t in terms)
        if hits:
            match_count += hits
        full_parts.append(f"[{role.upper()}]: {content}")

    if match_count == 0:
        return None

    full_text = "\n\n".join(full_parts)
    session_id = os.path.basename(path).replace("history_", "").replace(".json", "")
    return {"session_id": session_id, "score": match_count, "text": full_text, "msg_count": len(history)}

scored = []
for f in files:
    r = score_and_extract(f)
    if r:
        scored.append(r)

scored.sort(key=lambda x: x["score"], reverse=True)
top = scored[:limit]

if not top:
    print(f"No matches found for '{query}' in session history.")
    sys.exit(0)

# ── Truncate around match positions (hermes strategy) ─────────────────
MAX_CHARS = 8000

def truncate_around_matches(text, query_terms, max_chars=MAX_CHARS):
    if len(text) <= max_chars:
        return text
    tl = text.lower()
    positions = []
    for t in query_terms:
        for m in re.finditer(re.escape(t), tl):
            positions.append(m.start())
    if not positions:
        return text[:max_chars] + "\n...[truncated]..."
    positions.sort()
    best_start, best_count = 0, 0
    for pos in positions:
        ws = max(0, pos - max_chars // 4)
        we = ws + max_chars
        if we > len(text):
            ws = max(0, len(text) - max_chars)
        count = sum(1 for p in positions if ws <= p < ws + max_chars)
        if count > best_count:
            best_count, best_start = count, ws
    start = best_start
    end = min(len(text), start + max_chars)
    prefix = "...[earlier turns truncated]...\n\n" if start > 0 else ""
    suffix = "\n\n...[later turns truncated]..." if end < len(text) else ""
    return prefix + text[start:end] + suffix

# ── LLM summarization (optional, uses call_api via subprocess) ────────
def summarize_session(session_id, conversation_text, score, msg_count):
    summary_prompt = f"""You are reviewing a past conversation transcript to help recall what happened.
Search topic: {query}
Session: {session_id} ({msg_count} messages, {score} keyword hits)

Summarize the session focusing on the search topic. Include:
1. What was asked or worked on
2. Actions taken and outcomes
3. Key decisions, solutions, or conclusions
4. Specific commands, paths, URLs, or technical details
5. Anything left unresolved

CONVERSATION (may be truncated around relevant sections):
{conversation_text}

Write a concise factual recap in past tense. Preserve specific technical details."""

    env = dict(os.environ)
    prompt_file = None
    try:
        # Write prompt to tempfile — avoids $@ empty-args bug and ARG_MAX limits
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as tf:
            tf.write(summary_prompt)
            prompt_file = tf.name

        result = subprocess.run(
            ["bash", "-c", f"""
cd '{script_dir}'
source core/mix/init.sh 2>/dev/null
HISTORY=$(python3 -c 'import json,sys; prompt=open(sys.argv[1]).read(); print(json.dumps([{{"role":"user","content":prompt}}]))' '{prompt_file}' 2>/dev/null)
export HISTORY
call_api "You are a conversation summarizer. Respond with a focused, factual summary." 2>/dev/null | python3 -c '
import sys,json
try:
    r=json.load(sys.stdin)
    t=r.get("choices",[{{}}])[0].get("message",{{}}).get("content","")
    if not t:
        t=r.get("candidates",[{{}}])[0].get("content",{{}}).get("parts",[{{}}])[0].get("text","")
    print(t.strip(),end="")
except: pass
'
"""],
            capture_output=True, text=True, timeout=90, env=env
        )
        return result.stdout.strip() if result.stdout.strip() else None
    except Exception:
        return None
    finally:
        if prompt_file:
            try:
                os.unlink(prompt_file)
            except OSError:
                pass

# ── Output results ────────────────────────────────────────────────────
print(f"Session search: '{query}' — found {len(top)} matching session(s)\n")
print("=" * 60)

for item in top:
    sid = item["session_id"]
    print(f"\n## Session: {sid}  ({item['score']} match{'es' if item['score'] != 1 else ''}, {item['msg_count']} messages)")
    print("-" * 40)

    trunc = truncate_around_matches(item["text"], terms)

    # Try LLM summary; fall back to raw snippets
    summary = summarize_session(sid, trunc, item["score"], item["msg_count"])
    if summary:
        print(summary)
    else:
        # Fallback: show context snippets
        lines = trunc.split("\n")
        shown = 0
        for line in lines:
            if any(t in line.lower() for t in terms):
                print(line[:200])
                shown += 1
                if shown >= 10:
                    break
    print()

PYEOF
