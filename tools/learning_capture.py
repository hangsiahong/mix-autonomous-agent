#!/usr/bin/env python3
"""
tools/learning_capture.py — Capture user reactions on bot messages as
learning examples.

Wired in from core/telegram/router.sh when a message_reaction update arrives
on a message the bot owns. Looks up the bot's message log
(brain/state/bot_messages.jsonl), classifies the reaction emoji as
good/bad/neutral, and appends a structured entry to
brain/state/learning_examples.jsonl.

A second tool (tools/distill_examples.py) later reads the examples file
and produces brain/learned_examples.md, which is injected into the system
prompt as worked examples of good/bad reasoning.

This is a background-only script — it does not touch the running session
or send chat messages. The router will optionally react 📚 to the message
to confirm the capture visually.

CLI:
    python3 tools/learning_capture.py \\
        --chat-id 670967877 --message-id 12345 \\
        --user-id 670967877 --emoji "👍"
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
BOT_MSG_LOG = DIR / "brain" / "state" / "bot_messages.jsonl"
EXAMPLES_FILE = DIR / "brain" / "state" / "learning_examples.jsonl"


# Reaction emoji → kind mapping. Anything not listed is "neutral" (still stored
# as light signal). Telegram only allows a fixed list of free-tier reactions
# (premium users get more). These are the common ones.
_GOOD = {"👍", "❤", "❤️", "🔥", "🎉", "👏", "🤩", "😍", "💯", "🏆", "⭐", "🥰"}
_BAD = {"👎", "💩", "🤮", "😡", "🤬", "🤡", "🤔", "😢", "😱"}


def classify(emoji: str) -> str:
    if not emoji:
        return "neutral"
    if emoji in _GOOD:
        return "good"
    if emoji in _BAD:
        return "bad"
    return "neutral"


def find_message(chat_id: str, message_id: str) -> dict | None:
    """
    Look up a bot message by (chat_id, message_id) in bot_messages.jsonl.
    Scans from the end backward so recent messages are found fast. Returns
    None if not found (e.g. reaction on a message we never logged).
    """
    if not BOT_MSG_LOG.exists():
        return None
    try:
        with BOT_MSG_LOG.open() as f:
            # Read all + scan in reverse. The file is small (one line per turn).
            lines = f.readlines()
    except Exception:
        return None

    cid = str(chat_id)
    mid = str(message_id)
    for ln in reversed(lines):
        ln = ln.strip()
        if not ln:
            continue
        try:
            d = json.loads(ln)
        except Exception:
            continue
        if str(d.get("chat_id", "")) == cid and str(d.get("message_id", "")) == mid:
            return d
    return None


def record(chat_id: str, message_id: str, user_id: str, emoji: str) -> dict:
    msg = find_message(chat_id, message_id)
    if not msg:
        return {"ok": False, "reason": "message not found in bot_messages.jsonl"}

    kind = classify(emoji)
    entry = {
        "ts": int(time.time()),
        "chat_id": str(chat_id),
        "message_id": str(message_id),
        "user_id": str(user_id),
        "session_id": msg.get("session_id", ""),
        "kind": kind,
        "emoji": emoji,
        "user_text": (msg.get("user_text") or "")[:2000],
        "assistant_text": (msg.get("assistant_text") or "")[:4000],
        "model": msg.get("model", ""),
    }
    try:
        EXAMPLES_FILE.parent.mkdir(parents=True, exist_ok=True)
        with EXAMPLES_FILE.open("a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        return {"ok": False, "reason": f"write failed: {e}"}

    return {"ok": True, "kind": kind, "session_id": entry["session_id"]}


def log_bot_message(
    chat_id: str, message_id: str, session_id: str,
    user_id: str, user_text: str, assistant_text: str, model: str,
) -> None:
    """
    Append a bot final-answer entry to bot_messages.jsonl. Called from
    24_agent_loop.sh after the final tg_edit_safe. Used by find_message
    later when a reaction arrives.

    Bounded — we keep the last 5000 lines to prevent unbounded growth.
    """
    if not chat_id or not message_id:
        return
    entry = {
        "ts": int(time.time()),
        "chat_id": str(chat_id),
        "message_id": str(message_id),
        "session_id": str(session_id),
        "user_id": str(user_id),
        "user_text": (user_text or "")[:2000],
        "assistant_text": (assistant_text or "")[:4000],
        "model": str(model or ""),
    }
    try:
        BOT_MSG_LOG.parent.mkdir(parents=True, exist_ok=True)
        with BOT_MSG_LOG.open("a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception:
        return

    # Rotate when file exceeds ~5000 lines. Cheap line-count + tail.
    try:
        with BOT_MSG_LOG.open() as f:
            lines = f.readlines()
        if len(lines) > 6000:
            with BOT_MSG_LOG.open("w") as f:
                f.writelines(lines[-5000:])
    except Exception:
        pass


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("react", help="Process a reaction event")
    r.add_argument("--chat-id", required=True)
    r.add_argument("--message-id", required=True)
    r.add_argument("--user-id", default="")
    r.add_argument("--emoji", default="")

    l = sub.add_parser("log", help="Log a bot final-answer message")
    l.add_argument("--chat-id", required=True)
    l.add_argument("--message-id", required=True)
    l.add_argument("--session-id", default="")
    l.add_argument("--user-id", default="")
    l.add_argument("--user-text", default="")
    l.add_argument("--assistant-text", default="")
    l.add_argument("--model", default="")

    s = sub.add_parser("stats", help="Summary of captured reactions")

    args = p.parse_args()
    if args.cmd == "react":
        out = record(args.chat_id, args.message_id, args.user_id, args.emoji)
        print(json.dumps(out))
    elif args.cmd == "log":
        log_bot_message(
            args.chat_id, args.message_id, args.session_id,
            args.user_id, args.user_text, args.assistant_text, args.model,
        )
        print(json.dumps({"ok": True}))
    elif args.cmd == "stats":
        good = bad = neutral = 0
        if EXAMPLES_FILE.exists():
            for ln in EXAMPLES_FILE.read_text().splitlines():
                try:
                    d = json.loads(ln)
                    k = d.get("kind", "")
                    if k == "good": good += 1
                    elif k == "bad": bad += 1
                    else: neutral += 1
                except Exception:
                    pass
        print(json.dumps({"good": good, "bad": bad, "neutral": neutral,
                          "total": good + bad + neutral}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
