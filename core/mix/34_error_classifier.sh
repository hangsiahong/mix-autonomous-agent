#!/bin/bash
# core/mix/34_error_classifier.sh - API Error Classification

classify_error() {
    local status_code="$1"
    local body="$2"
    
    # Defaults
    local reason="unknown"
    local retryable="true"
    local should_compress="false"

    if [[ "$status_code" == "429" ]]; then
        reason="rate_limit"
        retryable="true"
    elif [[ "$status_code" == "401" || "$status_code" == "403" ]]; then
        reason="auth"
        retryable="false"
    elif [[ "$status_code" == "400" ]]; then
        if [[ "$body" == *"context_length"* || "$body" == *"maximum context"* || "$body" == *"too many tokens"* ]]; then
            reason="context_overflow"
            retryable="true"
            should_compress="true"
        else
            reason="bad_request"
            retryable="false"
        fi
    elif [[ "$status_code" == "413" ]]; then
        reason="payload_too_large"
        retryable="true"
        should_compress="true"
    elif [[ "$status_code" == "500" || "$status_code" == "502" || "$status_code" == "503" || "$status_code" == "504" ]]; then
        reason="server_error"
        retryable="true"
    fi

    # String matching fallback for non-standard responses
    if [[ "$reason" == "unknown" ]]; then
        local lower_body=$(echo "$body" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_body" == *"rate limit"* || "$lower_body" == *"too many requests"* ]]; then
            reason="rate_limit"
            retryable="true"
        elif [[ "$lower_body" == *"context"* && ( "$lower_body" == *"limit"* || "$lower_body" == *"exceed"* ) ]]; then
            reason="context_overflow"
            retryable="true"
            should_compress="true"
        fi
    fi

    printf '{"reason":"%s","retryable":%s,"should_compress":%s}' "$reason" "$retryable" "$should_compress"
}
