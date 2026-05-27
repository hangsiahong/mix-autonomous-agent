"""Tool-call argument repair — port of hermes-agent's _repair_tool_call_arguments.

Some OpenAI-compatible models (xiaomi/mimo, GLM, Kimi, llama.cpp backends)
emit malformed JSON in `tool_calls[*].function.arguments`:
- empty string when the model decided on a tool but never streamed args
- truncated JSON ({"path":"foo)
- trailing commas, Python None literal, unescaped control chars
The upstream API (kconsole, openrouter, etc.) then 400s the next turn with
"Bad request from upstream" and the session gets stuck in a retry loop.

This function applies a fixed set of repairs; if all fail it returns "{}"
so the session survives. The tool itself will error with a helpful message
("path is required") on the next turn, which the model can act on.

Called from:
- core/mix/18_streaming_api_call.sh (prevent corruption being saved)
- core/mix/16_api.sh              (heal already-corrupted history)
"""
from __future__ import annotations

import json
import re


def _escape_invalid_chars_in_json_strings(raw: str) -> str:
    out: list[str] = []
    in_string = False
    i = 0
    n = len(raw)
    while i < n:
        ch = raw[i]
        if in_string:
            if ch == "\\" and i + 1 < n:
                out.append(ch); out.append(raw[i + 1]); i += 2; continue
            if ch == '"':
                in_string = False; out.append(ch)
            elif ord(ch) < 0x20:
                out.append(f"\\u{ord(ch):04x}")
            else:
                out.append(ch)
        else:
            if ch == '"':
                in_string = True
            out.append(ch)
        i += 1
    return "".join(out)


def repair_args(raw_args, tool_name: str = "?") -> str:
    """Repair malformed tool_call arguments. Always returns a parseable JSON object string."""
    if not isinstance(raw_args, str):
        try:
            return json.dumps(raw_args, separators=(",", ":"))
        except Exception:
            return "{}"
    s = raw_args.strip()
    if not s or s == "None":
        return "{}"
    try:
        parsed = json.loads(s, strict=False)
        if isinstance(parsed, dict):
            return json.dumps(parsed, separators=(",", ":"))
        return "{}"
    except Exception:
        pass
    fixed = re.sub(r",\s*([}\]])", r"\1", s)
    open_curly = fixed.count("{") - fixed.count("}")
    open_bracket = fixed.count("[") - fixed.count("]")
    if open_curly > 0:
        fixed += "}" * open_curly
    if open_bracket > 0:
        fixed += "]" * open_bracket
    for _ in range(50):
        try:
            json.loads(fixed)
            break
        except json.JSONDecodeError:
            if fixed.endswith("}") and fixed.count("}") > fixed.count("{"):
                fixed = fixed[:-1]
            elif fixed.endswith("]") and fixed.count("]") > fixed.count("["):
                fixed = fixed[:-1]
            else:
                break
    try:
        parsed = json.loads(fixed)
        if isinstance(parsed, dict):
            return json.dumps(parsed, separators=(",", ":"))
    except Exception:
        pass
    try:
        escaped = _escape_invalid_chars_in_json_strings(fixed)
        if escaped != fixed:
            parsed = json.loads(escaped)
            if isinstance(parsed, dict):
                return json.dumps(parsed, separators=(",", ":"))
    except Exception:
        pass
    return "{}"


def repair_history_tool_calls(history) -> int:
    """In-place repair of every tool_call.arguments in an OpenAI-format messages list.

    Returns the number of fields touched. Used as defense-in-depth so a poisoned
    message from a prior turn can't doom every future API call.
    """
    fixed = 0
    for msg in history or []:
        if not isinstance(msg, dict) or msg.get("role") != "assistant":
            continue
        for tc in (msg.get("tool_calls") or []):
            fn = tc.get("function") or {}
            old = fn.get("arguments")
            new = repair_args(old, fn.get("name", "?"))
            if new != old:
                fn["arguments"] = new
                tc["function"] = fn
                fixed += 1
    return fixed


if __name__ == "__main__":
    # Self-test
    cases = [
        ("",                          "{}"),
        ("None",                      "{}"),
        ("{}",                        "{}"),
        ('{"a":1}',                   '{"a":1}'),
        ('{"a":1,}',                  '{"a":1}'),       # trailing comma
        ('{"a":1',                    '{"a":1}'),       # unclosed
        ('null',                      "{}"),            # non-dict
        ('"plain string"',            "{}"),            # non-dict
    ]
    fails = 0
    for raw, want in cases:
        got = repair_args(raw)
        ok = got == want
        if not ok:
            fails += 1
        print(f"  {'OK' if ok else 'FAIL'}: repair_args({raw!r}) = {got!r}  (want {want!r})")
    print(f"\n{len(cases) - fails}/{len(cases)} cases pass")
    raise SystemExit(0 if fails == 0 else 1)
