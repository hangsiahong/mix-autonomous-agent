#!/usr/bin/env python3
"""
tools/memory_critic.py — Quality gatekeeper for memory writes.

Sits between the agent's proposed memory entry and the actual store. Runs the
proposed write through a cheap critic model (different from the writer, so
disagreement catches drift) and accepts/rejects/revises it.

Two modes:
  curated  — for tools/memory.sh (MEMORY.md / USER.md). Sees all existing
             entries; checks specificity, redundancy, contradiction.
  vector   — for tools/memory_remember.sh (LanceDB). Quality-only check on the
             proposed text — no full list of existing entries (vector store
             is unbounded; we don't fetch nearest for now).

CLI:
  echo '{"text":"...","existing":[...],"target":"memory"}' | \\
      python3 tools/memory_critic.py --mode curated

  echo '{"text":"..."}' | python3 tools/memory_critic.py --mode vector

Output (stdout, single line JSON):
  {"accept": true|false, "reason": "...", "revised": "..." | null}

Killswitch: AMA_MEM_CRITIC_DISABLED=1 makes the critic accept everything
without invoking the model — useful for migrations or debugging.

Log: every verdict (and reason) is appended to brain/state/memory_critic.log
so you can audit what got blocked or revised.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
LOG_FILE = DIR / "brain" / "state" / "memory_critic.log"

sys.path.insert(0, str(DIR / "tools"))
import mix_call  # noqa: E402


def _log(verdict: dict, mode: str, text: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with LOG_FILE.open("a") as f:
            f.write(json.dumps({
                "ts": int(time.time()),
                "mode": mode,
                "accept": verdict.get("accept"),
                "reason": verdict.get("reason", "")[:200],
                "revised": bool(verdict.get("revised")),
                "text_preview": text[:120],
            }) + "\n")
    except Exception:
        pass


CURATED_SYSTEM = """You are a memory quality gatekeeper for an autonomous agent.

The agent wants to add a new entry to its curated memory file (MEMORY.md or USER.md).
These files are read EVERY turn, so noise is expensive. You decide if the entry is
worth saving.

Accept an entry only if ALL hold:
1. It is specific (concrete fact, preference, decision, identifier, date, name, etc.)
   not vague boilerplate ("user wants good results", "be helpful", etc).
2. It is self-contained — readable without surrounding conversation context.
3. It is not a near-duplicate of any existing entry.
4. It does not directly contradict an existing entry (unless the new entry is
   clearly an update — in that case it should still be accepted but flag it).
5. For target=user, it is genuinely about the USER (their role, preferences,
   constraints) — not just current task state.

If you can tighten the wording without losing information, return the tightened
version in "revised". Otherwise leave revised as null.

Output ONLY a JSON object with keys: accept (bool), reason (one short sentence),
revised (string or null). No markdown, no prose around it."""


VECTOR_SYSTEM = """You are a memory quality gatekeeper for an autonomous agent.

The agent wants to save an observation to its vector memory store (recalled later
via embedding search). You decide if the entry is worth saving.

Accept only if it is:
- Specific (concrete fact, event, finding) not vague boilerplate.
- Self-contained — readable without conversation context.
- Likely to be useful when recalled later (would the agent or user benefit?).

Reject vague summaries, restatements of the task, or "the user said X" without
the substance of X.

Output ONLY a JSON object: {accept: bool, reason: one short sentence, revised: string|null}.
If you can tighten without losing info, fill revised. No markdown."""


def _format_curated_user(text: str, existing: list[str], target: str) -> str:
    existing_str = "\n".join(f"  - {e[:200]}" for e in existing) if existing else "  (none)"
    return (
        f"target: {target}\n\n"
        f"existing entries:\n{existing_str}\n\n"
        f"proposed new entry:\n\"\"\"\n{text}\n\"\"\""
    )


def _format_vector_user(text: str) -> str:
    return f"proposed entry to save in vector memory:\n\"\"\"\n{text}\n\"\"\""


def _parse_verdict(raw: str) -> dict:
    """Parse the model's JSON. Be tolerant of fenced blocks."""
    s = (raw or "").strip()
    if s.startswith("```"):
        s = s.split("```", 2)
        s = s[1] if len(s) >= 2 else ""
        if s.startswith("json"):
            s = s[4:]
        s = s.strip().rstrip("`").strip()
    try:
        d = json.loads(s)
    except Exception:
        return {"accept": True, "reason": f"critic returned unparsable output, defaulting to accept", "revised": None}
    accept = bool(d.get("accept", True))
    reason = str(d.get("reason", "")).strip()[:300]
    revised = d.get("revised")
    if revised is not None and not isinstance(revised, str):
        revised = None
    if revised is not None:
        revised = revised.strip()
        if not revised:
            revised = None
    return {"accept": accept, "reason": reason, "revised": revised}


def check_curated(text: str, existing: list[str], target: str = "memory") -> dict:
    if os.environ.get("AMA_MEM_CRITIC_DISABLED") == "1":
        return {"accept": True, "reason": "critic disabled", "revised": None}
    if not text or not text.strip():
        return {"accept": False, "reason": "empty text", "revised": None}
    raw = mix_call.call(
        tier="memory_critic",
        system=CURATED_SYSTEM,
        user=_format_curated_user(text, existing, target),
        max_tokens=1500,
        temperature=0.0,
        json_mode=True,
        timeout=20,
    )
    if not raw:
        # mix_call failed (network, rate limit) → fail open. Better to save a
        # possibly-bad entry than to lose a possibly-good one.
        return {"accept": True, "reason": "critic unreachable, fail open", "revised": None}
    verdict = _parse_verdict(raw)
    _log(verdict, "curated", text)
    return verdict


def check_vector(text: str) -> dict:
    if os.environ.get("AMA_MEM_CRITIC_DISABLED") == "1":
        return {"accept": True, "reason": "critic disabled", "revised": None}
    if not text or not text.strip():
        return {"accept": False, "reason": "empty text", "revised": None}
    raw = mix_call.call(
        tier="memory_critic",
        system=VECTOR_SYSTEM,
        user=_format_vector_user(text),
        max_tokens=1500,
        temperature=0.0,
        json_mode=True,
        timeout=20,
    )
    if not raw:
        return {"accept": True, "reason": "critic unreachable, fail open", "revised": None}
    verdict = _parse_verdict(raw)
    _log(verdict, "vector", text)
    return verdict


def main() -> int:
    p = argparse.ArgumentParser(description="Memory write critic")
    p.add_argument("--mode", choices=("curated", "vector"), required=True)
    args = p.parse_args()

    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception as e:
        print(json.dumps({"accept": True, "reason": f"bad stdin json: {e}", "revised": None}))
        return 0

    text = str(payload.get("text", ""))
    if args.mode == "curated":
        verdict = check_curated(
            text=text,
            existing=list(payload.get("existing", []) or []),
            target=str(payload.get("target", "memory")),
        )
    else:
        verdict = check_vector(text=text)

    print(json.dumps(verdict))
    return 0


if __name__ == "__main__":
    sys.exit(main())
