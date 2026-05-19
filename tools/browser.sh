#!/bin/bash
# tools/browser.sh — Playwright browser automation for JS-heavy pages.
# Inspired by hermes-agent browser_tool.py: accessibility-tree text snapshots.
#
# TOOL_action:   navigate | snapshot | click | type | scroll  (default: navigate)
# TOOL_url:      URL to navigate to (required for navigate)
# TOOL_selector: CSS selector or visible text for click/type/scroll actions
# TOOL_text:     Text to type (for type action)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

action="${TOOL_action:-navigate}"
url="${TOOL_url:-}"
selector="${TOOL_selector:-}"
text="${TOOL_text:-}"

# Validate required params
if [[ "$action" == "navigate" && -z "$url" ]]; then
    echo "Error: url is required for navigate action"
    exit 1
fi

if [[ "$action" == "click" || "$action" == "type" ]] && [[ -z "$selector" ]]; then
    echo "Error: selector is required for $action action"
    exit 1
fi

if [[ "$action" == "type" && -z "$text" ]]; then
    echo "Error: text is required for type action"
    exit 1
fi

BROWSER_ACTION="$action" \
BROWSER_URL="$url" \
BROWSER_SELECTOR="$selector" \
BROWSER_TEXT="$text" \
python3 "${DIR}/tools/_lib/browser.py"
