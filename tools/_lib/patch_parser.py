"""V4A patch format parser and applier.

Adapted from hermes-agent/tools/patch_parser.py.

The V4A format supports multi-file, multi-hunk patches in a single string:

    *** Begin Patch
    *** Update File: path/to/file.py
    @@ optional context hint @@
     unchanged context line (space prefix)
    -removed line
    +added line
    *** Add File: path/new.py
    +line 1
    +line 2
    *** Delete File: path/old.py
    *** Move File: src.py -> dst.py
    *** End Patch

Two-phase: validate ALL operations first; if any fail, NO files are touched.
"""

import difflib
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, List, Optional, Tuple


class OpType(Enum):
    ADD = "add"
    UPDATE = "update"
    DELETE = "delete"
    MOVE = "move"


@dataclass
class HunkLine:
    prefix: str          # ' ', '-', '+'
    content: str


@dataclass
class Hunk:
    context_hint: Optional[str] = None
    lines: List[HunkLine] = field(default_factory=list)


@dataclass
class Op:
    operation: OpType
    file_path: str
    new_path: Optional[str] = None
    hunks: List[Hunk] = field(default_factory=list)


@dataclass
class FileOps:
    """Pluggable file backend. Caller wires read/write/delete/move/validator."""
    read: Callable[[str], Tuple[Optional[str], Optional[str]]]   # (content, error)
    write: Callable[[str, str], Optional[str]]                   # err or None
    delete: Callable[[str], Optional[str]]
    move: Callable[[str, str], Optional[str]]
    exists: Callable[[str], bool]
    validate_path: Callable[[str], Optional[str]]                # err or None
    validate_syntax: Optional[Callable[[str, str], Optional[str]]] = None  # (path, content) -> err


def parse_v4a_patch(patch_content: str) -> Tuple[List[Op], Optional[str]]:
    """Parse a V4A patch. Returns (operations, error)."""
    lines = patch_content.split("\n")
    operations: List[Op] = []

    start_idx = end_idx = None
    for i, ln in enumerate(lines):
        if "*** Begin Patch" in ln or "***Begin Patch" in ln:
            start_idx = i
        elif "*** End Patch" in ln or "***End Patch" in ln:
            end_idx = i
            break
    if start_idx is None:
        start_idx = -1
    if end_idx is None:
        end_idx = len(lines)

    cur_op: Optional[Op] = None
    cur_hunk: Optional[Hunk] = None

    def _flush():
        nonlocal cur_hunk
        if cur_op and cur_hunk and cur_hunk.lines:
            cur_op.hunks.append(cur_hunk)
        cur_hunk = None

    i = start_idx + 1
    while i < end_idx:
        ln = lines[i]
        m_upd = re.match(r"\*\*\*\s*Update\s+File:\s*(.+)", ln)
        m_add = re.match(r"\*\*\*\s*Add\s+File:\s*(.+)", ln)
        m_del = re.match(r"\*\*\*\s*Delete\s+File:\s*(.+)", ln)
        m_mov = re.match(r"\*\*\*\s*Move\s+File:\s*(.+?)\s*->\s*(.+)", ln)

        if m_upd:
            _flush()
            if cur_op:
                operations.append(cur_op)
            cur_op = Op(OpType.UPDATE, m_upd.group(1).strip())
        elif m_add:
            _flush()
            if cur_op:
                operations.append(cur_op)
            cur_op = Op(OpType.ADD, m_add.group(1).strip())
            cur_hunk = Hunk()
        elif m_del:
            _flush()
            if cur_op:
                operations.append(cur_op)
            operations.append(Op(OpType.DELETE, m_del.group(1).strip()))
            cur_op = None
        elif m_mov:
            _flush()
            if cur_op:
                operations.append(cur_op)
            operations.append(Op(OpType.MOVE, m_mov.group(1).strip(),
                                 new_path=m_mov.group(2).strip()))
            cur_op = None
        elif ln.startswith("@@"):
            if cur_op:
                _flush()
                hint_match = re.match(r"@@\s*(.+?)\s*@@", ln)
                cur_hunk = Hunk(context_hint=hint_match.group(1) if hint_match else None)
        elif cur_op and ln:
            if cur_hunk is None:
                cur_hunk = Hunk()
            if ln.startswith("+"):
                cur_hunk.lines.append(HunkLine("+", ln[1:]))
            elif ln.startswith("-"):
                cur_hunk.lines.append(HunkLine("-", ln[1:]))
            elif ln.startswith(" "):
                cur_hunk.lines.append(HunkLine(" ", ln[1:]))
            elif ln.startswith("\\"):
                pass  # \ No newline at end of file
            else:
                cur_hunk.lines.append(HunkLine(" ", ln))
        i += 1

    if cur_op:
        if cur_hunk and cur_hunk.lines:
            cur_op.hunks.append(cur_hunk)
        operations.append(cur_op)

    if not operations:
        return [], None

    errs = []
    for op in operations:
        if not op.file_path:
            errs.append("Operation with empty file path")
        if op.operation == OpType.UPDATE and not op.hunks:
            errs.append(f"UPDATE {op.file_path!r}: no hunks found")
        if op.operation == OpType.MOVE and not op.new_path:
            errs.append(f"MOVE {op.file_path!r}: missing destination ('src -> dst')")
    if errs:
        return [], "Parse error: " + "; ".join(errs)
    return operations, None


def _count_occurrences(text, pattern):
    if not pattern:
        return 0
    n, i = 0, 0
    while True:
        i = text.find(pattern, i)
        if i == -1:
            return n
        n += 1
        i += len(pattern)


def validate(operations: List[Op], ops: FileOps) -> List[str]:
    """Phase 1: simulate every op against current files; return list of errors."""
    from tools._lib.fuzzy_match import fuzzy_find_and_replace, format_no_match_hint
    errors: List[str] = []

    for op in operations:
        path_err = ops.validate_path(op.file_path)
        if path_err:
            errors.append(f"{op.file_path}: {path_err}")
            continue
        if op.new_path:
            np_err = ops.validate_path(op.new_path)
            if np_err:
                errors.append(f"{op.new_path}: {np_err}")
                continue

        if op.operation == OpType.UPDATE:
            content, err = ops.read(op.file_path)
            if err:
                errors.append(f"{op.file_path}: {err}")
                continue
            simulated = content
            for hunk in op.hunks:
                search_lines = [l.content for l in hunk.lines if l.prefix in (" ", "-")]
                if not search_lines:
                    if hunk.context_hint:
                        n = _count_occurrences(simulated, hunk.context_hint)
                        if n == 0:
                            errors.append(
                                f"{op.file_path}: addition hunk hint "
                                f"'{hunk.context_hint}' not found")
                        elif n > 1:
                            errors.append(
                                f"{op.file_path}: addition hunk hint "
                                f"'{hunk.context_hint}' is ambiguous ({n} matches)")
                    continue
                pat = "\n".join(search_lines)
                rep_lines = [l.content for l in hunk.lines if l.prefix in (" ", "+")]
                rep = "\n".join(rep_lines)
                new_sim, count, _strat, mer = fuzzy_find_and_replace(
                    simulated, pat, rep, replace_all=False)
                if count == 0:
                    label = f"'{hunk.context_hint}'" if hunk.context_hint else "(no hint)"
                    msg = f"{op.file_path}: hunk {label} not found"
                    if mer:
                        msg += f" — {mer}"
                    msg += format_no_match_hint(mer, count, pat, simulated)
                    errors.append(msg)
                else:
                    simulated = new_sim

        elif op.operation == OpType.ADD:
            if ops.exists(op.file_path):
                errors.append(f"{op.file_path}: ADD target already exists")

        elif op.operation == OpType.DELETE:
            if not ops.exists(op.file_path):
                errors.append(f"{op.file_path}: DELETE target does not exist")

        elif op.operation == OpType.MOVE:
            if not ops.exists(op.file_path):
                errors.append(f"{op.file_path}: MOVE source does not exist")
            if op.new_path and ops.exists(op.new_path):
                errors.append(f"{op.new_path}: MOVE destination already exists")

    return errors


def apply(operations: List[Op], ops: FileOps) -> dict:
    """Phase 2: apply pre-validated ops. Returns summary dict."""
    from tools._lib.fuzzy_match import fuzzy_find_and_replace

    modified, created, deleted, moved = [], [], [], []
    diffs = []
    errors = []

    for op in operations:
        try:
            if op.operation == OpType.ADD:
                content_lines = [l.content for h in op.hunks for l in h.lines if l.prefix == "+"]
                content = "\n".join(content_lines)
                err = ops.write(op.file_path, content)
                if err:
                    errors.append(f"ADD {op.file_path}: {err}")
                else:
                    if ops.validate_syntax:
                        serr = ops.validate_syntax(op.file_path, content)
                        if serr:
                            ops.delete(op.file_path)
                            errors.append(f"ADD {op.file_path} reverted: syntax error: {serr}")
                            continue
                    created.append(op.file_path)
                    diffs.append(_format_add_diff(op.file_path, content_lines))

            elif op.operation == OpType.DELETE:
                old, rerr = ops.read(op.file_path)
                if rerr:
                    errors.append(f"DELETE {op.file_path}: {rerr}")
                    continue
                err = ops.delete(op.file_path)
                if err:
                    errors.append(f"DELETE {op.file_path}: {err}")
                else:
                    deleted.append(op.file_path)
                    diffs.append("".join(difflib.unified_diff(
                        (old or "").splitlines(keepends=True), [],
                        fromfile=f"a/{op.file_path}", tofile="/dev/null")))

            elif op.operation == OpType.MOVE:
                err = ops.move(op.file_path, op.new_path)
                if err:
                    errors.append(f"MOVE {op.file_path}: {err}")
                else:
                    moved.append(f"{op.file_path} -> {op.new_path}")

            elif op.operation == OpType.UPDATE:
                content, rerr = ops.read(op.file_path)
                if rerr:
                    errors.append(f"UPDATE {op.file_path}: {rerr}")
                    continue
                original = content
                for hunk in op.hunks:
                    search_lines = [l.content for l in hunk.lines if l.prefix in (" ", "-")]
                    rep_lines = [l.content for l in hunk.lines if l.prefix in (" ", "+")]
                    if not search_lines:
                        # Insert-only after context hint
                        insert = "\n".join(rep_lines)
                        if hunk.context_hint and hunk.context_hint in content:
                            pos = content.find(hunk.context_hint)
                            eol = content.find("\n", pos)
                            if eol != -1:
                                content = content[:eol + 1] + insert + "\n" + content[eol + 1:]
                            else:
                                content = content + "\n" + insert
                        else:
                            content = content.rstrip("\n") + "\n" + insert + "\n"
                        continue
                    pat = "\n".join(search_lines)
                    rep = "\n".join(rep_lines)
                    new_content, count, _, mer = fuzzy_find_and_replace(
                        content, pat, rep, replace_all=False)
                    if count == 0:
                        errors.append(f"UPDATE {op.file_path}: apply-phase miss: {mer}")
                        break
                    content = new_content
                else:
                    if ops.validate_syntax:
                        serr = ops.validate_syntax(op.file_path, content)
                        if serr:
                            errors.append(f"UPDATE {op.file_path} skipped: syntax error: {serr}")
                            continue
                    werr = ops.write(op.file_path, content)
                    if werr:
                        errors.append(f"UPDATE {op.file_path}: {werr}")
                    else:
                        modified.append(op.file_path)
                        diffs.append("".join(difflib.unified_diff(
                            original.splitlines(keepends=True),
                            content.splitlines(keepends=True),
                            fromfile=f"a/{op.file_path}",
                            tofile=f"b/{op.file_path}")))
        except Exception as e:
            errors.append(f"{op.file_path}: {type(e).__name__}: {e}")

    return {
        "ok": not errors,
        "modified": modified,
        "created": created,
        "deleted": deleted,
        "moved": moved,
        "diff": "\n".join(d for d in diffs if d),
        "errors": errors,
    }


def _format_add_diff(path, lines):
    head = f"--- /dev/null\n+++ b/{path}\n"
    return head + "\n".join(f"+{l}" for l in lines)
