#!/usr/bin/env python3
# tools/skill_router.py — keyword-based auto-binding so the LLM doesn't have
# to probe skills with bash/skill_manager list calls.
#
# Usage:
#   echo "<user message>" | python3 tools/skill_router.py route [current_skill]
#     → prints best matching skill name (or empty if no strong match)
#     → exit 0 always; caller treats empty as "no change"
#
#   python3 tools/skill_router.py describe <skill_name>
#     → prints one-line description from frontmatter (or fallback)
#
#   python3 tools/skill_router.py index
#     → prints skill index block (used by 16_api.sh in place of inline Python)
import os
import re
import sys
import json

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL_ROOTS = [
    os.path.join(ROOT, "core", "skills"),
    os.path.join(ROOT, "brain", "skills"),
]


def _read_frontmatter(prompt_path):
    """Return (desc, triggers, body_first_line) from a skill prompt.md."""
    try:
        text = open(prompt_path, encoding="utf-8", errors="ignore").read()
    except Exception:
        return ("", [], "")
    desc = ""
    triggers = []
    body = text
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?", text, re.DOTALL)
    if m:
        fm = m.group(1)
        body = text[m.end():]
        d = re.search(r"^description:\s*(.+)$", fm, re.MULTILINE)
        if d:
            desc = d.group(1).strip().strip('"').strip("'")[:120]
        # YAML-ish list: "triggers: [a, b, c]" OR multi-line "- a\n- b"
        t_inline = re.search(r"^triggers:\s*\[(.*?)\]", fm, re.MULTILINE | re.DOTALL)
        if t_inline:
            triggers = [s.strip().strip('"').strip("'").lower()
                        for s in t_inline.group(1).split(",") if s.strip()]
        else:
            t_block = re.search(r"^triggers:\s*\n((?:\s*-\s*.+\n?)+)", fm, re.MULTILINE)
            if t_block:
                triggers = [re.sub(r"^\s*-\s*", "", line).strip().lower()
                            for line in t_block.group(1).splitlines() if line.strip()]
    # Body first-line fallback for description (skip code/table/ascii)
    first_line = ""
    for line in body.splitlines():
        s = line.strip()
        if not s:
            continue
        if s.startswith(("```", "---", "|", ">", "#")):
            continue
        # Skip lines that look like ASCII art / box-drawing
        if sum(1 for c in s if ord(c) > 0x2500) / max(len(s), 1) > 0.2:
            continue
        first_line = s[:120]
        break
    return (desc, triggers, first_line)


def _all_skills():
    """Yield (name, desc, triggers, source) for every installed skill."""
    seen = set()
    for base, source in [(SKILL_ROOTS[0], "core"), (SKILL_ROOTS[1], "user")]:
        if not os.path.isdir(base):
            continue
        for name in sorted(os.listdir(base)):
            if name in seen:
                continue
            prompt = os.path.join(base, name, "prompt.md")
            if not os.path.isfile(prompt):
                continue
            seen.add(name)
            desc, triggers, fallback = _read_frontmatter(prompt)
            yield (name, desc or fallback, triggers, source)


def cmd_route(msg, current_skill):
    """Pick best skill by trigger match. Return name (or '' = keep current)."""
    text = msg.lower()
    best = ("", 0)
    for name, _desc, triggers, _src in _all_skills():
        if not triggers:
            continue
        score = 0
        for kw in triggers:
            if not kw:
                continue
            # Phrase match (whitespace boundary either side)
            pattern = r"(^|[\s\W])" + re.escape(kw.lower()) + r"($|[\s\W])"
            if re.search(pattern, text):
                # Longer triggers (phrases) outweigh single short words
                score += 2 if " " in kw or len(kw) > 6 else 1
        if score > best[1]:
            best = (name, score)
    # Require at least 2 points to switch — single common word isn't enough
    if best[1] < 2:
        return ""
    # Don't re-bind the same skill
    if best[0] == current_skill:
        return ""
    return best[0]


def cmd_describe(name):
    for n, desc, triggers, _src in _all_skills():
        if n == name:
            print(desc or "(no description)")
            return
    print("")


def cmd_index():
    """Emit a compact skill index block for system prompt injection."""
    rows = list(_all_skills())
    if not rows:
        return
    print("## Available Skills")
    print("Bind with: skill_manager(action=bind, name=\"<name>\")")
    print("The router auto-binds when your message matches a skill's triggers — usually no manual call needed.")
    for name, desc, _triggers, _src in rows:
        if desc:
            print(f"  • {name} — {desc}")
        else:
            print(f"  • {name}")


def main():
    if len(sys.argv) < 2:
        print("usage: skill_router.py {route|describe <name>|index}", file=sys.stderr)
        sys.exit(2)
    cmd = sys.argv[1]
    if cmd == "route":
        current = sys.argv[2] if len(sys.argv) > 2 else ""
        msg = sys.stdin.read()
        out = cmd_route(msg, current)
        if out:
            print(out)
    elif cmd == "describe":
        cmd_describe(sys.argv[2] if len(sys.argv) > 2 else "")
    elif cmd == "index":
        cmd_index()
    else:
        sys.exit(2)


if __name__ == "__main__":
    main()
