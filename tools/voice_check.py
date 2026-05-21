#!/usr/bin/env python3
"""
tools/voice_check.py — Style/voice drift detector.

After each agent turn, checks whether the assistant's most recent reply matches
the established voice in USER.md. Only runs when USER.md contains voice-related
entries (terms like "terse", "concise", "casual", "formal", "tone", "voice",
"style", "prefer", etc) — otherwise returns immediately.

If drift is detected, writes a single warning to
brain/state/voice_warnings_<sid>.json which is injected into the next turn's
context via 24_agent_loop.sh.

Killswitch: AMA_VOICE_CHECK_DISABLED=1.

CLI:
    python3 tools/voice_check.py --session-id <sid> \\
        --history brain/state/history_<sid>.json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
USER_MD = DIR / "brain" / "state" / "USER.md"
WARNINGS_DIR = DIR / "brain" / "state"

sys.path.insert(0, str(DIR / "tools"))
import mix_call  # noqa: E402


_VOICE_KEYWORDS = re.compile(
    r"\b(terse|concise|short|brief|laconic|verbose|wordy|chatty|formal|informal|"
    r"casual|polite|blunt|direct|friendly|cold|warm|tone|voice|style|"
    r"prefer(s|red|ence)?|avoid|no\s+(filler|emoji|exclamation|disclaimer))\b",
    re.I,
)


def _has_voice_prefs(user_md_text: str) -> list[str]:
    """Return the voice-related lines from USER.md. Empty list if none."""
    if not user_md_text:
        return []
    out = []
    for entry in user_md_text.split("§"):
        e = entry.strip()
        if e and _VOICE_KEYWORDS.search(e):
            out.append(e[:300])
    return out


def _last_assistant_reply(history: list[dict]) -> str:
    for m in reversed(history):
        if m.get("role") != "assistant":
            continue
        c = m.get("content")
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        if isinstance(c, str) and c.strip():
            return c.strip()[:4000]
    return ""


VOICE_SYSTEM = """You are checking whether an assistant's most recent reply follows the user's stated voice/style preferences.

You see:
- voice_prefs: the user's stated preferences (extracted from their persistent USER.md notes)
- reply: the assistant's most recent reply

Decide if the reply drifts from the established voice. Be strict but fair —
a single missing comma is not drift; verbose padding when the user wants terse
IS drift.

Output ONLY a JSON object:
{
  "drift": true|false,
  "reason": "<one short sentence — what drifted, or empty if none>",
  "suggestion": "<one short sentence — what to do next turn, or empty>"
}

Mark drift=false unless you can point to a specific way the reply violates
the stated preferences. False positives are annoying; under-flagging is fine."""


def run_check(history_file: Path, session_id: str) -> dict:
    if os.environ.get("AMA_VOICE_CHECK_DISABLED") == "1":
        return {"skipped": "killswitched"}

    if not USER_MD.exists():
        return {"skipped": "no USER.md"}

    user_md_text = USER_MD.read_text(errors="ignore")
    voice_prefs = _has_voice_prefs(user_md_text)
    if not voice_prefs:
        return {"skipped": "USER.md has no voice-related entries"}

    try:
        history = json.loads(history_file.read_text())
    except Exception as e:
        return {"skipped": f"history read failed: {e}"}

    reply = _last_assistant_reply(history)
    if not reply or len(reply) < 40:
        return {"skipped": "reply too short to evaluate"}

    raw = mix_call.call(
        tier="voice_check",
        system=VOICE_SYSTEM,
        user=(
            f"voice_prefs:\n"
            + "\n".join(f"- {p}" for p in voice_prefs[:6])
            + f"\n\nreply:\n\"\"\"\n{reply}\n\"\"\""
        ),
        max_tokens=1000,
        temperature=0.0,
        json_mode=True,
        timeout=20,
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

    if not verdict.get("drift"):
        return {"drift": False}

    _persist(session_id, {
        "ts": int(time.time()),
        "reason": str(verdict.get("reason", ""))[:200],
        "suggestion": str(verdict.get("suggestion", ""))[:200],
    })
    return {"drift": True, "reason": verdict.get("reason", "")}


def _persist(session_id: str, entry: dict) -> None:
    path = WARNINGS_DIR / f"voice_warnings_{session_id}.json"
    try:
        WARNINGS_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps([entry]))
    except Exception:
        pass


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--session-id", required=True)
    p.add_argument("--history", required=True)
    args = p.parse_args()
    print(json.dumps(run_check(Path(args.history), args.session_id)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
