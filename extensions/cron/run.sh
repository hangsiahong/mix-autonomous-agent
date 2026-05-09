#!/bin/bash
# extensions/cron/run.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${DIR}/core/mix/00_header.sh"
source "${DIR}/core/mix/16_api.sh"
source "${DIR}/core/mix/34_error_classifier.sh"
source "${DIR}/core/mix/38_rate_limit.sh"
source "${DIR}/core/mix/01_config.sh"

echo "[$(date)] Running background maintenance..."

# 1. Check Error Log for patterns
if [[ -f "${DIR}/brain/state/error_log.jsonl" ]]; then
    ERROR_COUNT=$(tail -n 100 "${DIR}/brain/state/error_log.jsonl" | wc -l)
    if [[ "$ERROR_COUNT" -gt 50 ]]; then
        echo "High error rate detected ($ERROR_COUNT in last 100). Needs attention."
        # Maybe send alert to TG_ADMIN if home_chat set
        # This is hard since we don't have chat_id easily here
    fi
fi

# 2. Cleanup old trajectories (keep last 1000)
if [[ -f "${DIR}/brain/state/trajectories.jsonl" ]]; then
    tail -n 1000 "${DIR}/brain/state/trajectories.jsonl" > "${DIR}/brain/state/trajectories.tmp"
    mv "${DIR}/brain/state/trajectories.tmp" "${DIR}/brain/state/trajectories.jsonl"
fi

echo "[$(date)] Maintenance complete."
