#!/usr/bin/env python3
"""Generate tools/README.md from brain/tools.json.

Run from the repo root:
    python3 tools/_lib/gen_tool_index.py

The README is grouped by toolset (core / search / memory / meta / inspect /
media / kanban) so a new reader can see what's available at a glance, plus a
short usage paragraph and pointer to the source file for each tool.
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOLS_JSON = os.path.join(ROOT, "brain", "tools.json")
OUT = os.path.join(ROOT, "tools", "README.md")

TOOLSET_ORDER = ["core", "search", "memory", "meta", "inspect", "media", "kanban"]
TOOLSET_DESCRIPTIONS = {
    "core":    "Always loaded. The agent's bread-and-butter.",
    "search":  "Always loaded. Reach out to the web / filesystem for information.",
    "memory":  "Always loaded. Persistent + vector + session memory.",
    "meta":    "Always loaded. Tools that act on the harness itself.",
    "inspect": "On-demand (skill toolsets / TOOL_EXTRA_TOOLSETS). Heavy or specialized.",
    "media":   "On-demand. Image generation and media handling.",
    "kanban":  "On-demand. Multi-task project tracking.",
}


def main():
    with open(TOOLS_JSON) as f:
        tools = json.load(f)

    by_set = {}
    for t in tools:
        ts = t.get("toolset", "core")
        by_set.setdefault(ts, []).append(t)

    lines = []
    lines.append("# Tool Index")
    lines.append("")
    lines.append(
        "Every tool the agent can call, grouped by toolset. This file is auto-generated from "
        "[`brain/tools.json`](../brain/tools.json) — regenerate with "
        "`python3 tools/_lib/gen_tool_index.py` whenever you add or change a tool."
    )
    lines.append("")
    lines.append("Toolsets the agent loads by default come from `brain/config.json` → "
                 "`default_toolsets`. Skills can pull in additional toolsets via their own "
                 "`tools.json` (`_enabled_toolsets`).")
    lines.append("")

    for ts in TOOLSET_ORDER:
        if ts not in by_set:
            continue
        lines.append(f"## `{ts}` toolset")
        lines.append("")
        lines.append(f"_{TOOLSET_DESCRIPTIONS.get(ts, '')}_")
        lines.append("")

        for t in sorted(by_set[ts], key=lambda x: x["name"]):
            name = t["name"]
            desc = t.get("description", "")
            params = t.get("parameters", {}).get("properties", {}) or {}
            required = set(t.get("parameters", {}).get("required", []) or [])
            src = _find_source(name)

            lines.append(f"### `{name}`")
            lines.append("")
            lines.append(desc)
            lines.append("")
            if params:
                lines.append("**Parameters**")
                lines.append("")
                lines.append("| Name | Required | Description |")
                lines.append("|---|---|---|")
                for pname, pdef in params.items():
                    pdesc = (pdef.get("description") or "").replace("|", "\\|")
                    enum = pdef.get("enum")
                    if enum:
                        pdesc = f"`{' | '.join(map(str, enum))}` — {pdesc}" if pdesc else f"`{' | '.join(map(str, enum))}`"
                    lines.append(f"| `{pname}` | {'✓' if pname in required else ''} | {pdesc} |")
                lines.append("")
            if src:
                lines.append(f"**Source:** [`{src}`](../{src})")
                lines.append("")

        lines.append("")

    # Append "any extra toolsets not in the ordered list" at the end
    extras = sorted(set(by_set.keys()) - set(TOOLSET_ORDER))
    if extras:
        lines.append("## Other")
        lines.append("")
        for ts in extras:
            for t in sorted(by_set[ts], key=lambda x: x["name"]):
                lines.append(f"- **`{t['name']}`** (toolset `{ts}`) — {t.get('description', '')}")
        lines.append("")

    with open(OUT, "w") as f:
        f.write("\n".join(lines))

    print(f"Wrote {OUT} ({len(tools)} tools across {len(by_set)} toolset(s))")


def _find_source(name):
    """Find tools/<name>.sh or tools/<name>.py if it exists."""
    for ext in (".sh", ".py"):
        rel = f"tools/{name}{ext}"
        if os.path.exists(os.path.join(ROOT, rel)):
            return rel
    return None


if __name__ == "__main__":
    main()
