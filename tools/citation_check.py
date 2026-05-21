#!/usr/bin/env python3
"""
tools/citation_check.py — Event-driven hallucination scanner.

Run after each agent turn IF the assistant's reply contains specific-fact
patterns (URLs, version strings, paths, dates not equal to today, stats).
Compares those claims against the tool results from the same turn. Anything
the agent stated that isn't traceable to a tool result gets flagged.

Output is persisted per-session at brain/state/citation_warnings_<sid>.json
(last 3 turns kept). 16_api.sh / 24_agent_loop.sh reads that file and injects
a "## Citation Warnings" block into the next turn's context.

CLI:
  python3 tools/citation_check.py --session-id <sid> --history brain/state/history_<sid>.json

Killswitch: AMA_CITATION_CHECK_DISABLED=1 short-circuits to no-op.

This is an OPTIONAL check — failures fail silently. The system prompt rule
is the primary defense; this is a backstop for when the cheap model drifts.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from datetime import date
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
WARNINGS_DIR = DIR / "brain" / "state"
MAX_KEPT = 3

sys.path.insert(0, str(DIR / "tools"))
import mix_call  # noqa: E402


# Patterns that suggest the assistant made a specific factual claim worth checking.
# Cheap pre-filter — if none of these match, skip the LLM check entirely.
_PATTERNS = [
    re.compile(r"https?://[^\s)\]]+"),                           # URLs
    re.compile(r"\bv?\d+\.\d+(?:\.\d+)?(?:-[\w.]+)?\b"),         # version-ish (1.2.3, v0.5)
    re.compile(r"\b\d{4}-\d{2}-\d{2}\b"),                        # ISO dates
    re.compile(r"\b\d+(?:,\d{3})+\b"),                           # large numbers (1,234,567)
    re.compile(r"\b\d+(?:\.\d+)?\s*%(?!\w)"),                    # percentages
    re.compile(r"\$\d[\d,.]*"),                                  # prices
    re.compile(r"\b(?:[\w-]+\.[\w-]+){2,}\b"),                   # dotted identifiers (foo.bar.baz)
    re.compile(r"`[^`]{3,80}`"),                                 # backticked code/identifier
]


def needs_check(text: str) -> bool:
    if not text or len(text) < 60:
        return False
    return any(p.search(text) for p in _PATTERNS)


def _extract_turn(history: list[dict]) -> tuple[str, str, str]:
    """
    Return (last_user_text, last_assistant_text, tool_results_blob).

    Walks backwards from end. tool_results_blob concatenates all tool messages
    seen between the last user message and the last assistant text response.
    """
    last_user = ""
    last_assistant = ""
    tool_blobs: list[str] = []

    # Find the most recent assistant final text (no tool_calls or with tool_calls but content set)
    last_assistant_idx = -1
    for i in range(len(history) - 1, -1, -1):
        m = history[i]
        if m.get("role") == "assistant":
            c = m.get("content")
            if isinstance(c, str) and c.strip():
                last_assistant = c.strip()
                last_assistant_idx = i
                break

    if last_assistant_idx < 0:
        return "", "", ""

    # Walk backwards from the assistant to collect tool results + the user message
    for i in range(last_assistant_idx - 1, -1, -1):
        m = history[i]
        role = m.get("role")
        if role == "tool":
            c = m.get("content") or ""
            if isinstance(c, str):
                tool_blobs.append(c[:2000])
        elif role == "user":
            c = m.get("content") or ""
            if isinstance(c, list):
                c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
            last_user = str(c)[:1500]
            break

    return last_user, last_assistant, "\n---\n".join(reversed(tool_blobs))[:8000]


CITATION_SYSTEM = """You are a hallucination scanner for an autonomous agent.

You see:
- the user's latest question
- the tool results the agent gathered this turn (web pages, file reads, search results, etc.)
- the agent's reply to the user

Your job: identify SPECIFIC factual claims in the reply that are NOT supported by
the tool results. Specific = checkable: URLs, version numbers, file paths,
function names, dates, statistics, prices, named identifiers, direct quotes.

DO NOT flag:
- general knowledge (math, language, definitions, well-known concepts)
- claims clearly hedged with "I think", "I'm not sure", "from memory"
- claims that match content in the tool results
- the agent saying "I don't know" or asking the user something

Today's date is provided for context — dates equal to today are fine without sourcing.

Output ONLY a JSON object:
{
  "violations": [
    {"claim": "<exact phrase from reply>", "reason": "<why this is unsourced>"}
  ]
}

If nothing flags, output {"violations": []}. Be strict — false positives waste
the user's attention. Only flag what is genuinely specific and unsourced."""


def run_check(history_file: Path, session_id: str) -> dict:
    if os.environ.get("AMA_CITATION_CHECK_DISABLED") == "1":
        return {"skipped": "killswitched"}

    try:
        history = json.loads(history_file.read_text())
    except Exception as e:
        return {"skipped": f"history read failed: {e}"}

    last_user, last_assistant, tool_blob = _extract_turn(history)
    if not last_assistant:
        return {"skipped": "no assistant reply found"}

    if not needs_check(last_assistant):
        return {"skipped": "no specific-fact patterns in reply"}

    user_prompt = (
        f"Today's date: {date.today().isoformat()}\n\n"
        f"User's question:\n\"\"\"\n{last_user}\n\"\"\"\n\n"
        f"Tool results this turn:\n\"\"\"\n{tool_blob or '(none)'}\n\"\"\"\n\n"
        f"Agent's reply:\n\"\"\"\n{last_assistant}\n\"\"\""
    )

    raw = mix_call.call(
        tier="citation",
        system=CITATION_SYSTEM,
        user=user_prompt,
        max_tokens=800,
        temperature=0.0,
        json_mode=True,
        timeout=25,
    )
    if not raw:
        return {"skipped": "model unreachable"}

    try:
        s = raw.strip()
        if s.startswith("```"):
            s = s.split("```", 2)[1]
            if s.startswith("json"):
                s = s[4:]
            s = s.strip().rstrip("`").strip()
        verdict = json.loads(s)
    except Exception:
        return {"skipped": "unparsable model output"}

    violations = verdict.get("violations") or []
    if not isinstance(violations, list):
        violations = []
    violations = [v for v in violations if isinstance(v, dict) and v.get("claim")]

    if violations:
        _persist(session_id, violations)
    return {"violations": violations}


def _persist(session_id: str, violations: list[dict]) -> None:
    path = WARNINGS_DIR / f"citation_warnings_{session_id}.json"
    try:
        existing = json.loads(path.read_text()) if path.exists() else []
    except Exception:
        existing = []
    if not isinstance(existing, list):
        existing = []
    entry = {
        "ts": int(time.time()),
        "violations": violations[:5],  # cap per-turn flags
    }
    existing.append(entry)
    existing = existing[-MAX_KEPT:]
    try:
        WARNINGS_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(existing))
    except Exception:
        pass


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--session-id", required=True)
    p.add_argument("--history", required=True, help="Path to history_<sid>.json")
    args = p.parse_args()

    result = run_check(Path(args.history), args.session_id)
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
