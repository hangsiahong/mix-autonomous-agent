# Prompt injection scanner — blocks obvious attacks in context files before injection
_scan_for_injection() {
    local content="$1"
    local source="${2:-unknown}"
    local verdict
    verdict=$(printf '%s' "$content" | python3 -c "
import sys, re
text = sys.stdin.read()

INVISIBLE = {'\u200b','\u200c','\u200d','\u2060','\ufeff','\u202a','\u202b','\u202c','\u202d','\u202e'}
BAD_PATTERNS = [
    (r'ignore\\s+(previous|all|above|prior)\\s+instructions', 'prompt_injection'),
    (r'system\\s+prompt\\s+override', 'sys_prompt_override'),
    (r'disregard\\s+(your|all|any)\\s+(instructions|rules|guidelines)', 'disregard_rules'),
    (r'do\\s+not\\s+tell\\s+the\\s+user', 'deception_hide'),
    (r'curl\\s+[^\\n]*\\\\\$\\{?\\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)', 'exfil_curl'),
    (r'cat\\s+[^\\n]*(\\.env|credentials|\\.netrc|\\.pgpass)', 'read_secrets'),
    (r'<!--[^>]*(?:ignore|override|system|secret|hidden)[^>]*-->', 'html_comment_injection'),
]
found = []
for c in text:
    if c in INVISIBLE:
        found.append('invisible_unicode_U' + format(ord(c), '04X'))
        break
for pat, pid in BAD_PATTERNS:
    if re.search(pat, text, re.IGNORECASE):
        found.append(pid)
print('BLOCKED:' + ','.join(found) if found else 'OK')
" 2>/dev/null || echo 'OK')
    if [[ "$verdict" == BLOCKED:* ]]; then
        echo "AMA: [SECURITY] Injection pattern detected in '$source': ${verdict#BLOCKED:}. Content blocked." >&2
        return 1
    fi
    return 0
}

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
    _scan_for_injection "$system_prompt" "brain/system_prompt.txt" || system_prompt="[System prompt blocked due to injection pattern detected]"

    # Inject SOUL.md persona (user-editable, loaded fresh each session — hermes pattern)
    if [[ -f "SOUL.md" && -s "SOUL.md" ]]; then
        local _soul_raw
        _soul_raw=$(cat "SOUL.md")
        # Strip comment block (<!-- ... -->) so only the actual persona text is injected
        _soul_raw=$(echo "$_soul_raw" | python3 -c "import sys,re; print(re.sub(r'<!--.*?-->', '', sys.stdin.read(), flags=re.DOTALL).strip())")
        if [[ -n "$_soul_raw" ]]; then
            system_prompt="${system_prompt}\n\n---\n\n# Persona\n${_soul_raw}"
        fi
    fi

    # Inject curated memory snapshot (frozen at session start — stable prefix cache)
    local _mem_block=""
    local _ENTRY_DELIM=$'\n§\n'
    if [[ -f "brain/state/MEMORY.md" && -s "brain/state/MEMORY.md" ]]; then
        local _mem_raw
        _mem_raw=$(cat "brain/state/MEMORY.md")
        _mem_block="${_mem_block}## My Notes (MEMORY.md)\n${_mem_raw}\n"
    fi
    if [[ -f "brain/state/USER.md" && -s "brain/state/USER.md" ]]; then
        local _user_raw
        _user_raw=$(cat "brain/state/USER.md")
        _mem_block="${_mem_block}## About the User (USER.md)\n${_user_raw}\n"
    fi
    if [[ -n "$_mem_block" ]]; then
        system_prompt="[System note: The following is your persistent memory — NOT new user input. Treat as authoritative reference. Do not re-execute tasks described here; they were completed in prior sessions.]\n\n${_mem_block}\n---\n\n${system_prompt}"
    fi
  fi

  local tools=$(cat brain/tools.json)

  # Skill-specific prompt injection
  if [[ -n "$skill" ]]; then
    local skill_prompt=""
    local skill_tools="[]"

    # 1. Load from core (system skills)
    if [[ -f "core/skills/${skill}/prompt.txt" ]]; then
        # Use a temporary python snippet to expand environment variables safely
        skill_prompt=$(CAT_FILE="core/skills/${skill}/prompt.txt" PWD_VAL="$(pwd)" python3 -c '
import os
content = open(os.environ["CAT_FILE"]).read()
print(content.replace("$(pwd)", os.environ["PWD_VAL"]))
')
    fi
    if [[ -f "core/skills/${skill}/tools.json" ]]; then
        skill_tools=$(cat "core/skills/${skill}/tools.json")
    fi

    # 2. Load from brain (user overrides/new skills) - Prepend/Append based on preference
    # We treat brain as higher priority or extension
    if [[ -f "brain/skills/${skill}/prompt.txt" ]]; then
        local user_prompt=$(cat "brain/skills/${skill}/prompt.txt")
        skill_prompt="${skill_prompt}\n\n${user_prompt}"
    fi
    if [[ -f "brain/skills/${skill}/tools.json" ]]; then
        local user_tools=$(cat "brain/skills/${skill}/tools.json")
        skill_tools=$(UT="$user_tools" python3 -c "import json,os,sys; a=json.load(sys.stdin); b=json.loads(os.environ['UT']); print(json.dumps(a+b,separators=(',',':')))" <<< "$skill_tools")
    fi

    # 3. Load from custom folder within brain skill (extra layer for cleanliness)
    if [[ -f "brain/skills/${skill}/custom/prompt.txt" ]]; then
        local custom_prompt=$(cat "brain/skills/${skill}/custom/prompt.txt")
        skill_prompt="${skill_prompt}\n\n### CUSTOM EXTENSION\n${custom_prompt}"
    fi
    if [[ -f "brain/skills/${skill}/custom/tools.json" ]]; then
        local custom_tools=$(cat "brain/skills/${skill}/custom/tools.json")
        skill_tools=$(CT="$custom_tools" python3 -c "import json,os,sys; a=json.load(sys.stdin); b=json.loads(os.environ['CT']); print(json.dumps(a+b,separators=(',',':')))" <<< "$skill_tools")
    fi

    if [[ -n "$skill_prompt" ]]; then
        system_prompt="${system_prompt}\n\n## ACTIVE SKILL: ${skill}\n${skill_prompt}"
    fi
    if [[ "$skill_tools" != "[]" ]]; then
        tools=$(ST="$skill_tools" python3 -c "import json,os,sys; a=json.load(sys.stdin); b=json.loads(os.environ['ST']); print(json.dumps(a+b,separators=(',',':')))" <<< "$tools")
    fi
  fi
  
  local _hist_for_api
  _hist_for_api=$(_apply_provider_history_filter "$HISTORY") || _hist_for_api="$HISTORY"
  
  local _extra_payload="{}"
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_extra_payload_json" >/dev/null 2>&1; then
    _extra_payload=$(${PROVIDER}_extra_payload_json 2>/dev/null) || _extra_payload="{}"
  fi

  # Write large blobs to tempfiles to avoid ARG_MAX / env-size limits.
  # HISTORY_JSON can be megabytes when it contains embedded base64 images.
  local _hist_file _sys_file
  _hist_file=$(mktemp)
  _sys_file=$(mktemp)
  printf '%s' "$_hist_for_api" > "$_hist_file"
  printf '%s' "$system_prompt" > "$_sys_file"

  TOOLS="$tools" \
  HIST_FILE="$_hist_file" \
  SYS_FILE="$_sys_file" \
  MODEL_NAME="$_model" \
  EXTRA_PAYLOAD="$_extra_payload" \
  STREAM_MODE="$stream" \
  python3 -c '
import json, os, sys
s = open(os.environ["SYS_FILE"]).read()
try:
    h = json.load(open(os.environ["HIST_FILE"]))
except Exception as e:
    sys.stderr.write(f"Bad HISTORY JSON: {e}\n")
    h = []
try:
    t = json.loads(os.environ.get("TOOLS") or "[]")
except:
    t = []
m = os.environ.get("MODEL_NAME", "")
try:
    ex = json.loads(os.environ.get("EXTRA_PAYLOAD") or "{}")
except:
    ex = {}
stream = os.environ.get("STREAM_MODE", "false").lower() == "true"

msg = [{"role": "system", "content": s}] + h
body = {"model": m, "messages": msg}
if t:
    wrapped_tools = []
    for tool in t:
        if isinstance(tool, dict) and "type" not in tool:
            wrapped_tools.append({"type": "function", "function": tool})
        else:
            wrapped_tools.append(tool)
    body["tools"] = wrapped_tools
    body["tool_choice"] = "auto"
if stream:
    body["stream"] = True
    body["stream_options"] = {"include_usage": True}
body.update(ex)
print(json.dumps(body))
'
  local _py_status=$?
  rm -f "$_hist_file" "$_sys_file"
  return $_py_status
}

call_api() {
  local sys_prompt_override="$1"

  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_call_api" >/dev/null 2>&1; then
    "${PROVIDER}_call_api" "$sys_prompt_override"
    return $?
  fi

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
      local _cls_parsed
      _cls_parsed=$(echo "$classification" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('reason','unknown'))
print(d.get('retryable','false'))
print(d.get('should_compress','false'))
" 2>/dev/null)
      local reason retryable should_compress
      IFS=$'\n' read -r reason retryable should_compress <<< "$_cls_parsed"

      if [[ "$reason" == "rate_limit" ]]; then
          mark_rate_limited "$PROVIDER" "$MODEL" 60
      fi

      # Log error for reflection
      local err_entry
      err_entry=$(TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")" PROV="$PROVIDER" MOD="$MODEL" CODE="$code" RSN="$reason" BODY="$body" python3 -c "
import json, os
print(json.dumps({'ts':os.environ['TS'],'provider':os.environ['PROV'],'model':os.environ['MOD'],'code':os.environ['CODE'],'reason':os.environ['RSN'],'body':os.environ['BODY']}))
")
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
