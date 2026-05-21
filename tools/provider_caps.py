#!/usr/bin/env python3
"""
tools/provider_caps.py — Reader for brain/provider_capabilities.json.

Lets any codepath ask "does <provider>/<model> support <feature>?" before
sending a payload that uses that feature. The map starts with sensible
defaults per provider; models can override specific capabilities.

Python:
    from provider_caps import get, supports
    get("kconsole", "gemini-2.5-flash", "structured_output")  # → "yes"
    supports("anthropic", "claude-opus-4-7", "cache")           # → True

CLI:
    python3 tools/provider_caps.py get kconsole gemini-2.5-flash structured_output
    python3 tools/provider_caps.py supports anthropic claude-opus-4-7 cache
    python3 tools/provider_caps.py dump kconsole gemini-3-flash-preview

`get` returns the raw string value ("yes"/"no"/"native"/"partial"/etc) or
the int max_context. `supports` returns a bool — True iff the value is
"yes" or "native" (i.e. fully supported).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent
MAP_FILE = DIR / "brain" / "provider_capabilities.json"

_cache: dict | None = None


def _load() -> dict:
    global _cache
    if _cache is None:
        try:
            _cache = json.loads(MAP_FILE.read_text())
        except Exception:
            _cache = {"providers": {}}
    return _cache


def get(provider: str, model: str, feature: str, default=None):
    """
    Return the capability value for (provider, model, feature). Falls back
    to the provider's "default" entry, then to `default`.
    """
    data = _load().get("providers", {})
    p = data.get(provider) or {}
    # Model-specific override first
    m = (p.get("models") or {}).get(model) or {}
    if feature in m:
        return m[feature]
    # Provider default
    d = p.get("default") or {}
    if feature in d:
        return d[feature]
    return default


def supports(provider: str, model: str, feature: str) -> bool:
    """
    Boolean form: True iff the feature is "yes", "native", or "partial".
    "no", "none", missing, or unknown → False.
    """
    v = get(provider, model, feature, default=None)
    if isinstance(v, str):
        return v.lower() in {"yes", "native", "partial"}
    if isinstance(v, bool):
        return v
    return False


def dump(provider: str, model: str) -> dict:
    """Return the merged capability dict for (provider, model)."""
    data = _load().get("providers", {})
    p = data.get(provider) or {}
    merged = dict(p.get("default") or {})
    merged.update((p.get("models") or {}).get(model) or {})
    return merged


def main() -> int:
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("get")
    g.add_argument("provider"); g.add_argument("model"); g.add_argument("feature")

    s = sub.add_parser("supports")
    s.add_argument("provider"); s.add_argument("model"); s.add_argument("feature")

    d = sub.add_parser("dump")
    d.add_argument("provider"); d.add_argument("model")

    args = p.parse_args()
    if args.cmd == "get":
        v = get(args.provider, args.model, args.feature)
        print("" if v is None else v)
    elif args.cmd == "supports":
        print("1" if supports(args.provider, args.model, args.feature) else "0")
    elif args.cmd == "dump":
        print(json.dumps(dump(args.provider, args.model), indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
