"""Text-form tool-call extractor — fallback for weak tool-calling models.

Some OpenAI-compatible models (xiaomi/mimo, Qwen, Gemma, GLM) consistently
botch the structured `tool_calls.arguments` JSON field but emit a clean
Claude-style XML block inside `content` instead. This parser extracts those
blocks and converts them into OpenAI-format tool_calls so the agent loop
can execute them normally.

Formats handled (case-insensitive, multiline):

1. Claude/mimo XML — most common:
       <tool_call>
       <function=NAME>
       <parameter name="K1">V1</parameter>
       <parameter name="K2">V2</parameter>
       </function>
       </tool_call>

2. JSON-inside-tag (some Qwen/GLM configs):
       <tool_call>
       {"name": "NAME", "arguments": {"K1": "V1"}}
       </tool_call>

3. Gemma-style standalone <function>:
       <function name="NAME"><parameter name="K1">V1</parameter></function>

Returns a list of {id, type, function:{name, arguments}} dicts ready to
splice into the streaming response.
"""
from __future__ import annotations

import json
import re
import time
import uuid

_BLOCK_RE = re.compile(r"<tool_call\b[^>]*>(.*?)</tool_call>", re.DOTALL | re.IGNORECASE)
_FN_OPEN_RE = re.compile(r"<function(?:\s*=\s*|\s+name\s*=\s*\"?)([A-Za-z_][A-Za-z0-9_\-]*)\"?\s*>", re.IGNORECASE)
_PARAM_RE = re.compile(
    r"<parameter\s+name\s*=\s*\"([^\"]+)\"\s*>(.*?)</parameter>",
    re.DOTALL | re.IGNORECASE,
)
_BARE_FN_RE = re.compile(
    r"<function\s+name\s*=\s*\"([^\"]+)\"\s*>(.*?)</function>",
    re.DOTALL | re.IGNORECASE,
)


def _parse_one_block(inner: str):
    """Extract (name, args_dict) from the inside of one <tool_call>...</tool_call>."""
    s = inner.strip()
    if not s:
        return None

    # Try JSON form first — {"name":"X","arguments":{...}} or [{...}, ...]
    if s.startswith("{") or s.startswith("["):
        try:
            obj = json.loads(s)
            if isinstance(obj, list) and obj:
                obj = obj[0]
            if isinstance(obj, dict):
                name = obj.get("name") or obj.get("function") or ""
                args = obj.get("arguments")
                if isinstance(args, dict):
                    return (name, args) if name else None
                if isinstance(args, str):
                    try:
                        parsed = json.loads(args)
                        if isinstance(parsed, dict):
                            return (name, parsed) if name else None
                    except Exception:
                        pass
                return (name, {}) if name else None
        except Exception:
            pass

    # Claude-style: <function=NAME>...<parameter name="K">V</parameter>...</function>
    fn_match = _FN_OPEN_RE.search(s)
    if fn_match:
        name = fn_match.group(1)
        args = {}
        for pm in _PARAM_RE.finditer(s):
            key = pm.group(1)
            val = pm.group(2)
            args[key] = _coerce_value(val)
        return (name, args)
    return None


def _coerce_value(raw: str):
    """Best-effort type coercion for parameter values."""
    s = raw.strip()
    if not s:
        return ""
    # Try JSON (handles numbers, booleans, null, objects, arrays, strings)
    try:
        return json.loads(s)
    except Exception:
        pass
    # Plain string — preserve as-is including newlines/whitespace inside the tag
    return raw


def extract(content: str):
    """Extract OpenAI-format tool_calls from text content. Returns a list."""
    if not content or "<" not in content:
        return []
    calls = []
    seen_spans = []
    # 1. <tool_call> blocks
    for m in _BLOCK_RE.finditer(content):
        parsed = _parse_one_block(m.group(1))
        if parsed:
            name, args = parsed
            if name:
                calls.append(_build_call(name, args))
                seen_spans.append((m.start(), m.end()))
    # 2. Standalone <function name="..."> (Gemma-style) — only outside any
    #    <tool_call> block we already consumed.
    for m in _BARE_FN_RE.finditer(content):
        if any(start <= m.start() < end for start, end in seen_spans):
            continue
        name = m.group(1)
        inner = m.group(2)
        args = {}
        for pm in _PARAM_RE.finditer(inner):
            args[pm.group(1)] = _coerce_value(pm.group(2))
        calls.append(_build_call(name, args))
    return calls


def strip(content: str) -> str:
    """Remove text-form tool_call blocks from content (for clean display)."""
    if not content:
        return content
    out = _BLOCK_RE.sub("", content)
    # Strip bare Gemma-style <function name="..."> only at block boundaries
    out = re.sub(
        r"(?:^|\n)[ \t]*<function\s+name\s*=\s*\"[^\"]+\"\s*>.*?</function>",
        "",
        out,
        flags=re.DOTALL | re.IGNORECASE,
    )
    return out.strip()


def _build_call(name: str, args: dict) -> dict:
    return {
        "id": f"call_{int(time.time()*1000)}_{uuid.uuid4().hex[:6]}",
        "type": "function",
        "function": {
            "name": name,
            "arguments": json.dumps(args, separators=(",", ":")),
        },
    }


if __name__ == "__main__":
    samples = [
        # Claude/mimo XML
        '<tool_call>\n<function=write_file>\n<parameter name="path">hello.txt</parameter>\n<parameter name="content">hi</parameter>\n</function>\n</tool_call>',
        # JSON form
        '<tool_call>\n{"name":"bash","arguments":{"command":"ls"}}\n</tool_call>',
        # Multiple in one content
        ('<tool_call>\n<function=read_code>\n<parameter name="path">a.py</parameter>\n</function>\n</tool_call>\n'
         'Some prose here.\n'
         '<tool_call>\n<function=read_code>\n<parameter name="path">b.py</parameter>\n</function>\n</tool_call>'),
        # Empty (mimo's broken case)
        '<tool_call>\n<function=run_command>\n</function>\n</tool_call>',
        # No tool calls
        'Just plain text with no XML.',
    ]
    for s in samples:
        calls = extract(s)
        print(f"INPUT ({len(s)} chars): {s[:80]!r}...")
        for c in calls:
            print(f"  → {c['function']['name']}({c['function']['arguments']})")
        print(f"  STRIPPED: {strip(s)[:80]!r}\n")
