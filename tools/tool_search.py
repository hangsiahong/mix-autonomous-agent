#!/usr/bin/env python3
"""
tool_search — cc-oss-inspired deferred tool loader.

Rationale
---------
AMA's `brain/tools.json` declares ~36 tools. Most turns use 1-3. Loading
every schema on every turn wastes tokens and gives the model decision
fatigue. We mark rarely-used tools with `"defer": true`. They appear by
NAME only in the per-turn `## Deferred Tools` context block — no schema.
When the model decides it needs one, it calls this tool with a query and
gets back the full JSONSchema for the matched tools. The harness records
the loaded names in `brain/state/active_tools_<sid>.json`, and on
subsequent turns `core/mix/16_api.sh` includes those schemas in the
payload's `tools` array so the model can actually invoke them.

Query forms
-----------
  select:foo,bar,baz   → fetch those exact tools by name (no scoring)
  +keyword             → require "keyword" in tool name; rank rest
  any free text        → keyword score across name + description

Output (printed to stdout)
--------------------------
Markdown-ish block the model can read. Each matched tool is a single
<function>{...}</function> JSON object — the same encoding as the system-
prompt tool list, so the model can copy patterns.

Subcommands
-----------
  search <sid> <query>       — print matches + record loaded names
  list-deferred <sid>        — print deferred-not-yet-loaded names
  list-active <sid>          — print currently-loaded deferred names
  active-json <sid>          — print the JSON set (for 16_api.sh to merge in)
  clear <sid>                — clear active set
"""
import json
import os
import re
import sys

# How many tools to return per search. cc-oss tunes this experimentally;
# 5 is a reasonable default — the model can refine if it needs more.
DEFAULT_MAX_RESULTS = 5

TOOLS_PATH = "brain/tools.json"
EXTRA_TOOLS_PATH = "brain/tools_extra.json"
ALWAYS_LOAD = {"tool_search"}  # The model needs this one to load others.


def _active_path(sid: str) -> str:
    return f"brain/state/active_tools_{sid}.json"


def _load_all_tools() -> list:
    """Merge brain/tools.json + brain/tools_extra.json (custom tools)."""
    try:
        with open(TOOLS_PATH) as f:
            base = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        base = []
    try:
        with open(EXTRA_TOOLS_PATH) as f:
            extra = json.load(f) or []
    except (FileNotFoundError, json.JSONDecodeError):
        extra = []
    seen = {t.get("name") for t in base if t.get("name")}
    for t in extra:
        if t.get("name") and t["name"] not in seen:
            base.append(t)
            seen.add(t["name"])
    return base


def is_deferred(tool: dict) -> bool:
    """A tool is deferred if it declares `"defer": true` in tools.json."""
    if tool.get("name") in ALWAYS_LOAD:
        return False
    return bool(tool.get("defer"))


def _load_active(sid: str) -> set:
    try:
        with open(_active_path(sid)) as f:
            return set(json.load(f) or [])
    except (FileNotFoundError, json.JSONDecodeError):
        return set()


def _save_active(sid: str, names: set) -> None:
    p = _active_path(sid)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = f"{p}.tmp.{os.getpid()}"
    with open(tmp, "w") as f:
        json.dump(sorted(names), f)
    os.replace(tmp, p)


# Keep the original schema for the response; strip our own bookkeeping
# fields so the model never sees `"defer": true` (would confuse it).
_INTERNAL_FIELDS = ("defer", "toolset")


def _strip(tool: dict) -> dict:
    return {k: v for k, v in tool.items() if k not in _INTERNAL_FIELDS}


def _score(tool: dict, query_terms: list, require: str = None) -> int:
    """Cheap heuristic: name match dominates, description match secondary.

    Scoring (cumulative):
      - exact name match (any term equals the full name) → 200
      - name token exact match (split on `_`) → 50 per term
      - name contains term as substring → 30 per term
      - description contains term → 5 per term
      - +require keyword present → mandatory or score is 0
    """
    name = tool.get("name", "").lower()
    desc = (tool.get("description") or "").lower()
    name_tokens = set(re.split(r"[_\-\s]+", name))
    if require and require not in name and require not in desc:
        return 0
    score = 0
    for term in query_terms:
        term = term.lower()
        if not term:
            continue
        if term == name:
            score += 200
        if term in name_tokens:
            score += 50
        elif term in name:
            score += 30
        if term in desc:
            score += 5
    return score


def search(sid: str, query: str, max_results: int = DEFAULT_MAX_RESULTS) -> str:
    """Match deferred tools against query, record activations, return schema text."""
    all_tools = _load_all_tools()
    deferred = [t for t in all_tools if is_deferred(t)]
    active = _load_active(sid)

    q = (query or "").strip()
    matched: list = []

    if q.startswith("select:"):
        wanted = {n.strip() for n in q[7:].split(",") if n.strip()}
        # Exact selection across ALL tools (including non-deferred — useful for
        # re-fetching a schema by exact name). Most calls hit deferred.
        by_name = {t.get("name"): t for t in all_tools}
        for name in wanted:
            if name in by_name:
                matched.append(by_name[name])
    else:
        require = None
        terms = []
        for tok in q.split():
            if tok.startswith("+") and len(tok) > 1:
                require = tok[1:].lower()
                terms.append(tok[1:])
            else:
                terms.append(tok)
        if not terms:
            # Empty query → return the full deferred list (names + descs only)
            lines = ["No query given. Here are all deferred tools available:\n"]
            for t in deferred:
                if t.get("name") not in active:
                    lines.append(f"- `{t.get('name','?')}` — {t.get('description','')[:120]}")
            return "\n".join(lines) if len(lines) > 1 else "All deferred tools are already loaded."
        scored = [(t, _score(t, terms, require)) for t in deferred]
        scored = [(t, s) for t, s in scored if s > 0]
        scored.sort(key=lambda x: -x[1])
        matched = [t for t, _ in scored[:max_results]]

    if not matched:
        return f"No deferred tools matched query: {q!r}. Use `list-deferred` to see candidates."

    # Record activations so 16_api.sh includes these in the next payload.
    for t in matched:
        if t.get("name"):
            active.add(t["name"])
    _save_active(sid, active)

    out = [
        f"Loaded {len(matched)} tool schema(s) for this session. "
        f"You can now call them by name exactly like any tool above.\n",
        "<functions>",
    ]
    for t in matched:
        out.append(json.dumps(_strip(t)))
    out.append("</functions>")
    return "\n".join(out)


def list_deferred_names(sid: str) -> str:
    """List deferred tools NOT yet loaded in this session — one per line."""
    active = _load_active(sid)
    lines = []
    for t in _load_all_tools():
        if is_deferred(t) and t.get("name") not in active:
            n = t.get("name", "")
            desc = (t.get("description") or "").split(".")[0][:80]
            lines.append(f"- `{n}` — {desc}")
    return "\n".join(lines)


def list_active(sid: str) -> str:
    return "\n".join(sorted(_load_active(sid)))


def active_json(sid: str) -> str:
    """JSON array of active tool names. Consumed by 16_api.sh."""
    return json.dumps(sorted(_load_active(sid)))


def clear_active(sid: str) -> None:
    try:
        os.remove(_active_path(sid))
    except FileNotFoundError:
        pass


def _cli():
    if len(sys.argv) < 2:
        sys.exit(
            "usage: tool_search.py <search|list-deferred|list-active|active-json|clear> ..."
        )
    cmd = sys.argv[1]
    if cmd == "search":
        sid = sys.argv[2]
        query = " ".join(sys.argv[3:])
        print(search(sid, query))
    elif cmd == "list-deferred":
        print(list_deferred_names(sys.argv[2]))
    elif cmd == "list-active":
        print(list_active(sys.argv[2]))
    elif cmd == "active-json":
        print(active_json(sys.argv[2]))
    elif cmd == "clear":
        clear_active(sys.argv[2])
    else:
        sys.exit(f"unknown subcommand: {cmd}")


if __name__ == "__main__":
    _cli()
