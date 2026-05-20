#!/usr/bin/env python3
"""
file_mutation_check — post-tool-batch verifier.

Given a JSON array of tool_calls that just executed, extract the file paths
each write-tool targeted, stat them, and emit a compact markdown footer
showing what actually exists on disk now. cc-oss / hermes-agent v0.14.0
"per-turn file mutation verifier footer" pattern.

The model reads this footer next to its tool results so it can catch:
  - silent write failures (path doesn't exist after a `write_file`)
  - wrong path (write claims success but file is elsewhere)
  - empty writes (size 0 when content was supposed to be written)
  - clobbered files (mtime older than the tool call would suggest)

Stdin: JSON array of tool_call objects (OpenAI-format).
Stdout: markdown footer if any write tools were in the batch, else nothing.

Run via:  tools/file_mutation_check.py < <(printf '%s' "$tool_calls")
"""
import json
import os
import sys
import time

# Write-tools and the field(s) that name their target file. Order in the value
# tuple matters: first match wins (e.g. write_file uses "path" not "file_path").
_WRITE_TOOLS = {
    "write_file":    ("path", "file_path"),
    "edit_code":     ("path", "file_path"),
    "patch":         ("path", "file_path", "target"),
    "ast_edit":      ("path", "file_path"),
}

# custom_tool_manager(action=create) writes to a known prefix; handle as a special case.


def _extract_path(name: str, args: dict) -> str:
    if name in _WRITE_TOOLS:
        for k in _WRITE_TOOLS[name]:
            v = args.get(k)
            if isinstance(v, str) and v.strip():
                return v.strip()
    elif name == "custom_tool_manager" and args.get("action") == "create":
        tool_name = args.get("name") or args.get("tool_name") or ""
        if tool_name:
            return f"tools/custom/{tool_name}.sh"
    elif name == "skill_manager" and args.get("action") == "create":
        sk = args.get("name") or args.get("skill") or ""
        if sk:
            return f"brain/skills/{sk}/prompt.md"
    return ""


def _human_size(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f}K"
    return f"{n / 1024 / 1024:.1f}M"


def _humanize_seconds_ago(secs: float) -> str:
    s = max(0, int(secs))
    if s < 1:
        return "just now"
    if s < 60:
        return f"{s}s ago"
    if s < 3600:
        return f"{s // 60}m ago"
    if s < 86400:
        return f"{s // 3600}h ago"
    return f"{s // 86400}d ago"


def check(tool_calls: list) -> str:
    """Return a markdown footer string, or empty string if no write tools in batch."""
    if not isinstance(tool_calls, list):
        return ""

    touched: list = []   # [(tool_name, path)]
    for tc in tool_calls:
        fn = tc.get("function") or {}
        name = (fn.get("name") or tc.get("name") or "").strip()
        raw = fn.get("arguments") or "{}"
        try:
            args = json.loads(raw) if isinstance(raw, str) else (raw or {})
        except Exception:
            args = {}
        if not isinstance(args, dict):
            continue
        p = _extract_path(name, args)
        if p:
            touched.append((name, p))

    if not touched:
        return ""

    now = time.time()
    lines = []
    for tool_name, p in touched:
        full = p if os.path.isabs(p) else os.path.normpath(p)
        try:
            st = os.stat(full)
            size = st.st_size
            mtime = st.st_mtime
            age = now - mtime
            tag = "✓"
            note = f"{_human_size(size)}"
            if size == 0:
                tag = "⚠"
                note += " (empty!)"
            if age > 60:
                # Stale mtime is a real signal: the write tool just ran. If the
                # file's mtime is more than a minute old, the write probably
                # didn't land at this path.
                tag = "⚠"
                note += f" (mtime {_humanize_seconds_ago(age)} — write may not have landed?)"
            lines.append(f"  {tag} `{p}` — {note}  _[{tool_name}]_")
        except FileNotFoundError:
            lines.append(f"  ✗ `{p}` — **MISSING** (write may have failed) _[{tool_name}]_")
        except Exception as e:
            lines.append(f"  ? `{p}` — stat error: {type(e).__name__} _[{tool_name}]_")

    # Dedupe consecutive duplicates (same path edited twice in the batch)
    seen: set = set()
    unique = []
    for ln in lines:
        if ln in seen:
            continue
        seen.add(ln)
        unique.append(ln)

    return "\n--- File ops in this batch (post-write verify) ---\n" + "\n".join(unique)


def _cli():
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # malformed input → silent no-op
    out = check(data if isinstance(data, list) else [])
    if out:
        sys.stdout.write(out)


if __name__ == "__main__":
    _cli()
