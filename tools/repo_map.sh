#!/bin/bash
# Tool: repo_map
# Smart repository orientation: file tree + symbol extraction + entry points.
# Uses rg (ripgrep) and fd for fast, .gitignore-aware results.
#
# Inputs:
#   TOOL_depth    — tree depth (default 3)
#   TOOL_path     — subtree to map (default: project root)
#   TOOL_symbols  — show function/class symbols per file (default: true)
#   TOOL_query    — focus on files matching this pattern (optional)

DEPTH="${TOOL_depth:-3}"
START_PATH="${TOOL_path:-.}"
SHOW_SYMBOLS="${TOOL_symbols:-true}"
QUERY="${TOOL_query:-}"

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

# ── File tree (fd or find) ────────────────────────────────────────────────────
echo "## Repository Map: $START_PATH"
echo ""

EXCLUDE_DIRS="node_modules|\.git|__pycache__|brain/state|\.pytest_cache|dist|build|\.next|venv|\.venv|\.mypy_cache"

if command -v fd >/dev/null 2>&1; then
    if [[ -n "$QUERY" ]]; then
        echo "### Files matching: $QUERY"
        fd --max-depth "$DEPTH" --type f -g "*${QUERY}*" "$START_PATH" \
            --exclude node_modules --exclude .git --exclude __pycache__ \
            | sort | head -50
    else
        echo "### File Tree (depth $DEPTH)"
        fd --max-depth "$DEPTH" --type f "$START_PATH" \
            --exclude node_modules --exclude .git --exclude __pycache__ \
            | sort \
            | python3 -c "
import sys
files = sys.stdin.read().strip().split('\n')
# Group by directory
from collections import defaultdict
groups = defaultdict(list)
for f in files:
    if '/' in f:
        d, name = f.rsplit('/', 1)
    else:
        d, name = '.', f
    groups[d].append(name)
for d in sorted(groups):
    print(f'{d}/')
    for n in sorted(groups[d])[:20]:
        print(f'  {n}')
" 2>/dev/null
    fi
elif command -v tree >/dev/null 2>&1; then
    tree -L "$DEPTH" --noreport -I "${EXCLUDE_DIRS//|/|}" "$START_PATH"
else
    find "$START_PATH" -maxdepth "$DEPTH" \
        -not -path '*/.git/*' -not -path '*/node_modules/*' \
        -not -path '*/__pycache__/*' -not -path '*/brain/state/*' \
        | sort | sed -e "s|[^/]*/|  |g" | head -80
fi

# ── Symbol extraction (rg-powered) ───────────────────────────────────────────
if [[ "$SHOW_SYMBOLS" == "true" ]] && command -v rg >/dev/null 2>&1; then
    echo ""
    echo "### Key Symbols"
    echo ""

    # Python: functions and classes
    PY_SYMBOLS=$(rg --type py \
        -n --no-heading \
        '^\s*(def |class |async def )(\w+)' \
        "$START_PATH" \
        --glob '!test_*' --glob '!*_test.py' \
        2>/dev/null | head -60)
    if [[ -n "$PY_SYMBOLS" ]]; then
        echo "**Python** (def/class):"
        echo "$PY_SYMBOLS" | python3 -c "
import sys, re
lines = sys.stdin.read().strip().split('\n')
by_file = {}
for line in lines:
    if ':' not in line: continue
    parts = line.split(':', 2)
    if len(parts) < 3: continue
    fpath, lineno, code = parts
    m = re.search(r'^\s*(async def |def |class )(\w+)', code)
    if m:
        kind = 'class' if 'class' in m.group(1) else 'def'
        name = m.group(2)
        if fpath not in by_file:
            by_file[fpath] = []
        by_file[fpath].append(f'{kind} {name}:{lineno}')
for fpath in sorted(by_file):
    symbols = ', '.join(by_file[fpath][:8])
    print(f'  {fpath}: {symbols}')
" 2>/dev/null
        echo ""
    fi

    # Bash: functions
    SH_SYMBOLS=$(rg --type sh \
        -n --no-heading \
        '^(\w+)\s*\(\)' \
        "$START_PATH" \
        2>/dev/null | head -40)
    if [[ -n "$SH_SYMBOLS" ]]; then
        echo "**Shell** (functions):"
        echo "$SH_SYMBOLS" | python3 -c "
import sys
lines = sys.stdin.read().strip().split('\n')
by_file = {}
for line in lines:
    if ':' not in line: continue
    parts = line.split(':', 2)
    if len(parts) < 3: continue
    fpath, lineno, code = parts
    name = code.split('(')[0].strip()
    if fpath not in by_file:
        by_file[fpath] = []
    by_file[fpath].append(f'{name}:{lineno}')
for fpath in sorted(by_file):
    symbols = ', '.join(by_file[fpath][:8])
    print(f'  {fpath}: {symbols}')
" 2>/dev/null
        echo ""
    fi

    # JS/TS: exports and functions
    JS_SYMBOLS=$(rg --type js --type ts \
        -n --no-heading \
        '^(export (default )?(function|class|const|async function)|function |class )(\w+)' \
        "$START_PATH" \
        2>/dev/null | head -40)
    if [[ -n "$JS_SYMBOLS" ]]; then
        echo "**JS/TS** (exports/functions):"
        echo "$JS_SYMBOLS" | python3 -c "
import sys, re
lines = sys.stdin.read().strip().split('\n')
by_file = {}
for line in lines:
    if ':' not in line: continue
    parts = line.split(':', 2)
    if len(parts) < 3: continue
    fpath, lineno, code = parts
    m = re.search(r'(function|class|const)\s+(\w+)', code)
    if m:
        name = m.group(2)
        if fpath not in by_file:
            by_file[fpath] = []
        by_file[fpath].append(f'{name}:{lineno}')
for fpath in sorted(by_file):
    symbols = ', '.join(by_file[fpath][:6])
    print(f'  {fpath}: {symbols}')
" 2>/dev/null
        echo ""
    fi
fi

# ── Entry points ──────────────────────────────────────────────────────────────
if command -v rg >/dev/null 2>&1; then
    echo "### Entry Points"
    # Common entry points: main files, index, bot, app, server
    rg --files "$START_PATH" 2>/dev/null \
        | rg '(^|/)(main|index|bot|app|server|entry|__main__)\.(py|sh|js|ts|go)$' \
        | sort | head -10
    echo ""
fi

echo "(tip: use search_files to find specific patterns, delegate for deep implementation)"
