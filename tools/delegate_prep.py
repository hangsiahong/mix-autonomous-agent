#!/usr/bin/env python3
"""
tools/delegate_prep.py — Delegation handoff hygiene.

Wraps the agent's raw delegate-call inputs (goal, context, backend) with three
guardrails:

1. **Critique & revise the prompt** — cheap-model pass that checks the goal
   for completeness (paths, acceptance criteria, scope) and rewrites if vague.
   Bad delegate prompts produce bad delegate results no matter how powerful
   the backend; this is the highest-leverage step.

2. **Cache by hash** — sync delegate calls hash (goal+context+backend) and
   look up brain/state/delegate_cache/<hash>.json. Cached results within 24h
   are returned immediately. Async (tmux-backed) calls are NOT cached.

3. **Sanity-check the result** — after the delegate returns, a cheap-model
   pass asks "does this answer the goal?". If clearly off, the caller can
   retry with a tighter prompt.

Killswitch: AMA_DELEGATE_PREP_DISABLED=1 short-circuits prep to passthrough.
All three guardrails fail open — never block a delegate call on prep error.

Public API:
    prep_handoff(goal, context, backend) -> dict
        {"goal": str, "context": str, "cached": dict|None, "prep_note": str}
    cache_save(key, result_dict) -> None
    cache_get(key) -> dict|None
    verify_result(goal, result_text) -> dict
        {"satisfied": bool, "reason": str}
    cache_key(goal, context, backend) -> str
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
CACHE_DIR = DIR / "brain" / "state" / "delegate_cache"
CACHE_TTL = 24 * 3600  # 24h — beyond this, refetch

sys.path.insert(0, str(DIR / "tools"))
import mix_call  # noqa: E402


PREP_SYSTEM = """You are a delegation prompt editor for an autonomous agent.

The agent is about to hand off a task to a powerful sub-agent (Claude Code, Codex,
or a sub-AMA). The sub-agent will work autonomously — it can't ask follow-up
questions easily. Your job: take the agent's draft (goal + context) and decide
if it's crisp enough to hand off as-is, or needs tightening.

Accept as-is when the goal has:
- A concrete deliverable ("write X", "find Y", "explain Z")
- Enough context to start (file paths if it's code work, search terms if research)
- Implicit acceptance criteria (it's obvious when it's done)

Revise when:
- Goal is vague ("improve the code", "look at this")
- Critical context missing (no file paths for a code task; no scope for research)
- Acceptance is ambiguous (multiple plausible interpretations)

Output ONLY a JSON object:
{
  "revise": true|false,
  "goal":   "<revised goal or original if revise=false>",
  "context":"<revised context or original>",
  "note":   "<one short sentence on what changed, or 'no change'>"
}

Keep revisions tight — don't pad. If you can't improve it, leave it alone."""


VERIFY_SYSTEM = """You are checking whether a delegate's reply actually answers the goal it was given.

Output ONLY a JSON object:
{
  "satisfied": true|false,
  "reason": "<one short sentence>"
}

Mark satisfied=true if the reply addresses the core goal even if details could
be sharper. Mark satisfied=false only when the reply is clearly off-topic,
empty, an error/refusal, or punted on the actual task.

Be lenient — false negatives cost a retry; false positives cost nothing here."""


def cache_key(goal: str, context: str, backend: str) -> str:
    blob = f"{backend}\n{goal.strip()}\n---\n{context.strip()}"
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:24]


def cache_get(key: str) -> dict | None:
    path = CACHE_DIR / f"{key}.json"
    if not path.exists():
        return None
    try:
        d = json.loads(path.read_text())
    except Exception:
        return None
    if int(time.time()) - int(d.get("ts", 0)) > CACHE_TTL:
        return None
    return d.get("result")


def cache_save(key: str, result: dict) -> None:
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        (CACHE_DIR / f"{key}.json").write_text(json.dumps({
            "ts": int(time.time()),
            "result": result,
        }))
    except Exception:
        pass


def _parse_json(raw: str) -> dict | None:
    s = (raw or "").strip()
    if s.startswith("```"):
        s = s.split("```", 2)[1]
        if s.startswith("json"):
            s = s[4:]
        s = s.strip().rstrip("`").strip()
    try:
        return json.loads(s)
    except Exception:
        return None


def prep_handoff(goal: str, context: str, backend: str) -> dict:
    """
    Critique the prompt, check the cache, return prepped inputs.

    Returns:
        {
          "goal":     final goal text to use,
          "context":  final context text to use,
          "cached":   {"result": "..."} if cache hit, else None,
          "prep_note": short string describing what (if anything) was changed,
        }
    """
    out = {"goal": goal, "context": context, "cached": None, "prep_note": "passthrough"}

    if os.environ.get("AMA_DELEGATE_PREP_DISABLED") == "1":
        out["prep_note"] = "prep disabled"
        return out

    if not goal or not goal.strip():
        out["prep_note"] = "empty goal — prep skipped"
        return out

    # 1. Critique & revise
    user_prompt = (
        f"backend: {backend}\n\n"
        f"goal:\n\"\"\"\n{goal.strip()}\n\"\"\"\n\n"
        f"context:\n\"\"\"\n{(context or '').strip()}\n\"\"\""
    )
    raw = mix_call.call(
        tier="delegate_prep",
        system=PREP_SYSTEM,
        user=user_prompt,
        max_tokens=1200,
        temperature=0.1,
        json_mode=True,
        timeout=25,
    )
    verdict = _parse_json(raw) if raw else None
    if verdict and verdict.get("revise"):
        new_goal = str(verdict.get("goal") or goal).strip()
        new_context = str(verdict.get("context") or context).strip()
        if new_goal:
            out["goal"] = new_goal
        if new_context or not context:
            out["context"] = new_context
        out["prep_note"] = f"revised: {str(verdict.get('note', ''))[:200]}"
    elif verdict:
        out["prep_note"] = f"accepted as-is: {str(verdict.get('note', ''))[:200]}"

    # 2. Cache lookup using the FINAL (post-revision) inputs
    key = cache_key(out["goal"], out["context"], backend)
    hit = cache_get(key)
    if hit:
        out["cached"] = hit
        out["prep_note"] += " | cache hit"

    return out


def verify_result(goal: str, result_text: str) -> dict:
    """
    Cheap sanity check: does result_text answer goal? Fails open (satisfied=true)
    on any model error so the caller doesn't loop on transient issues.
    """
    if os.environ.get("AMA_DELEGATE_PREP_DISABLED") == "1":
        return {"satisfied": True, "reason": "verify disabled"}
    if not result_text or not result_text.strip():
        return {"satisfied": False, "reason": "empty result"}

    raw = mix_call.call(
        tier="delegate_prep",
        system=VERIFY_SYSTEM,
        user=(
            f"goal:\n\"\"\"\n{goal.strip()}\n\"\"\"\n\n"
            f"delegate's reply:\n\"\"\"\n{result_text[:6000]}\n\"\"\""
        ),
        max_tokens=400,
        temperature=0.0,
        json_mode=True,
        timeout=20,
    )
    verdict = _parse_json(raw) if raw else None
    if verdict is None:
        return {"satisfied": True, "reason": "verify model unreachable, assuming OK"}
    return {
        "satisfied": bool(verdict.get("satisfied", True)),
        "reason": str(verdict.get("reason", ""))[:200],
    }


if __name__ == "__main__":
    # CLI usage: echo '{"goal":"...","context":"...","backend":"..."}' | python3 tools/delegate_prep.py prep
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("action", choices=("prep", "verify"))
    args = p.parse_args()
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
    if args.action == "prep":
        print(json.dumps(prep_handoff(
            goal=str(payload.get("goal", "")),
            context=str(payload.get("context", "")),
            backend=str(payload.get("backend", "auto")),
        )))
    else:
        print(json.dumps(verify_result(
            goal=str(payload.get("goal", "")),
            result_text=str(payload.get("result_text", "")),
        )))
