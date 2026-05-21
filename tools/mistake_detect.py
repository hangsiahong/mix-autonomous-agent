#!/usr/bin/env python3
"""
tools/mistake_detect.py — Background mistake detector.

Runs after each agent turn (alongside reflection). Scans the most recent
user message for correction patterns ("no, I meant", "not that", "wrong, ...",
"actually I want", etc). If found, runs a cheap-model extraction pass on the
last user→agent→user exchange to pull out: original phrasing, what agent did,
what user actually wanted, lesson. Records via tools/mistake_db.py.

Killswitch: AMA_MISTAKE_DETECT_DISABLED=1.

CLI:
    python3 tools/mistake_detect.py --session-id <sid> --user-id <uid> \\
        --history brain/state/history_<sid>.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(DIR / "tools"))
import mix_call          # noqa: E402
import mistake_db        # noqa: E402


# Patterns that suggest the latest user message is a correction of the
# previous agent reply. Pre-filter to avoid LLM calls on normal chat.
_CORRECTION_PATTERNS = [
    re.compile(r"\bno[,!.]?\s+(i\s+meant|that's\s+not|that\s+isn[' ]?t|that\s+was\s+wrong)", re.I),
    re.compile(r"\b(wrong|nope|incorrect)\b[,.!]?\s+(do|it[' ]?s|i\s+meant|try)", re.I),
    re.compile(r"\bactually[,]?\s+(i|you|it|that|we)\b", re.I),
    re.compile(r"\b(not|isn[' ]?t)\s+(that|what)\s+i\s+(meant|wanted|asked)", re.I),
    re.compile(r"\bi\s+(meant|wanted|asked\s+for|was\s+asking)\b", re.I),
    re.compile(r"\byou\s+(misunderstood|got\s+it\s+wrong|missed)\b", re.I),
    re.compile(r"\bthat[' ]?s\s+not\s+(what|right|correct)", re.I),
    re.compile(r"^\s*(no|nope|wrong)[\s!,.]", re.I),
]


def is_correction(text: str) -> bool:
    if not text or len(text) < 4:
        return False
    return any(p.search(text) for p in _CORRECTION_PATTERNS)


def _last_exchange(history: list[dict]) -> tuple[str, str, str]:
    """
    Return (prev_user, agent_reply, latest_user).

    prev_user is the user message before the most recent agent reply.
    agent_reply is the most recent assistant text message.
    latest_user is the user message AFTER that agent reply.

    Any of the three may be "" if the exchange isn't complete.
    """
    latest_user = ""
    agent_reply = ""
    prev_user = ""
    state = "want_latest_user"

    for m in reversed(history):
        role = m.get("role")
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        c = (str(c) if c is not None else "").strip()

        if state == "want_latest_user":
            if role == "user" and c:
                latest_user = c[:1500]
                state = "want_agent"
        elif state == "want_agent":
            if role == "assistant" and c:
                agent_reply = c[:1500]
                state = "want_prev_user"
        elif state == "want_prev_user":
            if role == "user" and c:
                prev_user = c[:1500]
                break

    return prev_user, agent_reply, latest_user


EXTRACT_SYSTEM = """You are extracting a teachable correction from a conversation.

You see three messages:
- prev_user: what the user originally asked
- agent_reply: what the agent did/said
- latest_user: the user's correction or follow-up

Decide if `latest_user` is genuinely correcting the agent's prior interpretation
(vs just adding info, asking a follow-up question, or chatting).

If yes, extract a short, reusable lesson. Output ONLY a JSON object:
{
  "is_correction": true|false,
  "user_phrasing": "<the prev_user text — the phrasing that was misread>",
  "agent_did":     "<one short sentence: what the agent did wrong>",
  "actual_want":   "<one short sentence: what the user actually wanted>",
  "lesson":        "<one short sentence: rule that prevents this misread next time>"
}

If is_correction is false, all other fields can be empty strings.

Be strict — only mark is_correction=true when the latest_user really pushes
back on the agent's interpretation. Routine follow-ups, additions, or chat
should be false."""


def detect_and_record(history_file: Path, session_id: str, user_id: str) -> dict:
    if os.environ.get("AMA_MISTAKE_DETECT_DISABLED") == "1":
        return {"skipped": "killswitched"}
    try:
        history = json.loads(history_file.read_text())
    except Exception as e:
        return {"skipped": f"history read failed: {e}"}

    prev_user, agent_reply, latest_user = _last_exchange(history)
    if not latest_user or not agent_reply or not prev_user:
        return {"skipped": "incomplete exchange"}

    if not is_correction(latest_user):
        return {"skipped": "no correction pattern matched"}

    raw = mix_call.call(
        tier="classify",
        system=EXTRACT_SYSTEM,
        user=(
            f"prev_user:\n\"\"\"\n{prev_user}\n\"\"\"\n\n"
            f"agent_reply:\n\"\"\"\n{agent_reply}\n\"\"\"\n\n"
            f"latest_user:\n\"\"\"\n{latest_user}\n\"\"\""
        ),
        max_tokens=1200,
        temperature=0.0,
        json_mode=True,
        timeout=25,
    )
    if not raw:
        return {"skipped": "model unreachable"}

    s = raw.strip()
    if s.startswith("```"):
        s = s.split("```", 2)[1]
        if s.startswith("json"):
            s = s[4:]
        s = s.strip().rstrip("`").strip()
    try:
        verdict = json.loads(s)
    except Exception:
        return {"skipped": "unparsable model output"}

    if not verdict.get("is_correction"):
        return {"detected": False, "reason": "model judged not a correction"}

    new_id = mistake_db.record_mistake(
        user_id=user_id,
        session_id=session_id,
        user_phrasing=str(verdict.get("user_phrasing", prev_user)),
        agent_did=str(verdict.get("agent_did", "")),
        actual_want=str(verdict.get("actual_want", "")),
        lesson=str(verdict.get("lesson", "")),
    )
    return {"detected": True, "id": new_id, "lesson": verdict.get("lesson", "")}


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--session-id", required=True)
    p.add_argument("--user-id", default="")
    p.add_argument("--history", required=True)
    args = p.parse_args()
    print(json.dumps(detect_and_record(Path(args.history), args.session_id, args.user_id)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
