#!/usr/bin/env python3
"""
tools/janitor.py — Periodic cleanup so AMA doesn't accumulate bloat.

Idempotent — safe to run on every cron tick. Each sweep operation is
independent; failures in one don't block the others. Conservative TTL
defaults; override via env vars (listed below).

Sweeps (each can be disabled with the matching `--skip-*` flag):
  logs     JSONL/log rotation — keep last N lines per known log file
  audit    distill_audit/ — files older than DISTILL_AUDIT_TTL_DAYS
  cache    delegate_cache/ — files older than DELEGATE_CACHE_TTL_HOURS
  archives sessions/ archived histories — files older than SESSION_ARCHIVE_TTL_DAYS
  state    per-session leftover state files for sessions inactive > SESSION_STATE_TTL_DAYS
  locks    locks/*.lock for sessions with no live PID, older than 1 day
  memory   LanceDB prune for vectors unused > MEMORY_PRUNE_DAYS (calls memory_helper)

Defaults (env overrides):
  DISTILL_AUDIT_TTL_DAYS=7      DELEGATE_CACHE_TTL_HOURS=24
  SESSION_ARCHIVE_TTL_DAYS=90   SESSION_STATE_TTL_DAYS=30
  MEMORY_PRUNE_DAYS=60

CLI:
    python3 tools/janitor.py sweep             # do everything
    python3 tools/janitor.py sweep --dry-run   # show what WOULD be removed
    python3 tools/janitor.py report            # summary only, no removal
    python3 tools/janitor.py sweep --skip-memory --skip-archives

Killswitch: AMA_JANITOR_DISABLED=1 makes the whole script no-op.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent

# ── TTLs (env overrides) ──────────────────────────────────────────────────────
TTL_AUDIT_DAYS     = int(os.environ.get("DISTILL_AUDIT_TTL_DAYS", "7"))
TTL_CACHE_HOURS    = int(os.environ.get("DELEGATE_CACHE_TTL_HOURS", "24"))
TTL_ARCHIVE_DAYS   = int(os.environ.get("SESSION_ARCHIVE_TTL_DAYS", "90"))
TTL_STATE_DAYS     = int(os.environ.get("SESSION_STATE_TTL_DAYS", "30"))
TTL_LOCK_HOURS     = int(os.environ.get("LOCK_TTL_HOURS", "24"))
TTL_MEMORY_DAYS    = int(os.environ.get("MEMORY_PRUNE_DAYS", "60"))

# ── JSONL rotation targets — keep last N lines ────────────────────────────────
# Bigger keep counts for high-signal logs (errors, recaps); smaller for noisy ones.
ROTATE_TARGETS = {
    "brain/state/error_log.jsonl":          5000,
    "brain/state/tool_usage.jsonl":         5000,
    "brain/state/usage_log.jsonl":          5000,
    "brain/state/session_recaps.jsonl":     500,    # each entry is a paragraph
    "brain/state/self_heal_log.jsonl":      1000,
    "brain/state/memory_critic.log":        5000,
    "brain/state/mix_call_usage.jsonl":     5000,
    "brain/state/learning_examples.jsonl":  5000,
    "brain/state/trajectories.jsonl":       2000,
    "brain/state/access_control.log":       2000,
    "brain/state/cron.log":                 2000,
    "logs/bot.log":                         10000,
    "logs/curator.log":                     1000,
    "logs/scheduler_debug.log":             2000,
}

# Per-session state files that should be cleaned when the matching session is
# inactive (history file mtime > TTL_STATE_DAYS). The pattern captures the sid.
# Format: list of (file_glob, sid_extract_regex). The history_<sid>.json file
# itself is NEVER deleted by us — that's the canonical record.
SESSION_LEFTOVERS = [
    ("citation_warnings_*.json",  r"citation_warnings_(.+)\.json"),
    ("voice_warnings_*.json",     r"voice_warnings_(.+)\.json"),
    ("budget_*.json",             r"budget_(.+)\.json"),
    ("clarify_*.json",            r"clarify_(.+)\.json"),
    ("active_tools_*.json",       r"active_tools_(.+)\.json"),
    ("prefetch_*",                r"prefetch_(.+)"),
    ("model_*",                   r"model_(.+)"),
    ("queue_*",                   r"queue_(.+)"),
    ("steer_*",                   r"steer_(.+)"),
    ("history_*_sched_*.json",    r"history_(.+_sched_\d+)\.json"),  # scheduled forks
]


# ── Helpers ───────────────────────────────────────────────────────────────────


def _fmt_bytes(n: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}" if unit != "B" else f"{n}B"
        n /= 1024
    return f"{n:.1f}TB"


class Report:
    def __init__(self):
        self.actions: list[str] = []
        self.bytes_freed = 0
        self.errors: list[str] = []

    def note(self, msg: str) -> None:
        self.actions.append(msg)

    def freed(self, n: int) -> None:
        self.bytes_freed += max(0, int(n))

    def error(self, msg: str) -> None:
        self.errors.append(msg)


# ── Sweeps ────────────────────────────────────────────────────────────────────


def sweep_logs(rep: Report, dry: bool) -> None:
    for rel, keep in ROTATE_TARGETS.items():
        path = DIR / rel
        if not path.exists():
            continue
        try:
            with path.open("rb") as f:
                size_before = path.stat().st_size
                lines = f.readlines()
        except Exception as e:
            rep.error(f"{rel}: read failed ({e})")
            continue
        if len(lines) <= keep:
            continue
        kept = lines[-keep:]
        if dry:
            rep.note(f"[dry] rotate {rel}: {len(lines)}→{keep} lines")
            continue
        try:
            tmp = path.with_suffix(path.suffix + ".tmp")
            with tmp.open("wb") as f:
                f.writelines(kept)
            tmp.replace(path)
            size_after = path.stat().st_size
            rep.freed(size_before - size_after)
            rep.note(f"rotated {rel}: {len(lines)}→{keep} lines (-{_fmt_bytes(size_before - size_after)})")
        except Exception as e:
            rep.error(f"{rel}: rotate failed ({e})")


def _sweep_dir_by_mtime(rep: Report, dry: bool, rel: str, ttl_seconds: int, label: str) -> None:
    d = DIR / rel
    if not d.is_dir():
        return
    cutoff = time.time() - ttl_seconds
    removed = 0
    bytes_freed = 0
    for child in d.iterdir():
        if not child.is_file():
            continue
        try:
            mtime = child.stat().st_mtime
            if mtime >= cutoff:
                continue
            size = child.stat().st_size
            if dry:
                rep.note(f"[dry] {label}: would remove {child.name} ({_fmt_bytes(size)})")
                continue
            child.unlink()
            removed += 1
            bytes_freed += size
        except Exception as e:
            rep.error(f"{label}: {child.name}: {e}")
    if removed:
        rep.freed(bytes_freed)
        rep.note(f"{label}: removed {removed} files (-{_fmt_bytes(bytes_freed)})")


def sweep_audit(rep: Report, dry: bool) -> None:
    _sweep_dir_by_mtime(rep, dry, "brain/state/distill_audit",
                        TTL_AUDIT_DAYS * 86400, "distill_audit")


def sweep_cache(rep: Report, dry: bool) -> None:
    _sweep_dir_by_mtime(rep, dry, "brain/state/delegate_cache",
                        TTL_CACHE_HOURS * 3600, "delegate_cache")


def sweep_archives(rep: Report, dry: bool) -> None:
    _sweep_dir_by_mtime(rep, dry, "brain/state/sessions",
                        TTL_ARCHIVE_DAYS * 86400, "archived sessions")


def sweep_state(rep: Report, dry: bool) -> None:
    """
    Delete per-session leftover files for sessions whose history file is older
    than TTL_STATE_DAYS (or whose history file is missing entirely — orphan).
    The history file itself is NEVER deleted by this sweep.
    """
    state_dir = DIR / "brain" / "state"
    if not state_dir.is_dir():
        return
    cutoff = time.time() - TTL_STATE_DAYS * 86400

    # Build session activity index: sid → most-recent mtime across history files
    sid_mtime: dict[str, float] = {}
    for hf in state_dir.glob("history_*.json"):
        m = re.match(r"history_(.+)\.json$", hf.name)
        if not m:
            continue
        sid = m.group(1)
        try:
            mt = hf.stat().st_mtime
            if mt > sid_mtime.get(sid, 0):
                sid_mtime[sid] = mt
        except Exception:
            pass

    removed = 0
    bytes_freed = 0
    for glob_pat, sid_regex in SESSION_LEFTOVERS:
        for f in state_dir.glob(glob_pat):
            m = re.match(sid_regex, f.name)
            if not m:
                continue
            sid = m.group(1)
            # If we have history mtime for this sid AND it's recent, skip
            if sid in sid_mtime and sid_mtime[sid] >= cutoff:
                continue
            # No history file OR history is stale → safe to remove leftover.
            # Additional guard: don't remove if there's a live run pid for this sid.
            if (state_dir / f"run_{sid}.pid").exists():
                continue
            try:
                size = f.stat().st_size
                if dry:
                    rep.note(f"[dry] state: would remove {f.name} (stale sid {sid}, {_fmt_bytes(size)})")
                    continue
                f.unlink()
                removed += 1
                bytes_freed += size
            except Exception as e:
                rep.error(f"state {f.name}: {e}")
    if removed:
        rep.freed(bytes_freed)
        rep.note(f"state leftovers: removed {removed} files (-{_fmt_bytes(bytes_freed)})")


def sweep_locks(rep: Report, dry: bool) -> None:
    """
    Lock files don't strictly NEED removal (flock auto-releases), but the
    files accumulate. Remove locks older than TTL_LOCK_HOURS for sessions
    with no live PID.
    """
    lock_dir = DIR / "brain" / "state" / "locks"
    if not lock_dir.is_dir():
        return
    cutoff = time.time() - TTL_LOCK_HOURS * 3600
    removed = 0
    for lf in lock_dir.glob("*.lock"):
        try:
            if lf.stat().st_mtime >= cutoff:
                continue
            sid = lf.stem
            if (DIR / "brain" / "state" / f"run_{sid}.pid").exists():
                continue
            if dry:
                rep.note(f"[dry] locks: would remove {lf.name}")
                continue
            lf.unlink()
            removed += 1
        except Exception as e:
            rep.error(f"locks {lf.name}: {e}")
    if removed:
        rep.note(f"locks: removed {removed} stale lock files")


def sweep_memory(rep: Report, dry: bool) -> None:
    """LanceDB vector prune via memory_helper.py."""
    cmd = ["python3", str(DIR / "tools" / "memory_helper.py"), "prune", "--days", str(TTL_MEMORY_DAYS)]
    if dry:
        cmd.append("--dry-run")
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, cwd=str(DIR))
        out = (proc.stdout + proc.stderr).strip()
        if out:
            rep.note(f"memory: {out.splitlines()[-1]}")
    except subprocess.TimeoutExpired:
        rep.error("memory: prune timed out")
    except Exception as e:
        rep.error(f"memory: {e}")


def report_mode(rep: Report) -> None:
    """Sizing report — no removal."""
    state = DIR / "brain" / "state"
    total = 0
    big: list[tuple[int, str]] = []
    if state.is_dir():
        for root, _, files in os.walk(state):
            for name in files:
                p = Path(root) / name
                try:
                    sz = p.stat().st_size
                    total += sz
                    if sz >= 50 * 1024:
                        big.append((sz, str(p.relative_to(DIR))))
                except Exception:
                    pass
    rep.note(f"brain/state total: {_fmt_bytes(total)}")
    for sz, name in sorted(big, reverse=True)[:15]:
        rep.note(f"  {_fmt_bytes(sz):>10}  {name}")


# ── Entry ─────────────────────────────────────────────────────────────────────


def main() -> int:
    if os.environ.get("AMA_JANITOR_DISABLED") == "1":
        print("janitor: disabled via AMA_JANITOR_DISABLED")
        return 0

    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    sw = sub.add_parser("sweep", help="Run all enabled sweeps")
    sw.add_argument("--dry-run", action="store_true")
    sw.add_argument("--skip-logs", action="store_true")
    sw.add_argument("--skip-audit", action="store_true")
    sw.add_argument("--skip-cache", action="store_true")
    sw.add_argument("--skip-archives", action="store_true")
    sw.add_argument("--skip-state", action="store_true")
    sw.add_argument("--skip-locks", action="store_true")
    sw.add_argument("--skip-memory", action="store_true")
    sw.add_argument("--quiet", action="store_true")

    sub.add_parser("report", help="Size summary, no removal")

    args = p.parse_args()
    rep = Report()

    if args.cmd == "report":
        report_mode(rep)
    else:
        dry = bool(args.dry_run)
        if not args.skip_logs:     sweep_logs(rep, dry)
        if not args.skip_audit:    sweep_audit(rep, dry)
        if not args.skip_cache:    sweep_cache(rep, dry)
        if not args.skip_archives: sweep_archives(rep, dry)
        if not args.skip_state:    sweep_state(rep, dry)
        if not args.skip_locks:    sweep_locks(rep, dry)
        if not args.skip_memory:   sweep_memory(rep, dry)

    quiet = getattr(args, "quiet", False)
    if not quiet:
        for a in rep.actions:
            print(a)
        if rep.errors:
            print("errors:", file=sys.stderr)
            for e in rep.errors:
                print(f"  {e}", file=sys.stderr)
        if rep.bytes_freed and args.cmd == "sweep":
            print(f"\ntotal freed: {_fmt_bytes(rep.bytes_freed)}")
        if not rep.actions:
            print("janitor: nothing to do")
    return 0


if __name__ == "__main__":
    sys.exit(main())
