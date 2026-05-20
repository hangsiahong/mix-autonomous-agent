#!/bin/bash
# tool_search — deferred tool loader. See tools/tool_search.py for full docs.
#
# Args (TOOL_* env vars set by 13_tool_execution.sh):
#   TOOL_query        — required, search query
#   TOOL_max_results  — optional, defaults to 5
#   TOOL_SESSION_ID   — implicit, set by run_tool
#
# Output: matched tool schemas the model can read + use.
# Side effect: appends matched names to brain/state/active_tools_<sid>.json so
# 16_api.sh includes them in the next API payload.

set -e

if [[ -z "$TOOL_query" ]]; then
    echo "Error: 'query' is required. Examples: 'kanban', 'select:ast_edit,delegate', '+browser screenshot'."
    exit 1
fi

if [[ -z "$TOOL_SESSION_ID" ]]; then
    echo "Error: TOOL_SESSION_ID not set — harness bug, tool cannot resolve which session to activate tools in."
    exit 1
fi

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

# Pass query via env so quotes/specials in the query can't break the python invocation.
TS_QUERY="$TOOL_query" TS_SID="$TOOL_SESSION_ID" TS_MAX="${TOOL_max_results:-5}" python3 -c '
import os, sys
sys.path.insert(0, "tools")
from tool_search import search
print(search(os.environ["TS_SID"], os.environ["TS_QUERY"], max_results=int(os.environ["TS_MAX"])))
'
