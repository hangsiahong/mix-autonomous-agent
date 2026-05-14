"""Path validation and sensitive-path detection for AMA tools.

Adapted from hermes-agent/tools/path_security.py and file_tools.py.
All file-mutating tools must call validate_within_root() and check_sensitive_path().
"""

import os
from pathlib import Path
from typing import Optional, Tuple


# Sensitive system paths that no tool should ever write to.
_SENSITIVE_PREFIXES = (
    "/etc/", "/boot/", "/usr/", "/lib/", "/lib64/",
    "/sbin/", "/bin/", "/sys/", "/proc/",
    "/private/etc/", "/private/var/",
)
_SENSITIVE_EXACT = {
    "/var/run/docker.sock", "/run/docker.sock",
    "/etc/passwd", "/etc/shadow", "/etc/sudoers",
}

# Within the user's HOME, paths that often hold credentials.
_HOME_SENSITIVE_SUFFIXES = (
    "/.ssh", "/.aws", "/.gnupg", "/.docker/config.json",
    "/.netrc", "/.pgpass", "/.kube/config",
)

# Project files the agent must never overwrite directly.
# These are managed by dedicated functions/tools — direct writes corrupt state.
_AGENT_PROTECTED_SUFFIXES = (
    "brain/tools.json",    # use brain/tools_extra.json + custom_tool_manager
    "brain/config.json",   # use set_topic_config / set_group_mode / add_to_whitelist
)
_AGENT_PROTECTED_MESSAGES = {
    "brain/tools.json": (
        "Use custom_tool_manager(action=create, ...) to add tools — "
        "they go into brain/tools_extra.json which is safe to modify. "
        "Direct writes to brain/tools.json corrupt the base tool list."
    ),
    "brain/config.json": (
        "Use the config helper functions (set_topic_config, set_group_mode, "
        "add_to_whitelist) — never write brain/config.json directly."
    ),
}

# Block paths that would hang the process on read.
_BLOCKED_DEVICES = {
    "/dev/stdin", "/dev/stdout", "/dev/stderr",
    "/dev/zero", "/dev/random", "/dev/urandom",
    "/dev/tty", "/dev/null",
}


def resolve_path(filepath: str, root: Optional[str] = None) -> Path:
    """Resolve a path: expand ~, make absolute against root or cwd, follow symlinks."""
    p = Path(filepath).expanduser()
    if not p.is_absolute():
        base = Path(root) if root else Path.cwd()
        p = base / p
    return p.resolve()


def validate_within_root(filepath: str, root: str) -> Tuple[Optional[Path], Optional[str]]:
    """Ensure resolved path lies under root. Returns (resolved_path, error_msg)."""
    try:
        resolved = resolve_path(filepath, root)
        root_resolved = Path(root).resolve()
        resolved.relative_to(root_resolved)
        return resolved, None
    except (ValueError, OSError) as exc:
        return None, (
            f"Access denied: '{filepath}' resolves outside the project root "
            f"({root}). Detail: {exc}"
        )


def check_sensitive_path(filepath: str) -> Optional[str]:
    """Return error message if path targets a sensitive location, else None."""
    try:
        resolved = str(resolve_path(filepath))
    except (OSError, ValueError):
        resolved = filepath
    normalized = os.path.normpath(os.path.expanduser(filepath))

    # Block direct writes to agent-protected project files
    for suffix in _AGENT_PROTECTED_SUFFIXES:
        if resolved.endswith(suffix) or normalized.endswith(suffix):
            return _AGENT_PROTECTED_MESSAGES.get(suffix,
                f"Protected project file: {filepath}"
            )

    for prefix in _SENSITIVE_PREFIXES:
        if resolved.startswith(prefix) or normalized.startswith(prefix):
            return (
                f"Refusing to write sensitive system path: {filepath}. "
                f"Use the bash tool with explicit user approval if truly needed."
            )

    if resolved in _SENSITIVE_EXACT or normalized in _SENSITIVE_EXACT:
        return f"Refusing to write protected path: {filepath}"

    home = os.path.expanduser("~")
    for suffix in _HOME_SENSITIVE_SUFFIXES:
        target = home + suffix
        if resolved == target or resolved.startswith(target + "/"):
            return (
                f"Refusing to write into a credential directory: {filepath}. "
                f"This path commonly stores secrets."
            )

    return None


def is_blocked_device(filepath: str) -> bool:
    """True if path is a device file that would hang on read."""
    normalized = os.path.expanduser(filepath)
    if normalized in _BLOCKED_DEVICES:
        return True
    if normalized.startswith("/proc/") and normalized.endswith(("/fd/0", "/fd/1", "/fd/2")):
        return True
    return False
