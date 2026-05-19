"""Python entrypoints invoked by tools/edit_code.sh, tools/patch.sh,
tools/write_file.sh, and tools/read_code.sh.

Single Python interpreter call per tool invocation — keeps Bash thin and
the file logic well-tested. Reads JSON args from stdin, prints JSON or
plain text result to stdout. Exit code 0 on success, 1 on failure.

Usage:
    echo '{"path":"x","old_string":"a","new_string":"b"}' \\
        | python3 tools/_lib/cli.py edit
"""

import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict

# Make `tools._lib.*` importable when invoked directly.
_HERE = os.path.dirname(os.path.abspath(__file__))
_ROOT = os.path.dirname(os.path.dirname(_HERE))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)

from tools._lib.file_backend import make_file_ops  # noqa: E402
from tools._lib.fuzzy_match import (  # noqa: E402
    fuzzy_find_and_replace,
    format_no_match_hint,
)
from tools._lib.patch_parser import apply, parse_v4a_patch, validate  # noqa: E402

PROJECT_ROOT = _ROOT
MAX_READ_CHARS = 200_000  # ~50k tokens, safety cap

# WORKSPACE_DIR: second allowed root for write_file / edit_code / patch.
# Set in .env so agents can edit real project directories outside the harness.
# Must be an absolute path; ignored if empty or relative.
_workspace = os.environ.get("WORKSPACE_DIR", "").strip()
_EXTRA_ROOTS = [_workspace] if _workspace and os.path.isabs(_workspace) else []


def _err(msg: str) -> int:
    print(f"Error: {msg}", file=sys.stdout)
    return 1


def _ok(msg: str) -> int:
    print(msg)
    return 0


# ── edit_code: single-file find/replace with fuzzy matching ──────────────

def cmd_edit(args: Dict[str, Any]) -> int:
    path = args.get("path") or ""
    old = args.get("old_string", "")
    new = args.get("new_string", "")
    replace_all = bool(args.get("replace_all", False))

    if not path:
        return _err("'path' is required")
    if not old:
        return _err("'old_string' is required (use write_file to create new files)")

    backend = make_file_ops(PROJECT_ROOT, _EXTRA_ROOTS)
    perr = backend.validate_path(path)
    if perr:
        return _err(perr)

    content, rerr = backend.read(path)
    if rerr:
        return _err(f"{path}: {rerr}")

    new_content, count, strategy, ferr = fuzzy_find_and_replace(
        content, old, new, replace_all=replace_all
    )
    if count == 0:
        msg = f"{path}: {ferr or 'no match'}"
        msg += format_no_match_hint(ferr, count, old, content)
        return _err(msg)

    serr = backend.validate_syntax(path, new_content)
    if serr:
        return _err(
            f"{path}: edit rejected — would introduce a syntax error:\n{serr}\n"
            f"(strategy={strategy}, no changes written)"
        )

    werr = backend.write(path, new_content)
    if werr:
        return _err(f"{path}: write failed: {werr}")

    # Concise diff for the model
    import difflib
    diff = "".join(difflib.unified_diff(
        content.splitlines(keepends=True),
        new_content.splitlines(keepends=True),
        fromfile=f"a/{path}", tofile=f"b/{path}", n=2,
    ))
    note = ""
    if strategy != "exact":
        note = f"\n[matched via {strategy} strategy — verify the diff]"
    return _ok(f"Edited {path} ({count} replacement{'s' if count != 1 else ''}){note}\n\n{diff}")


# ── patch: V4A multi-file/multi-hunk patches ─────────────────────────────

def cmd_patch(args: Dict[str, Any]) -> int:
    patch_text = args.get("patch", "")
    if not patch_text:
        return _err("'patch' is required (V4A format)")

    operations, perr = parse_v4a_patch(patch_text)
    if perr:
        return _err(perr)
    if not operations:
        return _err("No operations found in patch")

    backend = make_file_ops(PROJECT_ROOT, _EXTRA_ROOTS)

    verrs = validate(operations, backend)
    if verrs:
        body = "\n".join(f"  • {e}" for e in verrs)
        return _err(f"Patch validation failed (no files modified):\n{body}")

    result = apply(operations, backend)
    if not result["ok"]:
        body = "\n".join(f"  • {e}" for e in result["errors"])
        return _err(f"Patch apply failed (run `git diff` to inspect):\n{body}")

    summary_parts = []
    if result["modified"]:
        summary_parts.append(f"modified: {', '.join(result['modified'])}")
    if result["created"]:
        summary_parts.append(f"created: {', '.join(result['created'])}")
    if result["deleted"]:
        summary_parts.append(f"deleted: {', '.join(result['deleted'])}")
    if result["moved"]:
        summary_parts.append(f"moved: {', '.join(result['moved'])}")
    summary = "; ".join(summary_parts) or "no-op"
    return _ok(f"Patch applied: {summary}\n\n{result['diff']}")


# ── write_file: create or overwrite ──────────────────────────────────────

def cmd_write(args: Dict[str, Any]) -> int:
    path = args.get("path") or ""
    content = args.get("content", "")
    append = bool(args.get("append", False))

    if not path:
        return _err("'path' is required")

    backend = make_file_ops(PROJECT_ROOT, _EXTRA_ROOTS)
    perr = backend.validate_path(path)
    if perr:
        return _err(perr)

    # If file exists and we're overwriting, do a syntax check on the new content
    # to catch obvious LLM mistakes before clobbering working code.
    if not append:
        serr = backend.validate_syntax(path, content)
        if serr:
            return _err(
                f"{path}: write rejected — content has a syntax error:\n{serr}"
            )

    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)) or ".", exist_ok=True)
        mode = "a" if append else "w"
        with open(path, mode, encoding="utf-8") as f:
            f.write(content)
        size = os.path.getsize(path)
        verb = "Appended to" if append else "Wrote"
        return _ok(f"{verb} {path} ({size:,} bytes)")
    except OSError as e:
        return _err(f"{path}: {type(e).__name__}: {e}")


# ── read_code: paginated read with line numbers ──────────────────────────

def cmd_read(args: Dict[str, Any]) -> int:
    path = args.get("path") or ""
    offset = int(args.get("offset", 1) or 1)
    limit = int(args.get("limit", 500) or 500)

    if not path:
        return _err("'path' is required")
    offset = max(1, offset)
    limit = max(1, min(limit, 2000))

    backend = make_file_ops(PROJECT_ROOT, _EXTRA_ROOTS)
    perr = backend.validate_path(path)
    if perr:
        return _err(perr)

    if not os.path.exists(path):
        return _err(f"{path}: file not found")
    if os.path.isdir(path):
        return _err(f"{path}: is a directory (use list_files instead)")

    try:
        size = os.path.getsize(path)
        if size > 5_000_000:
            return _err(
                f"{path}: file is {size:,} bytes — too large to read in full. "
                f"Use bash with grep/sed/head for targeted access."
            )
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            all_lines = f.readlines()
    except OSError as e:
        return _err(f"{path}: {type(e).__name__}: {e}")

    total = len(all_lines)
    end = min(offset - 1 + limit, total)
    selected = all_lines[offset - 1:end]

    width = len(str(end))
    body = "".join(
        f"{offset + i:>{width}}| {line}" if line.endswith("\n")
        else f"{offset + i:>{width}}| {line}\n"
        for i, line in enumerate(selected)
    )

    if len(body) > MAX_READ_CHARS:
        return _err(
            f"{path}: output {len(body):,} chars exceeds limit ({MAX_READ_CHARS:,}). "
            f"Narrow the read with offset/limit (file has {total} lines)."
        )

    truncated_msg = ""
    if end < total:
        truncated_msg = (
            f"\n[…truncated at line {end} of {total}; "
            f"call read_code again with offset={end + 1} to continue]"
        )

    return _ok(f"📄 {path} (lines {offset}-{end} of {total})\n{body}{truncated_msg}")


# ── dispatch ─────────────────────────────────────────────────────────────

COMMANDS = {
    "edit": cmd_edit,
    "patch": cmd_patch,
    "write": cmd_write,
    "read": cmd_read,
}


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        print(f"Usage: cli.py {{{'|'.join(COMMANDS)}}} (reads JSON args from stdin)",
              file=sys.stderr)
        return 2
    cmd = sys.argv[1]
    try:
        raw = sys.stdin.read()
        args = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError as e:
        return _err(f"invalid JSON args on stdin: {e}")
    return COMMANDS[cmd](args)


if __name__ == "__main__":
    sys.exit(main())
