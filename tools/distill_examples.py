#!/usr/bin/env python3
"""
tools/distill_examples.py — Build brain/learned_examples.md from
brain/state/learning_examples.jsonl.

Picks the most recent N good (👍/❤️) and M bad (👎) reactions and renders
them as worked examples that get injected into the system prompt. The model
learns from concrete examples better than from abstract rules, so we keep
this verbatim (no synthesis pass) — the user's actual reactions are the
strongest signal we have.

CLI:
    python3 tools/distill_examples.py          # writes brain/learned_examples.md
    python3 tools/distill_examples.py --dry    # prints, doesn't write
    python3 tools/distill_examples.py --max-good 5 --max-bad 3
"""
from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
SOURCE = DIR / "brain" / "state" / "learning_examples.jsonl"
OUT = DIR / "brain" / "learned_examples.md"

# Caps so the injected block stays bounded. The system prompt is cached, so
# small fluctuations in size hurt the cache hit rate — these stay stable.
DEFAULT_MAX_GOOD = 5
DEFAULT_MAX_BAD = 3
USER_PREVIEW_CHARS = 400
ASSIST_PREVIEW_CHARS = 700


def _load() -> list[dict]:
    if not SOURCE.exists():
        return []
    out = []
    for ln in SOURCE.read_text(errors="ignore").splitlines():
        ln = ln.strip()
        if not ln:
            continue
        try:
            out.append(json.loads(ln))
        except Exception:
            pass
    return out


def _dedup(entries: list[dict]) -> list[dict]:
    """
    Drop near-duplicates by (user_text first 100 chars, kind). Recent wins.
    Keeps signal diverse — 5 reactions on variations of the same question
    don't crowd out other examples.
    """
    seen: set[tuple[str, str]] = set()
    out: list[dict] = []
    for e in reversed(entries):  # walk from newest
        key = (str(e.get("user_text", ""))[:100].strip().lower(), e.get("kind", ""))
        if key in seen:
            continue
        seen.add(key)
        out.append(e)
    out.reverse()
    return out


def _fmt_example(e: dict, n: int) -> str:
    ts = e.get("ts")
    when = datetime.fromtimestamp(int(ts)).strftime("%Y-%m-%d") if ts else "unknown"
    user = str(e.get("user_text", "")).strip()[:USER_PREVIEW_CHARS]
    asst = str(e.get("assistant_text", "")).strip()[:ASSIST_PREVIEW_CHARS]
    emoji = e.get("emoji", "")
    model = e.get("model", "")

    if len(str(e.get("user_text", ""))) > USER_PREVIEW_CHARS:
        user += "…"
    if len(str(e.get("assistant_text", ""))) > ASSIST_PREVIEW_CHARS:
        asst += "…"

    return (
        f"### Example {n} — {when} (reaction: {emoji}, model: {model})\n"
        f"**User:** {user}\n\n"
        f"**Reply:** {asst}\n"
    )


def render(max_good: int = DEFAULT_MAX_GOOD, max_bad: int = DEFAULT_MAX_BAD) -> str:
    entries = _dedup(_load())
    goods = [e for e in entries if e.get("kind") == "good"][-max_good:]
    bads = [e for e in entries if e.get("kind") == "bad"][-max_bad:]

    if not goods and not bads:
        return ""

    parts: list[str] = []
    parts.append("# Learned Reasoning Examples")
    parts.append(
        "These are real past exchanges where the user reacted. **Match the style "
        "and reasoning shape of the goods**; **do not repeat the patterns of the "
        "bads**. The user's reactions are the ground truth on what works in this "
        "specific relationship — weight them heavily."
    )

    if goods:
        parts.append("\n## Good — replies the user reacted positively to")
        for i, e in enumerate(reversed(goods), 1):
            parts.append(_fmt_example(e, i))

    if bads:
        parts.append("\n## Bad — replies the user reacted negatively to")
        for i, e in enumerate(reversed(bads), 1):
            parts.append(_fmt_example(e, i))

    return "\n".join(parts).rstrip() + "\n"


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--max-good", type=int, default=DEFAULT_MAX_GOOD)
    p.add_argument("--max-bad", type=int, default=DEFAULT_MAX_BAD)
    p.add_argument("--dry", action="store_true", help="Print, don't write")
    args = p.parse_args()

    text = render(max_good=args.max_good, max_bad=args.max_bad)
    if args.dry:
        sys.stdout.write(text or "(no examples yet)\n")
        return 0

    if not text:
        # Nothing to write — remove stale output so we don't inject empty.
        if OUT.exists():
            OUT.unlink()
        return 0

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text)
    print(f"wrote {OUT.relative_to(DIR)} ({len(text)} chars)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
