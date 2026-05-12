#!/usr/bin/env python3
"""
AMA Error Pattern Analyzer.
Reads error_log.jsonl and tool_usage.jsonl, identifies recurring patterns,
and outputs a structured report the agent can act on.

Usage:
  error_analyzer.py report [--hours N]       # Full report (default: 24h)
  error_analyzer.py patterns [--hours N]     # Just recurring patterns (3+ hits)
  error_analyzer.py since <timestamp>        # Errors since ISO timestamp
"""
import json, sys, os, re, time
from pathlib import Path
from collections import defaultdict, Counter
from datetime import datetime, timezone, timedelta

DIR = Path(__file__).resolve().parent.parent
ERROR_LOG  = DIR / "brain/state/error_log.jsonl"
TOOL_LOG   = DIR / "brain/state/tool_usage.jsonl"
HEAL_LOG   = DIR / "brain/state/self_heal_log.jsonl"

def _load_jsonl(path, since_ts=0):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text().splitlines():
        try:
            e = json.loads(line)
            ts_raw = e.get("ts", "")
            # Parse ISO timestamp or unix int
            if isinstance(ts_raw, str) and ts_raw:
                try:
                    ts = datetime.fromisoformat(ts_raw.replace("Z","+00:00")).timestamp()
                except Exception:
                    ts = 0
            else:
                ts = float(ts_raw or 0)
            if ts >= since_ts:
                e["_ts"] = ts
                rows.append(e)
        except Exception:
            pass
    return rows

def _fingerprint(body: str) -> str:
    """Collapse an error body to a short canonical key for grouping."""
    b = body[:600]
    # Extract core message field — no length limit on match, message can be long
    m = re.search(r'"message"\s*:\s*"([^"]+)"', b)
    if m:
        msg = m.group(1)
        # Remove variable parts (ordinal numbers like "4. content block", UUIDs)
        msg = re.sub(r'\b\d+\.\s+content block\b', 'N. content block', msg)
        msg = re.sub(r'\b\d+\b', 'N', msg)
        msg = re.sub(r'[0-9a-f]{8,}', 'HASH', msg)
        return msg[:100]
    # Fallback: extract status if present
    m2 = re.search(r'"status"\s*:\s*"([^"]+)"', b)
    if m2:
        return m2.group(1)[:80]
    # Last resort: first 80 chars stripped of whitespace
    return re.sub(r'\s+', ' ', b)[:80]

def analyze(hours=24):
    since_ts = time.time() - hours * 3600
    errors = _load_jsonl(ERROR_LOG, since_ts)
    tools  = _load_jsonl(TOOL_LOG,  since_ts)

    # Group API errors by pattern
    patterns: dict[str, list] = defaultdict(list)
    for e in errors:
        fp = _fingerprint(e.get("body", ""))
        patterns[fp].append(e)

    # Identify recurring (3+) patterns
    recurring = {fp: rows for fp, rows in patterns.items() if len(rows) >= 3}

    # Tool failure summary (tools that appear suspiciously often — could indicate loops)
    tool_counts = Counter(t.get("tool","?") for t in tools)
    frequent_tools = {k: v for k, v in tool_counts.items() if v >= 5}

    # Last self-heal actions
    heals = _load_jsonl(HEAL_LOG, time.time() - 7 * 86400)

    return {
        "window_hours": hours,
        "total_api_errors": len(errors),
        "unique_patterns": len(patterns),
        "recurring_patterns": [
            {
                "pattern": fp,
                "count": len(rows),
                "reason": rows[0].get("reason", "unknown"),
                "model": rows[0].get("model", "?"),
                "last_seen": rows[-1].get("ts", "?"),
                "example_body": rows[-1].get("body", "")[:200],
            }
            for fp, rows in sorted(recurring.items(), key=lambda x: -len(x[1]))
        ],
        "frequent_tools": frequent_tools,
        "recent_heals": [
            {"ts": h.get("ts"), "action": h.get("action"), "result": h.get("result")}
            for h in heals[-5:]
        ],
        # needs_attention ONLY fires for actual API error patterns, NOT tool frequency.
        # High tool usage (bash: 40 calls) is normal — not an error condition.
        # Tool frequency is informational only.
        "needs_attention": len(recurring) > 0,
    }

def format_report(data: dict) -> str:
    lines = [
        f"=== AMA Error Report (last {data['window_hours']}h) ===",
        f"Total API errors: {data['total_api_errors']}",
        f"Unique error patterns: {data['unique_patterns']}",
    ]
    if data["recurring_patterns"]:
        lines.append(f"\n--- Recurring Patterns (3+ hits) ---")
        for p in data["recurring_patterns"]:
            lines.append(
                f"\n[{p['count']}x] {p['reason']} on {p['model']}\n"
                f"  Pattern: {p['pattern']}\n"
                f"  Last seen: {p['last_seen']}\n"
                f"  Example: {p['example_body']}"
            )
    else:
        lines.append("\nNo recurring error patterns found.")

    if data["frequent_tools"]:
        lines.append("\n--- High-Frequency Tools ---")
        for t, c in sorted(data["frequent_tools"].items(), key=lambda x: -x[1]):
            lines.append(f"  {t}: {c} calls in window")

    if data["recent_heals"]:
        lines.append("\n--- Recent Self-Heals ---")
        for h in data["recent_heals"]:
            lines.append(f"  [{h['ts']}] {h['action']}: {h['result']}")

    if data["needs_attention"]:
        lines.append("\n⚠️  ACTION NEEDED: Recurring patterns detected.")
    else:
        lines.append("\n✅ No critical patterns detected.")

    return "\n".join(lines)

def log_heal(action: str, result: str):
    entry = json.dumps({
        "ts": datetime.now(timezone.utc).isoformat(),
        "action": action,
        "result": result
    })
    with open(HEAL_LOG, "a") as f:
        f.write(entry + "\n")

def archive_addressed(before_ts: float = 0) -> dict:
    """
    Move errors older than before_ts to an archive file and clear them from
    the active log. Called after a self-heal session so stale errors stop
    triggering repeat alerts.
    """
    if not ERROR_LOG.exists():
        return {"archived": 0, "kept": 0}

    all_rows = ERROR_LOG.read_text().splitlines()
    archive_path = DIR / "brain/state/error_log_archive.jsonl"

    kept = []
    archived = []
    for line in all_rows:
        try:
            e = json.loads(line)
            ts_raw = e.get("ts", "")
            try:
                ts = datetime.fromisoformat(ts_raw.replace("Z","+00:00")).timestamp()
            except Exception:
                ts = 0
            if before_ts > 0 and ts < before_ts:
                archived.append(line)
            else:
                kept.append(line)
        except Exception:
            kept.append(line)

    if archived:
        with open(archive_path, "a") as f:
            f.write("\n".join(archived) + "\n")
        ERROR_LOG.write_text("\n".join(kept) + ("\n" if kept else ""))

    return {"archived": len(archived), "kept": len(kept)}

def create_heal_request(patterns):
    """Write a heal_request.json for the agent to pick up next session."""
    req = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "patterns": patterns,
        "instruction": (
            "Recurring API errors detected. Use check_health, read_error_log, "
            "and bash to diagnose. Fix issues in tools/ directly. "
            "For changes to core/ files, describe the fix and send to admin."
        )
    }
    path = DIR / "brain/state/heal_request.json"
    path.write_text(json.dumps(req, indent=2))
    return str(path)

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "report"

    if cmd in ("report", "patterns"):
        hours = 24
        if "--hours" in sys.argv:
            i = sys.argv.index("--hours")
            hours = int(sys.argv[i+1]) if i+1 < len(sys.argv) else 24
        data = analyze(hours)
        if cmd == "patterns":
            if data["recurring_patterns"]:
                for p in data["recurring_patterns"]:
                    print(f"{p['count']}x | {p['reason']} | {p['pattern']}")
            else:
                print("No recurring patterns.")
        else:
            print(format_report(data))
            # Exit with code 1 if action needed (for cron use)
            sys.exit(1 if data["needs_attention"] else 0)

    elif cmd == "create_request":
        hours = int(sys.argv[2]) if len(sys.argv) > 2 else 24
        data = analyze(hours)
        if data["recurring_patterns"]:
            path = create_heal_request(data["recurring_patterns"])
            print(f"Heal request created: {path}")
        else:
            print("No patterns to heal.")

    elif cmd == "log":
        action = sys.argv[2] if len(sys.argv) > 2 else "unknown"
        result = sys.argv[3] if len(sys.argv) > 3 else ""
        log_heal(action, result)
        print(f"Logged: {action}")

    elif cmd == "clear":
        # Archive everything older than N hours (default: all) out of active log
        hours = float(sys.argv[2]) if len(sys.argv) > 2 else 0
        before_ts = time.time() - hours * 3600 if hours > 0 else time.time()
        result = archive_addressed(before_ts)
        print(f"Archived {result['archived']} errors, kept {result['kept']} recent entries")

    elif cmd == "archive_before":
        # Archive errors before a given ISO timestamp
        ts_str = sys.argv[2] if len(sys.argv) > 2 else ""
        before_ts = 0
        if ts_str:
            try:
                before_ts = datetime.fromisoformat(ts_str.replace("Z","+00:00")).timestamp()
            except Exception:
                before_ts = float(ts_str)
        result = archive_addressed(before_ts)
        print(f"Archived {result['archived']} errors before {ts_str}")

    elif cmd == "since":
        ts_str = sys.argv[2] if len(sys.argv) > 2 else ""
        since = 0
        if ts_str:
            try:
                since = datetime.fromisoformat(ts_str.replace("Z","+00:00")).timestamp()
            except Exception:
                since = float(ts_str)
        errors = _load_jsonl(ERROR_LOG, since)
        for e in errors:
            print(json.dumps(e))

    else:
        print(__doc__)
        sys.exit(1)
