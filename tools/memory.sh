#!/bin/bash
# Tool: memory
# Curated file-backed memory with two stores:
#   target=memory  → brain/state/MEMORY.md  (agent's own notes, facts, learnings)
#   target=user    → brain/state/USER.md    (what you know about the user)
#
# Actions: add | replace | remove | read
# Entry delimiter: § (section sign). Each entry is one discrete fact.
# Character limits: memory=3000, user=2000. Use replace/remove to stay within limits.

action="${TOOL_action}"
target="${TOOL_target:-memory}"
content="${TOOL_content:-}"
old_text="${TOOL_old_text:-}"
new_content="${TOOL_new_content:-}"

python3 - <<PYEOF
import os, sys, re, json

action = os.environ.get("TOOL_action", "").strip()
target = os.environ.get("TOOL_target", "memory").strip().lower()
content = os.environ.get("TOOL_content", "").strip()
old_text = os.environ.get("TOOL_old_text", "").strip()
new_content_env = os.environ.get("TOOL_new_content", "").strip()

ENTRY_DELIM = "\n§\n"
STATE_DIR = "brain/state"
LIMITS = {"memory": 3000, "user": 2000}

_THREAT_PATTERNS = [
    (r'ignore\s+(previous|all|above|prior)\s+instructions', "prompt_injection"),
    (r'you\s+are\s+now\s+', "role_hijack"),
    (r'do\s+not\s+tell\s+the\s+user', "deception_hide"),
    (r'system\s+prompt\s+override', "sys_prompt_override"),
    (r'disregard\s+(your|all|any)\s+(instructions|rules|guidelines)', "disregard_rules"),
    (r'curl\s+[^\n]*\$\{?\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)', "exfil_curl"),
    (r'cat\s+[^\n]*(\.env|credentials|\.netrc|\.pgpass)', "read_secrets"),
]
_INVISIBLE = {'\u200b','\u200c','\u200d','\u2060','\ufeff','\u202a','\u202b','\u202c','\u202d','\u202e'}

def scan_content(text):
    for c in text:
        if c in _INVISIBLE:
            return f"Blocked: contains invisible unicode U+{ord(c):04X}"
    for pat, pid in _THREAT_PATTERNS:
        if re.search(pat, text, re.IGNORECASE):
            return f"Blocked: matches threat pattern '{pid}'"
    return None

def file_path(t):
    name = "MEMORY.md" if t == "memory" else "USER.md"
    return os.path.join(STATE_DIR, name)

def read_entries(t):
    path = file_path(t)
    if not os.path.exists(path):
        return []
    raw = open(path, encoding="utf-8").read().strip()
    if not raw:
        return []
    return [e.strip() for e in raw.split("§") if e.strip()]

def write_entries(t, entries):
    os.makedirs(STATE_DIR, exist_ok=True)
    path = file_path(t)
    if entries:
        text = ENTRY_DELIM.join(entries)
    else:
        text = ""
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def char_count(entries):
    if not entries:
        return 0
    return len(ENTRY_DELIM.join(entries))

if target not in ("memory", "user"):
    print(json.dumps({"success": False, "error": "target must be 'memory' or 'user'"}))
    sys.exit(0)

limit = LIMITS[target]

# ── READ ──────────────────────────────────────────────────────────────
if action == "read":
    entries = read_entries(target)
    used = char_count(entries)
    label = "MEMORY.md" if target == "memory" else "USER.md"
    if not entries:
        print(f"[{label}] Empty — no entries saved yet. Usage: 0/{limit} chars.")
    else:
        print(f"[{label}] {used}/{limit} chars, {len(entries)} entries:\n")
        for i, e in enumerate(entries, 1):
            print(f"{i}. {e}")
    sys.exit(0)

# ── ADD ───────────────────────────────────────────────────────────────
elif action == "add":
    if not content:
        print(json.dumps({"success": False, "error": "content is required for action=add"}))
        sys.exit(0)
    err = scan_content(content)
    if err:
        print(json.dumps({"success": False, "error": err}))
        sys.exit(0)
    entries = read_entries(target)
    if content in entries:
        print(json.dumps({"success": True, "message": "Entry already exists (no duplicate added).", "usage": f"{char_count(entries)}/{limit}"}))
        sys.exit(0)

    # ── Critic pass — gate the write through a cheap second model.
    # Killswitch + critic-unreachable both fail open. Rejects logged.
    import subprocess
    try:
        _proc = subprocess.run(
            ["python3", "tools/memory_critic.py", "--mode", "curated"],
            input=json.dumps({"text": content, "existing": entries, "target": target}),
            capture_output=True, text=True, timeout=25,
        )
        _verdict = json.loads((_proc.stdout or "").strip() or '{"accept":true}')
    except Exception:
        _verdict = {"accept": True, "reason": "critic invoke failed, fail open", "revised": None}
    if not _verdict.get("accept", True):
        print(json.dumps({
            "success": False,
            "error": f"Critic rejected entry: {_verdict.get('reason', 'no reason given')}",
            "hint": "Make the entry more specific or check for redundancy with existing entries.",
        }))
        sys.exit(0)
    if _verdict.get("revised"):
        content = _verdict["revised"]

    new_entries = entries + [content]
    new_total = char_count(new_entries)
    if new_total > limit:
        print(json.dumps({"success": False,
            "error": f"Memory at {char_count(entries):,}/{limit:,} chars. Adding would exceed limit ({len(content)} chars). Replace or remove entries first.",
            "current_entries": entries, "usage": f"{char_count(entries)}/{limit}"}))
        sys.exit(0)
    write_entries(target, new_entries)
    print(json.dumps({"success": True, "message": "Entry added.", "usage": f"{new_total}/{limit}", "entries": len(new_entries)}))

# ── REPLACE ───────────────────────────────────────────────────────────
elif action == "replace":
    if not old_text:
        print(json.dumps({"success": False, "error": "old_text is required for action=replace"}))
        sys.exit(0)
    if not new_content_env:
        print(json.dumps({"success": False, "error": "new_content is required for action=replace"}))
        sys.exit(0)
    err = scan_content(new_content_env)
    if err:
        print(json.dumps({"success": False, "error": err}))
        sys.exit(0)
    entries = read_entries(target)
    matches = [(i, e) for i, e in enumerate(entries) if old_text in e]
    if not matches:
        print(json.dumps({"success": False, "error": f"No entry matched '{old_text}'"}))
        sys.exit(0)
    if len(matches) > 1:
        previews = [e[:80] + ("..." if len(e) > 80 else "") for _, e in matches]
        print(json.dumps({"success": False, "error": f"Multiple entries matched '{old_text}'. Be more specific.", "matches": previews}))
        sys.exit(0)
    idx, _ = matches[0]

    # ── Critic pass — same gate as add, evaluated against entries minus the
    # one being replaced (so the critic doesn't see the new entry as a dup of
    # its predecessor). Fail-open on critic errors.
    import subprocess
    _others = [e for i, e in enumerate(entries) if i != idx]
    try:
        _proc = subprocess.run(
            ["python3", "tools/memory_critic.py", "--mode", "curated"],
            input=json.dumps({"text": new_content_env, "existing": _others, "target": target}),
            capture_output=True, text=True, timeout=25,
        )
        _verdict = json.loads((_proc.stdout or "").strip() or '{"accept":true}')
    except Exception:
        _verdict = {"accept": True, "reason": "critic invoke failed, fail open", "revised": None}
    if not _verdict.get("accept", True):
        print(json.dumps({
            "success": False,
            "error": f"Critic rejected replacement: {_verdict.get('reason', 'no reason given')}",
        }))
        sys.exit(0)
    if _verdict.get("revised"):
        new_content_env = _verdict["revised"]

    entries[idx] = new_content_env
    new_total = char_count(entries)
    if new_total > limit:
        print(json.dumps({"success": False, "error": f"Replacement would exceed char limit ({new_total}/{limit})."}))
        sys.exit(0)
    write_entries(target, entries)
    print(json.dumps({"success": True, "message": "Entry replaced.", "usage": f"{new_total}/{limit}"}))

# ── REMOVE ────────────────────────────────────────────────────────────
elif action == "remove":
    if not old_text:
        print(json.dumps({"success": False, "error": "old_text is required for action=remove"}))
        sys.exit(0)
    entries = read_entries(target)
    matches = [(i, e) for i, e in enumerate(entries) if old_text in e]
    if not matches:
        print(json.dumps({"success": False, "error": f"No entry matched '{old_text}'"}))
        sys.exit(0)
    idx = matches[0][0]
    removed = entries.pop(idx)
    write_entries(target, entries)
    print(json.dumps({"success": True, "message": f"Removed: {removed[:80]}", "usage": f"{char_count(entries)}/{limit}", "remaining": len(entries)}))

else:
    print(json.dumps({"success": False, "error": f"Unknown action '{action}'. Use: add, replace, remove, read"}))

PYEOF
