#!/bin/bash
# tools/context_discovery.sh - Find and format local context hints

TARGET_PATH="$1"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVED_PATH="$(realpath -m "$TARGET_PATH")"

# Ensure we are within project root
[[ "$RESOLVED_PATH" != "$PROJECT_ROOT"* ]] && exit 0

# If path is a file, use its parent directory
DIR_PATH="$RESOLVED_PATH"
[[ -f "$RESOLVED_PATH" ]] && DIR_PATH="$(dirname "$RESOLVED_PATH")"

HINT_FILES=("README.md" "HINTS.md" ".ama-context" "AGENT.md" "SPEC.md")
FOUND_HINT=""
FOUND_PATH=""

# Walk up to 3 levels towards project root
for ((i=0; i<3; i++)); do
    [[ "$DIR_PATH" != "$PROJECT_ROOT"* ]] && break
    
    for hint in "${HINT_FILES[@]}"; do
        if [[ -f "${DIR_PATH}/${hint}" ]]; then
            # Don't return the file we are currently reading
            [[ "${DIR_PATH}/${hint}" == "$RESOLVED_PATH" ]] && continue
            
            FOUND_HINT=$(head -c 2000 "${DIR_PATH}/${hint}")
            FOUND_PATH="${DIR_PATH}/${hint}"
            break 2
        fi
    done
    
    DIR_PATH="$(dirname "$DIR_PATH")"
done

if [[ -n "$FOUND_HINT" ]]; then
    REL_PATH="${FOUND_PATH#$PROJECT_ROOT/}"
    echo -e "\n--- CONTEXT HINT ($REL_PATH) ---\n$FOUND_HINT\n--- END CONTEXT ---"
fi
