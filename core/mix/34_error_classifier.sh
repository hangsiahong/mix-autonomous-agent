#!/bin/bash
# core/mix/34_error_classifier.sh - API Error Classification
#
# Returns a JSON object with four fields:
#   reason          — semantic class of the error (string)
#   retryable       — whether retrying this same request could succeed (bool)
#   should_compress — caller should compress history before retrying (bool, legacy hint)
#   action          — *what to do about it* (verb, see below)
#
# Reasons / actions matrix (hermes-inspired taxonomy):
#
#   reason                 | typical status | action              | notes
#   -----------------------|----------------|---------------------|----------------------------------
#   rate_limit             | 429            | retry_after_delay   | exponential backoff
#   billing_exhausted      | 402, 429+kw    | rotate_pool         | quota out — try another key
#   auth                   | 401            | rotate_pool         | bad key — try another in pool
#   provider_policy        | 403/400+kw     | fail_user           | content blocked, tell the user
#   model_unavailable      | 404+kw         | switch_model        | bad model name — fall back
#   context_overflow       | 400+kw         | compress            | reduce history, then retry
#   payload_too_large      | 413            | compress            | same as context_overflow
#   thinking_signature     | 400+kw         | disable_thinking    | model can't handle thoughtSignature
#   cache_miss             | 400+kw         | reinline_cache      | cachedContent gone — drop ref
#   timeout                | 408            | retry_after_delay   | network/upstream slow
#   model_overloaded       | 503            | switch_model        | provider degraded, try fallback
#   server_error           | 500/502/504    | retry_after_delay   | transient infra
#   bad_request_permanent  | 400+kw         | fail                | structural — won't fix on retry
#   bad_request            | 400 (other)    | fail                | unclear; surface to user
#   unknown                | else           | retry_after_delay   | fallback
#
# Consumers (16_api.sh, 18_streaming_api_call.sh) should dispatch on `action`,
# not on `reason` — adding a new reason without a default action is a footgun.

classify_error() {
    local status_code="$1"
    local body="$2"

    local reason="unknown"
    local retryable="true"
    local should_compress="false"
    local action="retry_after_delay"

    # Lowercase body once for keyword matching
    local lb; lb=$(echo "$body" | tr '[:upper:]' '[:lower:]')

    case "$status_code" in
        429)
            # Could be true rate-limit OR quota exhaustion (some providers conflate).
            if [[ "$lb" == *"quota"* || "$lb" == *"billing"* || "$lb" == *"insufficient_quota"* || "$lb" == *"insufficient funds"* ]]; then
                reason="billing_exhausted"; action="rotate_pool"
            else
                reason="rate_limit"; action="retry_after_delay"
            fi
            retryable="true"
            ;;
        402)
            reason="billing_exhausted"; action="rotate_pool"; retryable="true"
            ;;
        401)
            # Bad/expired key — try another pool entry before giving up
            reason="auth"; action="rotate_pool"; retryable="true"
            ;;
        403)
            # 403 splits into two: policy/safety blocks (won't retry) vs auth (rotate)
            if [[ "$lb" == *"policy"* || "$lb" == *"blocked"* || "$lb" == *"safety"* || "$lb" == *"violat"* || "$lb" == *"harmful"* ]]; then
                reason="provider_policy"; action="fail_user"; retryable="false"
            else
                reason="auth"; action="rotate_pool"; retryable="true"
            fi
            ;;
        404)
            if [[ "$lb" == *"model"* && "$lb" == *"not found"* ]] || \
               [[ "$lb" == *"model "* && "$lb" == *"does not exist"* ]] || \
               [[ "$lb" == *"unknown model"* ]] || \
               [[ "$lb" == *"unsupported model"* ]]; then
                reason="model_unavailable"; action="switch_model"; retryable="true"
            else
                reason="bad_request"; action="fail"; retryable="false"
            fi
            ;;
        408)
            reason="timeout"; action="retry_after_delay"; retryable="true"
            ;;
        400)
            # Order matters: most specific keywords first.
            if [[ "$lb" == *"context_length"* || "$lb" == *"maximum context"* || "$lb" == *"too many tokens"* || "$lb" == *"context window"* ]]; then
                reason="context_overflow"; action="compress"; retryable="true"; should_compress="true"
            elif [[ "$lb" == *"thought_signature"* || "$lb" == *"thoughtsignature"* ]]; then
                # Model rejected (or required) the thoughtSignature field. Disable
                # thinking for this turn — usually clears it. See [[project_thought_signature]].
                reason="thinking_signature"; action="disable_thinking"; retryable="true"
            elif [[ "$lb" == *"cachedcontent"* || "$lb" == *"cached_content"* || "$lb" == *"cached content"* ]]; then
                reason="cache_miss"; action="reinline_cache"; retryable="true"
            elif [[ "$lb" == *"input cannot be empty"* || "$lb" == *"model input cannot be empty"* || "$lb" == *"contents cannot be empty"* ]]; then
                reason="bad_request_permanent"; action="fail"; retryable="false"
            elif [[ "$lb" == *"safety"* || "$lb" == *"blocked"* || "$lb" == *"harm_category"* || "$lb" == *"harmful"* ]]; then
                reason="provider_policy"; action="fail_user"; retryable="false"
            else
                reason="bad_request"; action="fail"; retryable="false"
            fi
            ;;
        413)
            reason="payload_too_large"; action="compress"; retryable="true"; should_compress="true"
            ;;
        500|502|504)
            reason="server_error"; action="retry_after_delay"; retryable="true"
            ;;
        503)
            # 503 from Gemini/Vertex usually means model overloaded — try fallback model
            reason="model_overloaded"; action="switch_model"; retryable="true"
            ;;
    esac

    # Keyword fallback for non-standard status codes (or when status alone wasn't decisive)
    if [[ "$reason" == "unknown" ]]; then
        if [[ "$lb" == *"rate limit"* || "$lb" == *"too many requests"* ]]; then
            reason="rate_limit"; action="retry_after_delay"; retryable="true"
        elif [[ "$lb" == *"context"* && ( "$lb" == *"limit"* || "$lb" == *"exceed"* ) ]]; then
            reason="context_overflow"; action="compress"; retryable="true"; should_compress="true"
        elif [[ "$lb" == *"thought_signature"* ]]; then
            reason="thinking_signature"; action="disable_thinking"; retryable="true"
        elif [[ "$lb" == *"insufficient_quota"* || "$lb" == *"insufficient funds"* || "$lb" == *"credits exhausted"* ]]; then
            reason="billing_exhausted"; action="rotate_pool"; retryable="true"
        fi
    fi

    printf '{"reason":"%s","retryable":%s,"should_compress":%s,"action":"%s"}' \
        "$reason" "$retryable" "$should_compress" "$action"
}
