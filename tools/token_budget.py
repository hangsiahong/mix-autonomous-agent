#!/usr/bin/env python3
"""
Token budget — cc-oss-inspired self-throttle for the agent.

Either party (user or model) can declare a budget by including one of these
patterns anywhere in their message:

    +500k                          (shorthand at start or end)
    spend 50k tokens               (verbose)
    use 1.5m tokens                (verbose, with decimal)

Once set, the budget is sticky per session (cleared by /new or `clear` here).
The harness accumulates `spent` against the budget after every API call. When
the assistant crosses 90%, a one-shot warning is injected into the next turn's
context so it can wrap up gracefully. At 100%, the turn loop exits cleanly.

State lives at brain/state/budget_<session_id>.json as a single dict:
    {"budget": int, "spent": int, "set_at": iso8601, "set_by": "user"|"assistant",
     "warned_90": bool}

Subcommands (called from bash):
    parse <text>                   → prints int or empty
    set <sid> <budget> <by>        → writes state
    add <sid> <delta>              → adds to spent; prints "<spent>|<pct>|<crossed_90>|<exhausted>"
    get <sid>                      → prints JSON dict or empty
    line <sid>                     → prints one-line status for context injection
    clear <sid>                    → removes state file
"""
import json
import os
import re
import sys
import time

# Matching ported from cc-oss/utils/tokenBudget.ts. Anchored shorthand
# avoids false-positives in natural text ("plan A+B+C+5kmore" should NOT match).
_SHORTHAND_START = re.compile(r"^\s*\+(\d+(?:\.\d+)?)\s*(k|m|b)\b", re.IGNORECASE)
_SHORTHAND_END = re.compile(r"\s\+(\d+(?:\.\d+)?)\s*(k|m|b)\s*[.!?]?\s*$", re.IGNORECASE)
_VERBOSE = re.compile(r"\b(?:use|spend)\s+(\d+(?:\.\d+)?)\s*(k|m|b)\s*tokens?\b", re.IGNORECASE)
_MULT = {"k": 1_000, "m": 1_000_000, "b": 1_000_000_000}

# Threshold at which we inject a one-shot "wrap up" nudge into the next turn.
WARN_PCT = 90


def _state_path(sid: str) -> str:
    return f"brain/state/budget_{sid}.json"


def parse(text: str):
    """Return an int budget if `text` declares one, else None."""
    if not text:
        return None
    for pat in (_SHORTHAND_START, _SHORTHAND_END, _VERBOSE):
        m = pat.search(text)
        if m:
            try:
                return int(float(m.group(1)) * _MULT[m.group(2).lower()])
            except (KeyError, ValueError):
                continue
    return None


def _load(sid: str) -> dict:
    p = _state_path(sid)
    try:
        with open(p) as f:
            return json.load(f) or {}
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def _save(sid: str, state: dict) -> None:
    p = _state_path(sid)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = f"{p}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.replace(tmp, p)


def set_budget(sid: str, budget: int, by: str) -> dict:
    """Create or replace the budget for this session. Resets `spent` to 0."""
    state = {
        "budget": int(budget),
        "spent": 0,
        "set_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "set_by": by,
        "warned_90": False,
    }
    _save(sid, state)
    return state


def add_spent(sid: str, delta: int) -> dict:
    """Accumulate `delta` tokens. Returns the updated state plus computed flags.

    The harness uses these flags to:
      - inject a one-shot warning into the next turn's context (`crossed_90`)
      - exit the turn loop cleanly when the budget is exhausted (`exhausted`)
    """
    state = _load(sid)
    if not state or "budget" not in state:
        return {}
    prev_pct = (state.get("spent", 0) / state["budget"] * 100) if state["budget"] else 0
    state["spent"] = state.get("spent", 0) + int(delta)
    pct = (state["spent"] / state["budget"] * 100) if state["budget"] else 0
    crossed_90 = (prev_pct < WARN_PCT <= pct) and not state.get("warned_90")
    if crossed_90:
        state["warned_90"] = True
    state["_pct"] = round(pct, 1)
    state["_crossed_90"] = crossed_90
    state["_exhausted"] = pct >= 100
    _save(sid, {k: v for k, v in state.items() if not k.startswith("_")})
    return state


def format_line(sid: str) -> str:
    """One-line status fragment for injection into the per-turn context block."""
    state = _load(sid)
    if not state or "budget" not in state:
        return ""

    def fmt(n: int) -> str:
        return f"{n/1000:.1f}k" if n >= 1000 else str(n)

    pct = (state["spent"] / state["budget"] * 100) if state["budget"] else 0
    warn = " ⚠ approaching limit" if pct >= WARN_PCT else ""
    return (
        f"- **Active budget** (set by {state.get('set_by','?')}): "
        f"{fmt(state['spent'])} / {fmt(state['budget'])} ({pct:.1f}%){warn}"
    )


def clear(sid: str) -> None:
    try:
        os.remove(_state_path(sid))
    except FileNotFoundError:
        pass


def _cli():
    if len(sys.argv) < 2:
        sys.exit("usage: token_budget.py <parse|set|add|get|line|clear> ...")
    cmd = sys.argv[1]
    if cmd == "parse":
        text = sys.argv[2] if len(sys.argv) > 2 else sys.stdin.read()
        v = parse(text)
        if v is not None:
            print(v)
    elif cmd == "set":
        _, _, sid, budget, by = sys.argv[:5]
        s = set_budget(sid, int(budget), by)
        print(json.dumps(s))
    elif cmd == "add":
        _, _, sid, delta = sys.argv[:4]
        s = add_spent(sid, int(delta))
        if not s:
            return
        # Compact line bash can parse with `read`: spent|pct|crossed_90|exhausted
        print(f"{s.get('spent',0)}|{s.get('_pct',0)}|"
              f"{'1' if s.get('_crossed_90') else '0'}|"
              f"{'1' if s.get('_exhausted') else '0'}")
    elif cmd == "get":
        s = _load(sys.argv[2])
        if s:
            print(json.dumps(s))
    elif cmd == "line":
        print(format_line(sys.argv[2]))
    elif cmd == "clear":
        clear(sys.argv[2])
    else:
        sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    _cli()
