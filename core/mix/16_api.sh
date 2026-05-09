# API helper
_api_build_payload() {
  local stream="${1:-false}"
  local sys_prompt_override="$2"
  local skill="$3"
  local _model="$MODEL"
  [ -n "${_GOOGLE_VERTEX_MODEL_PREFIX:-}" ] && _model="${_GOOGLE_VERTEX_MODEL_PREFIX}${MODEL}"
  
  local system_prompt
  if [[ -n "$sys_prompt_override" ]]; then
    system_prompt="$sys_prompt_override"
  else
    system_prompt=$(cat brain/system_prompt.txt)
  fi

  # Skill-specific prompt injection
  if [[ -n "$skill" ]]; then
    if [[ -f "brain/skills/${skill}/prompt.txt" ]]; then
        local skill_prompt=$(cat "brain/skills/${skill}/prompt.txt")
        system_prompt="${system_prompt}\n\n## ACTIVE SKILL: ${skill}\n${skill_prompt}"
    fi
  fi
  
  local tools=$(cat brain/tools.json)

  # Skill-specific tool filtering/addition
  if [[ -n "$skill" ]]; then
    if [[ -f "brain/skills/${skill}/tools.json" ]]; then
        local skill_tools=$(cat "brain/skills/${skill}/tools.json")
        tools=$(echo "$tools" | jq --argjson st "$skill_tools" '. + $st')
    fi
  fi
  
  local _hist_for_api
  _hist_for_api=$(_apply_provider_history_filter "$HISTORY") || _hist_for_api="$HISTORY"
  
  local _extra_payload="{}"
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_extra_payload_json" >/dev/null 2>&1; then
    _extra_payload=$(${PROVIDER}_extra_payload_json 2>/dev/null) || _extra_payload="{}"
  fi

  printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
    "$(printf '%s' "$system_prompt" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')" \
    "$tools" \
    "$_hist_for_api" \
    "$_model" \
    "$_extra_payload" \
    "$stream" \
  | python3 -c '
import json,sys
s=json.loads(sys.stdin.readline())
t=json.loads(sys.stdin.readline())
h=json.loads(sys.stdin.readline())
m=sys.stdin.readline().strip()
ex=json.loads(sys.stdin.readline())
stream=sys.stdin.readline().strip().lower()=="true"
msg=[{"role":"system","content":s}]+h
body={"model":m,"messages":msg,"tools":t,"tool_choice":"auto"}
if stream:
    body["stream"]=True
    body["stream_options"]={"include_usage":True}
body.update(ex)
print(json.dumps(body))
' 2>/dev/null
}

call_api() {
  local sys_prompt_override="$1"
  local payload
  payload=$(_api_build_payload "false" "$sys_prompt_override") || { echo "FAIL:payload"; return 1; }

  local _api_key="$API_KEY"
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_get_api_key" >/dev/null 2>&1; then
    local _pkey; _pkey=$(${PROVIDER}_get_api_key 2>/dev/null) || true
    [ -n "$_pkey" ] && _api_key="$_pkey"
  fi

  local _suppress_auth=false
  local _extra_pairs=""
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_extra_headers_json" >/dev/null 2>&1; then
    local _pheaders; _pheaders=$(${PROVIDER}_extra_headers_json 2>/dev/null) || true
    if [ -n "$_pheaders" ]; then
      _extra_pairs=$(printf '%s' "$_pheaders" | python3 -c '
import json,sys
for k,v in json.load(sys.stdin).items():
    if v is None:
        if k.lower()=="authorization": print("SUPPRESS_AUTH")
    else:
        print(f"{k}\t{v}")
' 2>/dev/null) || true
      echo "$_extra_pairs" | grep -q '^SUPPRESS_AUTH' && _suppress_auth=true
    fi
  fi

  local _curl_args=(-s -w "%{http_code}" --max-time 1800
    "${BASE_URL}/chat/completions"
    -H "Content-Type: application/json")
  [ "$_suppress_auth" = "false" ] && _curl_args+=(-H "Authorization: Bearer $_api_key")

  if [ -n "$_extra_pairs" ]; then
    while IFS=$'\t' read -r _hk _hv; do
      [ "$_hk" = "SUPPRESS_AUTH" ] && continue
      [ -n "$_hk" ] && [ -n "$_hv" ] && _curl_args+=(-H "$_hk: $_hv")
    done <<< "$_extra_pairs"
  fi

  local attempt=1
  local max_attempts=3
  while [ "$attempt" -le "$max_attempts" ]; do
      if ! check_rate_limit "$PROVIDER" "$MODEL"; then
          # If rate limited, we might want to fail fast or try a fallback model
          # For now, just wait if it's the first attempt, or fail if we've waited enough
          sleep 5
      fi

      local tmp; tmp=$(mktemp)
      local code
      local curl_err=0
      code=$(curl "${_curl_args[@]}" -o "$tmp" -d "$payload" 2>/dev/null) || curl_err=$?
      local body; body=$(cat "$tmp" 2>/dev/null || true); rm -f "$tmp"
      
      if [ "$curl_err" -ne 0 ]; then
        echo "FAIL:curl_error_$curl_err"
        return 1
      fi

      if [ "$code" == "200" ]; then
          printf '%s' "$body"
          return 0
      fi

      # Classify Error
      local classification=$(classify_error "$code" "$body")
      local reason=$(echo "$classification" | jq -r '.reason')
      local retryable=$(echo "$classification" | jq -r '.retryable')
      local should_compress=$(echo "$classification" | jq -r '.should_compress')

      if [[ "$reason" == "rate_limit" ]]; then
          mark_rate_limited "$PROVIDER" "$MODEL" 60
      fi

      # Log error for reflection
      local err_entry=$(jq -n \
          --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
          --arg provider "$PROVIDER" \
          --arg model "$MODEL" \
          --arg code "$code" \
          --arg reason "$reason" \
          --arg body "$body" \
          '{ts: $ts, provider: $provider, model: $model, code: $code, reason: $reason, body: $body}')
      echo "$err_entry" >> "brain/state/error_log.jsonl"

      if [[ "$retryable" == "true" && "$attempt" -lt "$max_attempts" ]]; then
          local delay=$((2 ** attempt + RANDOM % 5))
          echo "AMA: API Error $code, retrying in $delay s... ($attempt/$max_attempts)" >&2
          
          # If it's a rate limit or server error and we have a fallback, switch for next attempt
          if [[ ("$reason" == "rate_limit" || "$reason" == "server_error") && -n "$FALLBACK_MODEL" && "$MODEL" != "$FALLBACK_MODEL" ]]; then
              echo "AMA: Switching to fallback model $FALLBACK_MODEL" >&2
              MODEL="$FALLBACK_MODEL"
              # Re-build payload with new model
              payload=$(_api_build_payload "false" "$sys_prompt_override")
          fi

          sleep "$delay"
          attempt=$((attempt + 1))
          continue
      fi

      echo "FAIL:$code:$body"
      return 1
  done
}
