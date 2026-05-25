#!/bin/bash
# tools/switch_provider.sh — agent-facing provider/model swap for the current
# session. Writes sidecars that 24_agent_loop.sh reads on the NEXT turn (the
# in-flight turn is already committed to its provider). No restart, no .env edit.
#
# Args (via TOOL_ env vars):
#   provider  — required. One of: google, anthropic, openrouter, deepseek,
#               copilot, groq, kconsole, mimo, minimax, mistral, ollama, xai, zai.
#               Pass "default" to clear the override and return to .env's PROVIDER.
#   model     — optional. If omitted, a sensible per-provider default is picked
#               so model/provider stay in sync (the common foot-gun otherwise).
#               Pass "default" to clear the model override too.

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"

session_id="${TOOL_SESSION_ID:-${TOOL_session_id:-}}"
if [[ -z "$session_id" ]]; then
    echo "Error: TOOL_SESSION_ID is unset (tool execution context missing)."
    exit 1
fi

provider="${TOOL_provider:-}"
model="${TOOL_model:-}"

if [[ -z "$provider" ]]; then
    echo "Error: 'provider' is required. Try: google, anthropic, deepseek, kconsole, mimo, groq, openrouter, copilot, minimax, mistral, ollama, xai, zai. Use 'default' to revert."
    exit 1
fi

_VALID="google anthropic openrouter deepseek copilot groq kconsole mimo minimax mistral ollama xai zai default"
if ! grep -qw "$provider" <<< "$_VALID"; then
    echo "Error: unknown provider '$provider'. Valid: $_VALID"
    exit 1
fi

_provider_file="${_ROOT_DIR}/brain/state/provider_${session_id}"
_model_file="${_ROOT_DIR}/brain/state/model_${session_id}"

# "default" clears the override (returns to .env settings).
if [[ "$provider" == "default" ]]; then
    rm -f "$_provider_file"
    [[ "$model" == "default" || -z "$model" ]] && rm -f "$_model_file"
    [[ -n "$model" && "$model" != "default" ]] && printf '%s' "$model" > "$_model_file"
    echo "✓ Provider override cleared (will use .env default on next turn)."
    exit 0
fi

# Sensible default model per provider — keeps model/provider in sync so the
# agent doesn't have to remember exact model strings for every backend.
if [[ -z "$model" ]]; then
    case "$provider" in
        google)     model="gemini-3-flash-preview" ;;
        anthropic)  model="claude-sonnet-4-6" ;;
        openrouter) model="openrouter/auto" ;;
        deepseek)   model="deepseek-chat" ;;
        copilot)    model="gpt-4o" ;;
        groq)       model="llama-3.3-70b-versatile" ;;
        kconsole)   model="koompi-free" ;;
        mimo)       model="mimo-v2.5-pro" ;;
        minimax)    model="MiniMax-Text-01" ;;
        mistral)    model="mistral-large-latest" ;;
        ollama)     model="llama3.2" ;;
        xai)        model="grok-2-latest" ;;
        zai)        model="glm-4.6" ;;
    esac
fi

# Atomic writes — agent calls this from the tool execution path; the next turn
# starts as soon as we return.
printf '%s' "$provider" > "${_provider_file}.tmp" && mv "${_provider_file}.tmp" "$_provider_file"
if [[ "$model" == "default" ]]; then
    rm -f "$_model_file"
    echo "✓ Switched to provider <code>${provider}</code> (model cleared, will use provider default)."
else
    printf '%s' "$model" > "${_model_file}.tmp" && mv "${_model_file}.tmp" "$_model_file"
    echo "✓ Switched to provider <code>${provider}</code> with model <code>${model}</code>. Takes effect on the next turn."
fi
