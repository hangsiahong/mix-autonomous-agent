"""File backend implementing the FileOps protocol for AMA's project root.

Wraps `path_safety` checks and a `bash -n` / `python -c` syntax validator so
that every write goes through the same gate.
"""

import os
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Tuple

from tools._lib.patch_parser import FileOps
from tools._lib.path_safety import (
    check_sensitive_path,
    is_blocked_device,
    validate_within_root,
)


def _validate_path_factory(roots: list):
    """Allow writes within any of the provided roots (harness root + WORKSPACE_DIR)."""
    def _v(p: str) -> Optional[str]:
        if is_blocked_device(p):
            return f"Refusing to touch device file: {p}"
        sens = check_sensitive_path(p)
        if sens:
            return sens
        for root in roots:
            _, err = validate_within_root(p, root)
            if err is None:
                return None
        # Report error against primary root for clarity
        _, err = validate_within_root(p, roots[0])
        return err
    return _v


def _read(p: str) -> Tuple[Optional[str], Optional[str]]:
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            return f.read(), None
    except FileNotFoundError:
        return None, "file not found"
    except (OSError, UnicodeError) as e:
        return None, f"{type(e).__name__}: {e}"


def _write(p: str, content: str) -> Optional[str]:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(p)) or ".", exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(content)
        return None
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _delete(p: str) -> Optional[str]:
    try:
        os.remove(p)
        return None
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _move(src: str, dst: str) -> Optional[str]:
    try:
        os.makedirs(os.path.dirname(os.path.abspath(dst)) or ".", exist_ok=True)
        shutil.move(src, dst)
        return None
    except OSError as e:
        return f"{type(e).__name__}: {e}"


def _exists(p: str) -> bool:
    return os.path.exists(p)


def _validate_syntax(path: str, content: str) -> Optional[str]:
    """Best-effort syntax check based on extension. Returns error or None."""
    suffix = Path(path).suffix.lower()
    try:
        if suffix == ".sh" or suffix == ".bash":
            r = subprocess.run(
                ["bash", "-n", "-"], input=content, text=True,
                capture_output=True, timeout=5,
            )
            if r.returncode != 0:
                return (r.stderr or r.stdout or "bash syntax error").strip()
        elif suffix == ".py":
            r = subprocess.run(
                ["python3", "-c", "import sys, ast; ast.parse(sys.stdin.read())"],
                input=content, text=True, capture_output=True, timeout=5,
            )
            if r.returncode != 0:
                return (r.stderr or r.stdout or "python syntax error").strip()
        elif suffix == ".json":
            import json
            try:
                json.loads(content)
            except json.JSONDecodeError as e:
                return f"json: {e}"
    except (OSError, subprocess.TimeoutExpired) as e:
        # Don't block writes if the validator itself fails to run.
        return None
    return None


def make_file_ops(project_root: str, extra_roots: Optional[list] = None) -> FileOps:
    """Construct a FileOps bound to project_root plus any extra allowed roots.

    extra_roots is typically [WORKSPACE_DIR] so the agent can write to real
    project directories outside the harness without going through bash only.
    """
    all_roots = [project_root] + [r for r in (extra_roots or []) if r]
    return FileOps(
        read=_read,
        write=_write,
        delete=_delete,
        move=_move,
        exists=_exists,
        validate_path=_validate_path_factory(all_roots),
        validate_syntax=_validate_syntax,
    )
