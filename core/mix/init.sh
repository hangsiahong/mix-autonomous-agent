#!/bin/bash
# core/mix/init.sh - Mix Engine Loader

MIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source in order
source "${MIX_DIR}/00_header.sh"

# Providers first
for f in "${MIX_DIR}/providers"/*.sh; do
    [ -f "$f" ] && source "$f"
done

source "${MIX_DIR}/01_config.sh"
source "${MIX_DIR}/../access_control.sh"
source "${MIX_DIR}/11_history.sh"
source "${MIX_DIR}/13_tool_execution.sh"
source "${MIX_DIR}/16_api.sh"
source "${MIX_DIR}/17_response_parser.sh"
source "${MIX_DIR}/18_streaming_api_call.sh"
source "${MIX_DIR}/22_process_one_tool_call.sh"
source "${MIX_DIR}/23_parallel_tools.sh"
source "${MIX_DIR}/24_agent_loop.sh"
source "${MIX_DIR}/26_reflection.sh"
source "${MIX_DIR}/27_self_heal.sh"
source "${MIX_DIR}/28_summary.sh"
source "${MIX_DIR}/29_goal_loop.sh"
source "${MIX_DIR}/30_compression.sh"
source "${MIX_DIR}/32_usage.sh"
source "${MIX_DIR}/34_error_classifier.sh"
source "${MIX_DIR}/35_provider_pool.sh"
source "${MIX_DIR}/36_think_scrubber.sh"
source "${MIX_DIR}/38_rate_limit.sh"
source "${MIX_DIR}/40_trajectory.sh"

# Recover tools.json if a crash left behind a .bak (reflection swap wasn't restored)
if [[ -f "brain/tools.json.bak" ]]; then
    _tools_count=$(python3 -c "import json; print(len(json.load(open('brain/tools.json'))))" 2>/dev/null || echo 0)
    _bak_count=$(python3 -c "import json; print(len(json.load(open('brain/tools.json.bak'))))" 2>/dev/null || echo 0)
    if [[ "$_bak_count" -gt "$_tools_count" ]]; then
        echo "AMA: Recovering tools.json from backup (reflection crash recovery)..." >&2
        mv brain/tools.json.bak brain/tools.json
    else
        rm -f brain/tools.json.bak
    fi
fi
