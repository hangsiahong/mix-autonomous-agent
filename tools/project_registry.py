#!/usr/bin/env python3
"""
Project registry — persistent map of project names → paths + metadata.
Stored in brain/state/projects.json. Used by the agent to remember where
real workspaces live across sessions without relying on volatile memory.

Usage:
  python3 tools/project_registry.py list
  python3 tools/project_registry.py add <name> <path> [stack] [description]
  python3 tools/project_registry.py get <name>
  python3 tools/project_registry.py remove <name>
  python3 tools/project_registry.py touch <name>          # update last_active
"""
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

_DIR = Path(__file__).parent.parent
REGISTRY = _DIR / "brain" / "state" / "projects.json"


def _load() -> dict:
    if REGISTRY.exists():
        try:
            return json.loads(REGISTRY.read_text())
        except Exception:
            return {}
    return {}


def _save(data: dict):
    REGISTRY.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY.write_text(json.dumps(data, indent=2))


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def cmd_list():
    data = _load()
    if not data:
        print("No projects registered. Use: project_registry.py add <name> <path>")
        return
    for name, info in sorted(data.items()):
        path = info.get("path", "?")
        stack = info.get("stack", "")
        desc = info.get("description", "")
        active = info.get("last_active", info.get("created", "?"))
        exists = "✓" if os.path.isdir(path) else "✗ (missing)"
        line = f"{name}: {path} [{exists}]"
        if stack:
            line += f"  stack={stack}"
        if desc:
            line += f"  — {desc}"
        line += f"  last_active={active}"
        print(line)


def cmd_add(name: str, path: str, stack: str = "", description: str = ""):
    path = os.path.expanduser(path)
    if not os.path.isabs(path):
        workspace = os.environ.get("WORKSPACE_DIR", "")
        if workspace:
            path = os.path.join(workspace, path)
        else:
            print(f"Error: path must be absolute or WORKSPACE_DIR must be set.")
            sys.exit(1)
    data = _load()
    data[name] = {
        "path": path,
        "stack": stack,
        "description": description,
        "created": _now(),
        "last_active": _now(),
    }
    _save(data)
    print(f"Registered: {name} → {path}")


def cmd_get(name: str):
    data = _load()
    if name not in data:
        print(f"Project '{name}' not found.")
        sys.exit(1)
    info = data[name]
    for k, v in info.items():
        print(f"{k}: {v}")


def cmd_remove(name: str):
    data = _load()
    if name not in data:
        print(f"Project '{name}' not found.")
        sys.exit(1)
    del data[name]
    _save(data)
    print(f"Removed: {name}")


def cmd_touch(name: str):
    data = _load()
    if name in data:
        data[name]["last_active"] = _now()
        _save(data)


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args or args[0] == "list":
        cmd_list()
    elif args[0] == "add" and len(args) >= 3:
        cmd_add(args[1], args[2], args[3] if len(args) > 3 else "", args[4] if len(args) > 4 else "")
    elif args[0] == "get" and len(args) >= 2:
        cmd_get(args[1])
    elif args[0] == "remove" and len(args) >= 2:
        cmd_remove(args[1])
    elif args[0] == "touch" and len(args) >= 2:
        cmd_touch(args[1])
    else:
        print(__doc__)
        sys.exit(1)
