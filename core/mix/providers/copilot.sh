# ─── Provider: GitHub Copilot ────────────────────────────────────────────────
# Reference provider implementation. Uses GitHub device-flow OAuth to get a
# short-lived Copilot API token, then hits api.githubcopilot.com which is
# fully OpenAI-compatible (same payload, same streaming format).
#
# Auth flow:
#   1. POST github.com/login/device/code  → device_code + user_code
#   2. User visits https://github.com/login/device, enters user_code
#   3. Poll POST github.com/login/oauth/access_token → github_token
#   4. GET  api.github.com/copilot_internal/v2/token → copilot_token (30min TTL)
#   5. Bearer copilot_token on api.githubcopilot.com/chat/completions
#
# Config:
#   PROVIDER=copilot
#   MODEL=gpt-4o  (or claude-sonnet-4-20250514, o3, etc.)
#
# Files:
#   ~/.mix/copilot_github_token  — persisted GitHub OAuth token (step 3)
#   /tmp/mix-copilot-token       — cached Copilot API token (step 4, auto-refreshes)

_COPILOT_CLIENT_ID="Iv1.b507a08c87ecfe98"  # GitHub Copilot CLI client ID (public)
_COPILOT_GH_TOKEN_FILE="${HOME}/.mix/copilot_github_token"

# ─── Step 1-3: GitHub device-flow OAuth ────────────────────────────────────

copilot_login() {
  local chat_id="$1"
  [ -n "$chat_id" ] && export TG_CHAT_ID="$chat_id"

  ui_msg "  *GitHub Copilot Login*"

  # Request device code
  local resp
  resp=$(curl -s -X POST "https://github.com/login/device/code" \
    -H "Accept: application/json" \
    -d "client_id=${_COPILOT_CLIENT_ID}&scope=user:email" 2>/dev/null) || {
    ui_msg "  Failed to reach GitHub. Check network."
    return 1
  }

  local device_code user_code verification_uri
  device_code=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read())["device_code"])' <(printf '%s' "$resp") 2>/dev/null)
  user_code=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read())["user_code"])' <(printf '%s' "$resp") 2>/dev/null)
  verification_uri=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read())["verification_uri"])' <(printf '%s' "$resp") 2>/dev/null)

  if [ -z "$device_code" ] || [ -z "$user_code" ]; then
    ui_msg "  Failed to get device code from GitHub.\nResponse: $resp"
    return 1
  fi

  ui_msg "  Code: \`$user_code\`\nOpen: $verification_uri\n(Copy code and paste it in the browser)"

  # Try to copy code to clipboard (only if local)
  if [ -z "$TG_CHAT_ID" ]; then
    if command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$user_code" | wl-copy 2>/dev/null
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$user_code" | xclip -selection clipboard 2>/dev/null
    elif command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$user_code" | pbcopy 2>/dev/null
    fi
  fi

  # Poll for token
  local interval=5
  local gh_token=""
  local _poll_attempts=0 _poll_max=60  # 5 min
  ui_msg "  Waiting for authorization..."
  
  while true; do
    _poll_attempts=$((_poll_attempts + 1))
    if [ "$_poll_attempts" -gt "$_poll_max" ]; then
      ui_msg "  Timed out waiting for authorization (5 min)."
      return 1
    fi
    sleep "$interval"
    local poll_resp
    poll_resp=$(curl -s -X POST "https://github.com/login/oauth/access_token" \
      -H "Accept: application/json" \
      -d "client_id=${_COPILOT_CLIENT_ID}&device_code=${device_code}&grant_type=urn:ietf:params:oauth:grant-type:device_code" 2>/dev/null) || true

    local error
    error=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read()).get("error",""))' <(printf '%s' "$poll_resp") 2>/dev/null)

    if [ "$error" = "authorization_pending" ]; then
      continue
    elif [ "$error" = "slow_down" ]; then
      interval=$((interval + 5))
      continue
    elif [ "$error" = "expired_token" ]; then
      ui_msg "  Device code expired."
      return 1
    elif [ -z "$error" ]; then
      gh_token=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read()).get("access_token",""))' <(printf '%s' "$poll_resp") 2>/dev/null)
      if [ -n "$gh_token" ]; then
        break
      fi
    else
      ui_msg "  Unexpected error: $error"
      return 1
    fi
  done

  # Persist GitHub token
  mkdir -p "$(dirname "$_COPILOT_GH_TOKEN_FILE")"
  printf '%s' "$gh_token" > "$_COPILOT_GH_TOKEN_FILE"
  chmod 600 "$_COPILOT_GH_TOKEN_FILE"

  ui_msg "  GitHub token saved."
  return 0
}

# ─── Step 4: Exchange GitHub token → Copilot API token ─────────────────────
copilot_get_api_token() {
  # Check for cached token (valid ~30min)
  local cache_file="/tmp/mix-copilot-api-token"
  if [ -f "$cache_file" ]; then
    local cached_ts cached_token
    cached_ts=$(_mix_stat_mtime "$cache_file")
    local now; now=$(date +%s)
    local age=$(( now - cached_ts ))
    # Refresh if older than 25 minutes (token lasts 30min)
    if [ "$age" -lt 1500 ]; then
      cat "$cache_file"
      return 0
    fi
  fi

  local gh_token
  if [ -f "$_COPILOT_GH_TOKEN_FILE" ]; then
    gh_token=$(cat "$_COPILOT_GH_TOKEN_FILE")
  fi

  if [ -z "$gh_token" ]; then
    echo -e "  \033[1;33mNo GitHub token. Run: /provider copilot login\033[0m" >&2
    return 1
  fi

  local resp
  resp=$(curl -s "https://api.github.com/copilot_internal/v2/token" \
    -H "Authorization: token $gh_token" \
    -H "Accept: application/json" 2>/dev/null) || {
    echo -e "  \033[1;31mFailed to get Copilot token.\033[0m" >&2
    return 1
  }

  local api_token api_endpoint
  api_token=$(python3 -c 'import json,sys;print(json.loads(open(sys.argv[1]).read()).get("token",""))' <(printf '%s' "$resp") 2>/dev/null)
  api_endpoint=$(python3 -c 'import json,sys;d=json.loads(open(sys.argv[1]).read());print(d.get("endpoints",{}).get("api",""))' <(printf '%s' "$resp") 2>/dev/null)

  if [ -z "$api_token" ]; then
    local err
    err=$(python3 -c 'import json,sys;d=json.loads(open(sys.argv[1]).read());print(d.get("message","unknown"))' <(printf '%s' "$resp") 2>/dev/null)
    echo -e "  \033[1;31mCopilot token error: $err\033[0m" >&2
    echo -e "  \033[0;90m(Try: /provider copilot login)\033[0m" >&2
    return 1
  fi

  # Cache token and endpoint
  printf '%s' "$api_token" > "$cache_file"
  [ -n "$api_endpoint" ] && printf '%s' "$api_endpoint" > "${cache_file}.endpoint"
  printf '%s' "$api_token"
  return 0
}

# ─── Provider hooks (called by mix core) ───────────────────────────────────

# Return the API key to use. For Copilot, we auto-refresh the short-lived token.
copilot_get_api_key() {
  copilot_get_api_token
}

# Return extra headers for curl (newline-separated)
copilot_curl_headers() {
  echo "-H \"Editor-Version: vscode/1.90.0\""
  echo "-H \"Editor-Plugin-Version: copilot-chat/0.15.0\""
  echo "-H \"Openai-Organization: github-copilot\""
  echo "-H \"Openai-Intent: copilot-panel\""
  echo "-H \"User-Agent: GitHubCopilotChat/0.15.0\""
}

# Return extra env vars for python3 streaming (space-separated KEY=VALUE pairs)
copilot_stream_env() {
  echo "COPILOT_HEADERS=1"
}

# Copilot streaming python3 needs these extra headers injected
# This function is called from within call_api_stream's python3 block
copilot_extra_headers_json() {
  python3 -c '
import json
h = {
    "Editor-Version": "vscode/1.90.0",
    "Editor-Plugin-Version": "copilot-chat/0.15.0",
    "Openai-Organization": "github-copilot",
    "Openai-Intent": "copilot-panel",
    "User-Agent": "GitHubCopilotChat/0.15.0"
}
print(json.dumps(h))
'
}

# ─── List available models ─────────────────────────────────────────────────
copilot_validate_model() {
  local model_id="$1"
  local api_token
  api_token=$(copilot_get_api_token 2>/dev/null) || { echo "Could not fetch token to validate model."; return 1; }

  local resp
  resp=$(curl -s "https://api.individual.githubcopilot.com/models" \
    -H "Authorization: Bearer $api_token" \
    -H "Accept: application/json" \
    -H "Editor-Version: vscode/1.90.0" \
    -H "Openai-Organization: github-copilot" 2>/dev/null)

  local found
  found=$(printf '%s' "$resp" | python3 -c "
import json,sys
try:
  data=json.loads(sys.stdin.read())
  models=data.get('data',data if isinstance(data,list) else [])
  ids=[m.get('id','') for m in models]
  print('yes' if '$model_id' in ids else 'no')
except: print('unknown')
" 2>/dev/null)

  if [ "$found" = "yes" ]; then
    return 0
  elif [ "$found" = "unknown" ]; then
    # Can't verify — allow it with a warning
    echo "(Could not verify model list — proceeding anyway)"
    return 0
  else
    # Print closest matches
    printf '%s' "$resp" | python3 -c "
import json,sys
try:
  data=json.loads(sys.stdin.read())
  models=data.get('data',data if isinstance(data,list) else [])
  ids=[m.get('id','') for m in models]
  needle='$model_id'.lower()
  close=[i for i in ids if needle in i.lower() or i.lower() in needle]
  if close:
    print('Did you mean: ' + ', '.join(close[:5]) + '?')
  else:
    # show all
    print('Available: ' + ', '.join(ids))
except: pass
" 2>/dev/null
    return 1
  fi
}

copilot_list_models() {
  local api_token
  api_token=$(copilot_get_api_token) || return 1

  local resp
  resp=$(curl -s "https://api.individual.githubcopilot.com/models" \
    -H "Authorization: Bearer $api_token" \
    -H "Accept: application/json" \
    -H "Editor-Version: vscode/1.90.0" \
    -H "Editor-Plugin-Version: copilot-chat/0.15.0" \
    -H "Openai-Organization: github-copilot" \
    -H "Openai-Intent: copilot-panel" \
    -H "User-Agent: GitHubCopilotChat/0.15.0" 2>/dev/null)

  if [ -z "$resp" ]; then
    echo -e "  \033[1;31mEmpty response from models endpoint. Token may be expired.\033[0m"
    echo "  Try: /provider copilot login"
    return 1
  fi

  printf '%s\n' "$resp" | python3 -c '
import json,sys
raw = sys.stdin.read()
try:
  data = json.loads(raw)
  # Some endpoints wrap in "data", others return top-level list
  models = data.get("data", data if isinstance(data, list) else [])
  if not models:
    print("  No models returned. Raw response:")
    print("  " + raw[:300])
  else:
    for m in models:
      mid = m.get("id","?")
      caps = m.get("capabilities",{})
      streaming = "stream" if caps.get("streaming",False) else "no-stream"
      tools = "tools" if caps.get("tool_calls",False) else "no-tools"
      print(f"  {mid:<45} [{streaming}] [{tools}]")
except Exception as e:
  print(f"  Error parsing models: {e}")
  print("  Raw (first 300): " + raw[:300])
'
}

# ─── Set provider to copilot ───────────────────────────────────────────────
copilot_activate() {
  # Check for GitHub token first
  if [ ! -f "$_COPILOT_GH_TOKEN_FILE" ]; then
    echo -e "  \033[1;33mNot logged in. Run: /provider copilot login\033[0m"
    return 1
  fi

  # Get API token to verify auth works
  local api_token
  api_token=$(copilot_get_api_token) || {
    echo -e "  \033[1;31mAuth failed. Try: /provider copilot login\033[0m"
    return 1
  }

  # Use the endpoint from the token response if available, fallback to default
  local _ep_cache="/tmp/mix-copilot-api-token.endpoint"
  local _api_url="https://api.individual.githubcopilot.com"
  if [ -f "$_ep_cache" ]; then
    local _cached_ep; _cached_ep=$(cat "$_ep_cache" 2>/dev/null)
    [ -n "$_cached_ep" ] && _api_url="$_cached_ep"
  fi

  # Override config
  BASE_URL="$_api_url"
  PROVIDER="copilot"
  # Only set default model if none is already set (preserves /model + persisted choice)
  if [ -z "${MODEL:-}" ] || [ "${MODEL}" = "glm-5" ]; then
    MODEL="${AGENT_MODEL:-gpt-4o}"
  fi

  echo -e "  \033[38;5;82m$I_OK Provider → copilot\033[0m"
  echo "  Base URL: $BASE_URL"
  echo "  Model: $MODEL"
  echo -e "  Run \033[1m/provider copilot models\033[0m to list available models"
  echo -e "  Run \033[1m/model <id>\033[0m to switch models"
}
