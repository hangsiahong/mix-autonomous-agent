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

# 2. Cleanup log files (keep last N lines)
for logfile in "${DIR}/brain/state/trajectories.jsonl" \
               "${DIR}/brain/state/tool_usage.jsonl" \
               "${DIR}/brain/state/usage_log.jsonl" \
               "${DIR}/brain/state/error_log.jsonl"; do
    if [[ -f "$logfile" ]]; then
        local_keep=500
        [[ "$logfile" == *tool_usage* || "$logfile" == *error_log* ]] && local_keep=200
        line_count=$(wc -l < "$logfile")
        if [[ $line_count -gt $((local_keep + 100)) ]]; then
            tail -n "$local_keep" "$logfile" > "${logfile}.tmp" && mv "${logfile}.tmp" "$logfile"
            echo "[$(date)] Trimmed $logfile to $local_keep lines"
        fi
    fi
done

# 3. Monthly memory pruning — remove memories unused for 30+ days
MEMORY_PRUNE_MARKER="${DIR}/brain/state/.memory_last_pruned"
_now=$(date +%s)
_last_prune=0
if [[ -f "$MEMORY_PRUNE_MARKER" ]]; then
    _last_prune=$(cat "$MEMORY_PRUNE_MARKER" 2>/dev/null || echo 0)
fi
_days_since=$(( (_now - _last_prune) / 86400 ))
if [[ $_days_since -ge 30 ]]; then
    echo "[$(date)] Running monthly memory pruning (${_days_since} days since last prune)..."
    _prune_result=$(python3 "${DIR}/tools/memory_helper.py" prune 30 2>/dev/null)
    echo "[$(date)] $_prune_result"
    echo "$_now" > "$MEMORY_PRUNE_MARKER"
fi

echo "[$(date)] Maintenance complete."
