#!/usr/bin/env python3
"""
tools/mix_call.py — Thin OpenAI-compatible chat helper for BACKGROUND tasks only.

Reads brain/tier_routing.json and dispatches to the configured provider+model per
tier. The main user-facing turn is NOT handled here — that goes through
core/mix/16_api.sh + the provider scripts and stays on Vertex AI (paid credits).

Python:
    from mix_call import call
    text = call(tier="distill", messages=[{"role":"user","content":"..."}])

NOTE on embeddings: embeddings are NOT exposed here. Use
`tools/memory_helper.py:get_embedding()` instead — it already routes to
Vertex AI (text-embedding-004) via the main Google provider config.

CLI (bash callers):
    echo "user prompt" | python3 tools/mix_call.py --tier distill \\
        [--system "system prompt"] [--max-tokens 2000] [--json-mode]

Usage tracking lands in brain/state/mix_call_usage.jsonl (one line per call).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import requests

DIR = Path(__file__).resolve().parent.parent
ROUTING_FILE = DIR / "brain" / "tier_routing.json"
USAGE_LOG = DIR / "brain" / "state" / "mix_call_usage.jsonl"


_routing_cache: dict | None = None


def _load_routing() -> dict:
    global _routing_cache
    if _routing_cache is None:
        _routing_cache = json.loads(ROUTING_FILE.read_text())
    return _routing_cache


def _resolve(tier: str) -> tuple[str, str, str, str]:
    """Returns (provider, model, base_url, api_key)."""
    routing = _load_routing()
    entry = routing.get(tier)
    if not entry or not isinstance(entry, dict):
        raise ValueError(f"mix_call: unknown tier '{tier}' in tier_routing.json")
    provider = entry["provider"]
    model = entry["model"]
    pcfg = routing.get("providers", {}).get(provider)
    if not pcfg:
        raise ValueError(f"mix_call: provider '{provider}' not configured in tier_routing.json")
    base_url = pcfg["base_url"]
    api_key = os.environ.get(pcfg["api_key_env"], "")
    if not api_key:
        raise RuntimeError(f"mix_call: env var {pcfg['api_key_env']} is empty")
    return provider, model, base_url, api_key


def _log_usage(tier: str, model: str, ok: bool, tokens_in: int, tokens_out: int, dt: float, err: str = "") -> None:
    try:
        USAGE_LOG.parent.mkdir(parents=True, exist_ok=True)
        with USAGE_LOG.open("a") as f:
            f.write(json.dumps({
                "ts": int(time.time()),
                "tier": tier,
                "model": model,
                "ok": ok,
                "tokens_in": tokens_in,
                "tokens_out": tokens_out,
                "duration_ms": int(dt * 1000),
                "err": err[:200],
            }) + "\n")
    except Exception:
        pass


def call(
    tier: str,
    messages: list[dict] | None = None,
    *,
    system: str | None = None,
    user: str | None = None,
    max_tokens: int = 2048,
    temperature: float = 0.3,
    json_mode: bool = False,
    timeout: int = 60,
    retries: int = 1,
) -> str:
    """
    Make a chat completion call against the tier's configured provider+model.
    Returns the assistant text (empty string on failure — never raises for
    callers; check return value).

    `messages` is OpenAI-format. As a convenience, you can pass `system` and/or
    `user` strings instead and they'll be wrapped for you.
    """
    if messages is None:
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        if user:
            messages.append({"role": "user", "content": user})
    elif system and not any(m.get("role") == "system" for m in messages):
        messages = [{"role": "system", "content": system}] + messages

    try:
        provider, model, base_url, api_key = _resolve(tier)
    except Exception as e:
        _log_usage(tier, "", False, 0, 0, 0.0, str(e))
        print(f"mix_call: resolve error: {e}", file=sys.stderr)
        return ""

    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
        "stream": False,
    }
    if json_mode:
        payload["response_format"] = {"type": "json_object"}

    headers = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}
    url = f"{base_url}/chat/completions"

    t0 = time.time()
    last_err = ""
    for attempt in range(retries + 1):
        try:
            resp = requests.post(url, headers=headers, json=payload, timeout=timeout)
            if resp.status_code >= 500 and attempt < retries:
                last_err = f"HTTP {resp.status_code}"
                time.sleep(0.8 * (attempt + 1))
                continue
            resp.raise_for_status()
            data = resp.json()
            text = (data.get("choices", [{}])[0].get("message", {}).get("content") or "").strip()
            usage = data.get("usage", {}) or {}
            _log_usage(
                tier, model, True,
                int(usage.get("prompt_tokens", 0) or 0),
                int(usage.get("completion_tokens", 0) or 0),
                time.time() - t0,
            )
            return text
        except Exception as e:
            last_err = str(e)
            if attempt < retries:
                time.sleep(0.8 * (attempt + 1))
                continue

    _log_usage(tier, model, False, 0, 0, time.time() - t0, last_err)
    print(f"mix_call: {tier}/{model} failed: {last_err}", file=sys.stderr)
    return ""


def main() -> int:
    p = argparse.ArgumentParser(description="mix_call CLI — background-tier chat helper")
    p.add_argument("--tier", required=True, help="Tier name from brain/tier_routing.json")
    p.add_argument("--system", default=None)
    p.add_argument("--max-tokens", type=int, default=2048)
    p.add_argument("--temperature", type=float, default=0.3)
    p.add_argument("--json-mode", action="store_true")
    p.add_argument("--timeout", type=int, default=60)
    args = p.parse_args()

    user_text = sys.stdin.read().strip()
    if not user_text:
        print("mix_call: empty stdin", file=sys.stderr)
        return 2

    out = call(
        tier=args.tier,
        system=args.system,
        user=user_text,
        max_tokens=args.max_tokens,
        temperature=args.temperature,
        json_mode=args.json_mode,
        timeout=args.timeout,
    )
    if not out:
        return 1
    sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
