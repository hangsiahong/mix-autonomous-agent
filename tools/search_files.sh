#!/bin/bash
# Tool: search_files
# Search for a text pattern across project files.
# Uses ripgrep (rg) when available — 10x faster than grep, respects .gitignore.
#
# Inputs:
#   TOOL_pattern     — pattern to search (required, supports regex)
#   TOOL_path        — directory or file to search (default: project root)
#   TOOL_file_glob   — filename glob, e.g. '*.py' or '*.sh' (default: all)
#   TOOL_ignore_case — case-insensitive search (default: false)

pattern="${TOOL_pattern}"
path="${TOOL_path:-.}"
file_glob="${TOOL_file_glob:-}"
ignore_case="${TOOL_ignore_case:-false}"

if [[ -z "$pattern" ]]; then
    echo "Error: pattern is required."
    exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$path")"

if [[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]]; then
    echo "Error: Access denied. Path must be within the project directory."
    exit 1
fi

# ── ripgrep path (preferred: faster, .gitignore-aware, better output) ─────────
if command -v rg >/dev/null 2>&1; then
    rg_args=("-n" "--color=never" "--no-heading" "--max-count=3")
    [[ "$ignore_case" == "true" ]] && rg_args+=("-i")
    [[ -n "$file_glob" ]] && rg_args+=("-g" "$file_glob")

    results=$(rg "${rg_args[@]}" -- "$pattern" "$RESOLVED_PATH" 2>/dev/null | head -80)

    if [[ -z "$results" ]]; then
        echo "No matches for '$pattern'."
    else
        echo "$results"
        total=$(echo "$results" | wc -l)
        echo "(${total} match(es) — use TOOL_path to narrow scope)"
    fi

# ── grep fallback ─────────────────────────────────────────────────────────────
else
    flags="-rn"
    [[ "$ignore_case" == "true" ]] && flags="$flags -i"
    [[ -n "$file_glob" ]] && include_flag="--include=$file_glob" || include_flag=""

    results=$(LC_ALL=C grep $flags $include_flag -- "$pattern" "$RESOLVED_PATH" 2>/dev/null \
        | LC_ALL=C grep -v '/\.git/' \
        | head -60)

    if [[ -z "$results" ]]; then
        echo "No matches for '$pattern'."
    else
        echo "$results"
        total=$(echo "$results" | wc -l)
        echo "(${total} match(es))"
    fi
fi
