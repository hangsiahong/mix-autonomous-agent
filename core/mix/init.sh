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
source "${MIX_DIR}/24_agent_loop.sh"
source "${MIX_DIR}/26_reflection.sh"
source "${MIX_DIR}/28_summary.sh"
source "${MIX_DIR}/30_compression.sh"
source "${MIX_DIR}/32_usage.sh"
source "${MIX_DIR}/34_error_classifier.sh"
source "${MIX_DIR}/36_think_scrubber.sh"
source "${MIX_DIR}/38_rate_limit.sh"
source "${MIX_DIR}/40_trajectory.sh"
