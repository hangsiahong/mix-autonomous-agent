#!/usr/bin/env python3
"""google_cache.py — manage Gemini/Vertex context caches.

The stable part of every request (systemInstruction + tools schema) is
~5k tokens for AMA. We cache it once per session and reference the cache
name (`projects/.../cachedContents/abc123`) on subsequent turns, paying
~25% of the normal input-token rate for cached prefix tokens.

State lives at `brain/state/gemini_cache.json`:
  {
    "<sha256-of-sys+tools+model+mode+project>": {
      "name":        "projects/.../cachedContents/abc",
      "model":       "google/gemini-3-flash-preview",
      "expires_at":  1715800000,
      "created_at":  1715796400
    }
  }

Disabled by setting ENABLE_GEMINI_CACHE=0 in env (or AMA_DIR/.env).

CLI usage (mostly for debugging / cron cleanup):
  python3 tools/google_cache.py get <sys_file> <tools_file>  # prints cache name or empty
  python3 tools/google_cache.py purge                         # clear local state
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
import time
from typing import Optional

try:
    import requests
except Exception:
    requests = None

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE_FILE = os.path.join(ROOT, "brain", "state", "gemini_cache.json")
TTL_SECONDS = int(os.environ.get("GEMINI_CACHE_TTL", "3600"))  # 1h default
MIN_CACHEABLE_TOKENS_ROUGH = 1500  # API min is 1024; pad for char-to-token uncertainty


def _enabled() -> bool:
    return os.environ.get("ENABLE_GEMINI_CACHE", "1") not in ("0", "false", "")


_VERTEX_CACHE_NEEDS_OAUTH_NOTED = False  # log once per process


def _read_state() -> dict:
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except Exception:
        return {}


def _write_state(state: dict) -> None:
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, separators=(",", ":"))
    os.replace(tmp, STATE_FILE)


def _cache_key(system_prompt: str, tools_json: str, model: str, mode: str, project: str) -> str:
    h = hashlib.sha256()
    for chunk in (system_prompt, tools_json, model, mode, project):
        h.update((chunk or "").encode("utf-8", errors="replace"))
        h.update(b"\x00")
    return h.hexdigest()[:32]


def _purge_expired(state: dict) -> dict:
    now = time.time()
    return {k: v for k, v in state.items() if v.get("expires_at", 0) > now + 60}


def _build_tools_decls(tools_json: str) -> list:
    """Convert OpenAI-format tools.json to Gemini function_declarations."""
    try:
        tools = json.loads(tools_json)
    except Exception:
        return []
    decls = []
    for t in tools:
        f = t.get("function") if "function" in t else t
        decls.append({
            "name": f.get("name"),
            "description": f.get("description", ""),
            "parameters": f.get("parameters", {"type": "object", "properties": {}}),
        })
    return [{"function_declarations": decls}] if decls else []


def _create_cache(
    system_prompt: str,
    tools_json: str,
    model: str,
    mode: str,
    project: str,
    region: str,
    api_key: str,
    bearer: Optional[str] = None,
) -> Optional[str]:
    """POST cachedContents. Return cache resource name or None on failure."""
    if requests is None:
        return None

    if mode == "vertex":
        if region == "global":
            base = f"https://aiplatform.googleapis.com/v1/projects/{project}/locations/{region}"
        else:
            base = f"https://{region}-aiplatform.googleapis.com/v1/projects/{project}/locations/{region}"
        url = f"{base}/cachedContents"
        # Vertex expects "publishers/google/models/<model>" in cached content model field
        model_field = f"projects/{project}/locations/{region}/publishers/google/models/{model}"
    else:
        url = f"https://generativelanguage.googleapis.com/v1beta/cachedContents?key={api_key}"
        model_field = f"models/{model}"

    body = {
        "model": model_field,
        "systemInstruction": {"parts": [{"text": system_prompt}]},
        "ttl": f"{TTL_SECONDS}s",
    }
    tools_decls = _build_tools_decls(tools_json)
    if tools_decls:
        body["tools"] = tools_decls

    headers = {"Content-Type": "application/json"}
    if mode == "vertex":
        if bearer:
            headers["Authorization"] = f"Bearer {bearer}"
        elif api_key:
            headers["x-goog-api-key"] = api_key
        if project:
            headers.setdefault("x-goog-user-project", project)

    try:
        r = requests.post(url, json=body, headers=headers, timeout=30)
        if r.status_code in (200, 201):
            name = r.json().get("name")
            return name
        sys.stderr.write(f"google_cache: create HTTP {r.status_code}: {r.text[:400]}\n")
    except Exception as e:
        sys.stderr.write(f"google_cache: create exception: {e}\n")
    return None


def get_or_create(
    system_prompt: str,
    tools_json: str,
    model: str,
    mode: str = "vertex",
    project: str = "",
    region: str = "global",
    api_key: str = "",
    bearer: str = "",
) -> Optional[str]:
    """Return a usable cachedContents resource name, creating if needed.

    Returns None when caching is disabled, content is too small, or the
    create call fails — caller should fall back to inlining.
    """
    if not _enabled():
        return None
    # Vertex `cachedContents` API does NOT accept API keys — needs OAuth2.
    # If we're in vertex mode with only an API key and no bearer token (e.g.
    # gcloud isn't installed), skip silently rather than burning a 401 per turn.
    if mode == "vertex" and not bearer:
        global _VERTEX_CACHE_NEEDS_OAUTH_NOTED
        if not _VERTEX_CACHE_NEEDS_OAUTH_NOTED:
            sys.stderr.write(
                "google_cache: Vertex caching skipped — cachedContents API requires "
                "OAuth2 bearer token (`gcloud auth print-access-token`), not API key. "
                "Install gcloud or set ENABLE_GEMINI_CACHE=0 to silence.\n"
            )
            _VERTEX_CACHE_NEEDS_OAUTH_NOTED = True
        return None
    # Skip if content is too small to be worth caching
    rough_tokens = (len(system_prompt) + len(tools_json)) // 4
    if rough_tokens < MIN_CACHEABLE_TOKENS_ROUGH:
        return None

    state = _purge_expired(_read_state())
    key = _cache_key(system_prompt, tools_json, model, mode, project)

    entry = state.get(key)
    if entry and entry.get("expires_at", 0) > time.time() + 60:
        return entry.get("name")

    # Remove the stale entry (if any) before creating fresh
    state.pop(key, None)

    name = _create_cache(
        system_prompt=system_prompt,
        tools_json=tools_json,
        model=model,
        mode=mode,
        project=project,
        region=region,
        api_key=api_key,
        bearer=bearer,
    )
    if not name:
        # Persist the purge even on failure so we don't leak stale keys
        _write_state(state)
        return None

    state[key] = {
        "name": name,
        "model": model,
        "created_at": int(time.time()),
        "expires_at": int(time.time()) + TTL_SECONDS,
    }
    _write_state(state)
    return name


def invalidate(name: str) -> None:
    """Mark a cache name as bad (e.g. on 404) so we recreate next time."""
    state = _read_state()
    dirty = False
    for k, v in list(state.items()):
        if v.get("name") == name:
            state.pop(k, None)
            dirty = True
    if dirty:
        _write_state(state)


def _cli():
    if len(sys.argv) < 2:
        print("usage: google_cache.py {get|purge|status}", file=sys.stderr)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "purge":
        try:
            os.unlink(STATE_FILE)
            print("purged")
        except FileNotFoundError:
            print("(nothing to purge)")
    elif cmd == "status":
        state = _read_state()
        if not state:
            print("(empty)")
            return
        now = time.time()
        for k, v in state.items():
            remaining = int(v.get("expires_at", 0) - now)
            print(f"  {k[:8]}  {v.get('name','?')[-30:]}  expires in {remaining}s")
    elif cmd == "get":
        # Args: <sys_file> <tools_file>   (env: MODEL, GOOGLE_MODE, GOOGLE_PROJECT, ...)
        sys_file = sys.argv[2]
        tools_file = sys.argv[3]
        sp = open(sys_file).read()
        tj = open(tools_file).read()
        name = get_or_create(
            system_prompt=sp,
            tools_json=tj,
            model=os.environ.get("MODEL", ""),
            mode=os.environ.get("GOOGLE_MODE", "vertex"),
            project=os.environ.get("GOOGLE_PROJECT", ""),
            region=os.environ.get("GOOGLE_REGION", "global"),
            api_key=os.environ.get("GOOGLE_VERTEX_KEY", "") or os.environ.get("GOOGLE_API_KEY", ""),
            bearer=os.environ.get("GOOGLE_BEARER", ""),
        )
        print(name or "")


if __name__ == "__main__":
    _cli()
