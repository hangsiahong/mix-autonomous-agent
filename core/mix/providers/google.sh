# ─── Provider: Google (AI Studio + Vertex AI) ────────────────────────────────
# Supports two Google API surfaces, both OpenAI-compatible:
#
# 1. Google AI Studio (Gemini API) — simple, API key only
#    Endpoint: https://generativelanguage.googleapis.com/v1beta/openai
#    Auth: static API key from https://aistudio.google.com/apikey
#    Models: gemini-2.5-pro, gemini-2.5-flash, gemini-2.0-flash
#
# 2. Google Vertex AI — enterprise, gcloud CLI auth
#    Endpoint: https://{REGION}-aiplatform.googleapis.com/v1/projects/{PROJECT}/locations/{REGION}/endpoints/openapi
#    Auth: gcloud auth print-access-token (short-lived, auto-refreshes)
#    Same models + enterprise ones
#
# Config:
#   PROVIDER=google
#   MODEL=gemini-2.5-pro
#
# Files:
#   ~/.mix/google_provider   — stores: mode=studio|vertex, project_id, region
#   ~/.mix/google_api_key    — Studio API key (optional, can use env var)
#   /tmp/mix-google-token    — cached Vertex access token (auto-refreshes)

_GOOGLE_CONFIG_FILE="${HOME}/.mix/google_provider"
_GOOGLE_KEY_FILE="${HOME}/.mix/google_api_key"
_GOOGLE_TOKEN_CACHE="/tmp/mix-google-access-token"
_GOOGLE_THINKING_LEVEL=""  # empty = model default (high/dynamic for Gemini 3)

# Known models (hardcoded — stable, small list)
# Gemini 3.x models only available on Vertex AI via location=global
_GOOGLE_MODELS=(
  "gemini-2.5-pro"
  "gemini-2.0-flash-exp"
  "gemini-2.0-flash-thinking-exp"
  "gemini-1.5-pro"
  "gemini-1.5-flash"
  "gemini-3-flash-preview"
)

# Regex to detect global-only preview models
_GOOGLE_GLOBAL_MODELS_RE='gemini-3|gemini-exp'

# ─── Activate: read config, set BASE_URL + auth ────────────────────────────
google_activate() {
  # Determine mode: env override > config file > auto-detect
  local mode="${GOOGLE_MODE:-}"
  local project_id="${GOOGLE_PROJECT:-}"
  local region="${GOOGLE_REGION:-us-central1}"

  if [ -z "$mode" ] && [ -f "$_GOOGLE_CONFIG_FILE" ]; then
    mode=$(grep '^mode=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    [ -z "$project_id" ] && project_id=$(grep '^project_id=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    [ -z "$region" ] && region=$(grep '^region=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
    [ -z "$region" ] && region="us-central1"
    _GOOGLE_THINKING_LEVEL=$(grep '^thinking_level=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-) || true
  fi

  # Auto-detect: prefer Studio if key available, else Vertex if gcloud available
  if [ -z "$mode" ]; then
    if [ -n "${GOOGLE_API_KEY:-}" ] || [ -n "${GEMINI_KEY:-}" ] || [ -f "$_GOOGLE_KEY_FILE" ]; then
      mode="studio"
    elif [ -n "${GOOGLE_PROJECT:-}" ] || command -v gcloud >/dev/null 2>&1; then
      mode="vertex"
    else
      echo -e "  \033[1;33mGoogle provider: no credentials found.\033[0m"
      echo "  Run: /provider google login"
      return 1
    fi
  fi

  if [ "$mode" = "studio" ]; then
    BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai"
    local api_key="${GOOGLE_API_KEY:-}"
    if [ -z "$api_key" ] && [ -f "$_GOOGLE_KEY_FILE" ]; then
      api_key=$(cat "$_GOOGLE_KEY_FILE")
    fi
    if [ -z "$api_key" ]; then
      api_key="${GEMINI_KEY:-${API_KEY:-}}"
    fi
    if [ -z "$api_key" ]; then
      echo -e "  \033[1;33mNo Google API key. Run: /provider google login\033[0m"
      return 1
    fi
    API_KEY="$api_key"
    PROVIDER="google"
    [ -z "${MODEL:-}" ] && MODEL="gemini-2.5-pro"
    echo -e "  \033[38;5;82m$I_OK\033[0m Google AI Studio activated"
    echo "  Model: $MODEL | Endpoint: generativelanguage.googleapis.com"
    _mix_save_defaults
    return 0
  elif [ "$mode" = "vertex" ]; then
    if [ -z "$project_id" ]; then
      echo -e "  \033[1;33mNo Google Cloud project ID set.\033[0m"
      echo "  Run: /provider google login"
      return 1
    fi
    # Gemini 3.x Preview models only available on location=global
    local effective_region="$region"
    if [[ "${MODEL:-}" =~ $_GOOGLE_GLOBAL_MODELS_RE ]]; then
      effective_region="global"
    fi
    if [ "$effective_region" = "global" ]; then
      BASE_URL="https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${effective_region}/endpoints/openapi"
    else
      BASE_URL="https://${effective_region}-aiplatform.googleapis.com/v1/projects/${project_id}/locations/${effective_region}/endpoints/openapi"
    fi
    PROVIDER="google"
    [ -z "${MODEL:-}" ] && MODEL="gemini-2.5-pro"
    # Vertex OpenAI-compat needs 'google/' prefix in model field
    _GOOGLE_VERTEX_MODEL_PREFIX="google/"
    # Store API key for Vertex (used via x-goog-api-key header)
    local api_key="${GOOGLE_API_KEY:-}"
    if [ -z "$api_key" ] && [ -f "$_GOOGLE_KEY_FILE" ]; then
      api_key=$(cat "$_GOOGLE_KEY_FILE")
    fi
    API_KEY="$api_key"
    echo -e "  \033[38;5;82m$I_OK\033[0m Google Vertex AI activated"
    if [ "$effective_region" != "$region" ]; then
      echo "  Model: $MODEL | Project: $project_id | Region: global (preview model)"
    else
      echo "  Model: $MODEL | Project: $project_id | Region: $region"
    fi
    _mix_save_defaults
    return 0
  else
    echo -e "  \033[1;31mUnknown Google mode: $mode. Use 'studio' or 'vertex'.\033[0m"
    return 1
  fi
}

# ─── Login: interactive setup ───────────────────────────────────────────────
google_login() {
  echo -e "  \033[1;37mGoogle Provider Setup\033[0m"
  echo ""
  echo "  Choose authentication method:"
  echo "    1) AI Studio — API key (free, personal)"
  echo "    2) Vertex AI — gcloud + project (enterprise)"
  echo ""

  local choice
  printf "  Choice [1/2]: "
  read -r choice < /dev/tty

  if [ "$choice" = "1" ]; then
    _google_login_studio
  elif [ "$choice" = "2" ]; then
    _google_login_vertex
  else
    echo "  Cancelled."
    return 1
  fi
}

_google_login_studio() {
  echo ""
  echo -e "  \033[1;37mGoogle AI Studio — API Key\033[0m"
  echo "  Get your key at: \033[4mhttps://aistudio.google.com/apikey\033[0m"
  echo ""

  local api_key="${GOOGLE_API_KEY:-}"
  if [ -n "$api_key" ]; then
    echo -e "  \033[0;90mGOOGLE_API_KEY env var detected.\033[0m"
    printf "  Use it? [Y/n]: "
    read -r use_env < /dev/tty
    if [[ "$use_env" != [nN]* ]]; then
      _google_save_config "studio"
      echo -e "  \033[38;5;82m$I_OK\033[0m Using GOOGLE_API_KEY env var."
      return 0
    fi
  fi

  printf "  Paste API key: "
  read -r -s api_key < /dev/tty
  printf "\n"

  if [ -z "$api_key" ]; then
    echo -e "  \033[1;31mNo key provided.\033[0m"
    return 1
  fi

  # Validate key with a quick test call
  echo "  Validating key..."
  local test_resp
  test_resp=$(curl -s -o /dev/null -w "%{http_code}" \
    "https://generativelanguage.googleapis.com/v1beta/models?key=${api_key}" 2>/dev/null) || true

  if [ "$test_resp" = "200" ]; then
    mkdir -p "$(dirname "$_GOOGLE_KEY_FILE")"
    chmod 700 "$(dirname "$_GOOGLE_KEY_FILE")"
    printf '%s' "$api_key" > "$_GOOGLE_KEY_FILE"
    chmod 600 "$_GOOGLE_KEY_FILE"
    _google_save_config "studio"
    echo -e "  \033[38;5;82m$I_OK\033[0m API key validated and saved."
  elif [ "$test_resp" = "400" ] || [ "$test_resp" = "403" ]; then
    echo -e "  \033[1;31m$I_FAIL Invalid API key (HTTP $test_resp).\033[0m"
    return 1
  else
    echo -e "  \033[1;33m$I_WARN Could not validate (HTTP $test_resp). Saving anyway.\033[0m"
    mkdir -p "$(dirname "$_GOOGLE_KEY_FILE")"
    chmod 700 "$(dirname "$_GOOGLE_KEY_FILE")"
    printf '%s' "$api_key" > "$_GOOGLE_KEY_FILE"
    chmod 600 "$_GOOGLE_KEY_FILE"
    _google_save_config "studio"
  fi
}

_google_login_vertex() {
  echo ""
  echo -e "  \033[1;37mGoogle Vertex AI — gcloud CLI\033[0m"

  # Check gcloud
  if ! command -v gcloud >/dev/null 2>&1; then
    echo -e "  \033[1;31m$I_FAIL gcloud CLI not found.\033[0m"
    echo "  Install: https://cloud.google.com/sdk/docs/install"
    return 1
  fi

  # Check auth
  local account
  account=$(gcloud config get-value account 2>/dev/null) || true
  if [ -z "$account" ]; then
    echo "  No gcloud account configured. Running gcloud auth login..."
    gcloud auth login --no-launch-browser
    account=$(gcloud config get-value account 2>/dev/null) || true
    if [ -z "$account" ]; then
      echo -e "  \033[1;31m$I_FAIL Login failed.\033[0m"
      return 1
    fi
  fi
  echo -e "  Account: \033[38;5;82m$account\033[0m"

  # Get project
  local project_id="${GOOGLE_PROJECT:-}"
  if [ -z "$project_id" ]; then
    project_id=$(gcloud config get-value project 2>/dev/null) || true
  fi
  if [ -n "$project_id" ]; then
    printf "  Project ID [%s]: " "$project_id"
  else
    printf "  Project ID: "
  fi
  read -r project_id_input < /dev/tty
  [ -n "$project_id_input" ] && project_id="$project_id_input"

  if [ -z "$project_id" ]; then
    echo -e "  \033[1;31m$I_FAIL Project ID required.\033[0m"
    return 1
  fi

  # Get region
  local region="${GOOGLE_REGION:-us-central1}"
  printf "  Region [%s]: " "$region"
  read -r region_input < /dev/tty
  [ -n "$region_input" ] && region="$region_input"

  # Enable Vertex AI API if not enabled
  echo "  Checking Vertex AI API..."
  local api_enabled
  api_enabled=$(gcloud services list --enabled --project="$project_id" \
    --filter="name:aiplatform.googleapis.com" --format="value(name)" 2>/dev/null) || true
  if [ -z "$api_enabled" ]; then
    echo "  Enabling Vertex AI API (one-time)..."
    gcloud services enable aiplatform.googleapis.com --project="$project_id" 2>/dev/null || {
      echo -e "  \033[1;33m$I_WARN Could not auto-enable API. Enable manually:\033[0m"
      echo "  gcloud services enable aiplatform.googleapis.com --project=$project_id"
    }
  fi

  # Test token generation
  echo "  Testing access token..."
  local test_token
  test_token=$(gcloud auth print-access-token 2>/dev/null) || true
  if [ -z "$test_token" ]; then
    echo -e "  \033[1;31m$I_FAIL Could not generate access token.\033[0m"
    echo "  Try: gcloud auth login"
    return 1
  fi

  _google_save_config "vertex" "$project_id" "$region"
  echo -e "  \033[38;5;82m$I_OK\033[0m Vertex AI configured."
  echo "  Project: $project_id | Region: $region"
}

_google_save_config() {
  local mode="$1"
  local project_id="${2:-}"
  local region="${3:-us-central1}"
  mkdir -p "$(dirname "$_GOOGLE_CONFIG_FILE")"
  {
    printf 'mode=%s\nproject_id=%s\nregion=%s\n' "$mode" "$project_id" "$region"
    [ -n "${_GOOGLE_THINKING_LEVEL:-}" ] && printf 'thinking_level=%s\n' "$_GOOGLE_THINKING_LEVEL"
} > "$_GOOGLE_CONFIG_FILE"
  chmod 600 "$_GOOGLE_CONFIG_FILE"
}

# ─── Extra Payload: reasoning/thinking ──────────────────────────────────────
google_extra_payload_json() {
  local model_lower="${MODEL:-}"
  model_lower="${model_lower,,}"

  # Remove provider prefix if present
  model_lower="${model_lower#google/}"

  # Default thinking config for Gemini 3+
  if [[ "$model_lower" =~ gemini-3 ]]; then
      local level="${_GOOGLE_THINKING_LEVEL:-medium}"
      # Gemini 3 Pro only supports low/high
      if [[ "$model_lower" =~ pro ]]; then
          [[ "$level" != "high" ]] && level="low"
      fi

      # OpenAI-compatible field names for Gemini Thinking
      printf '{"include_thoughts": true, "thinking_level": "%s"}' "$level"
      return 0
  fi

  # Default for others
  echo "{}"
}

_google_get_vertex_token() {
  if [ -n "${GOOGLE_VERTEX_KEY:-}" ]; then
    echo -n "$GOOGLE_VERTEX_KEY"
    return 0
  fi
  if [ -f "$_GOOGLE_TOKEN_CACHE" ]; then
    local mtime=$(stat -c %Y "$_GOOGLE_TOKEN_CACHE")
    local now=$(date +%s)
    if [ $((now - mtime)) -lt 3000 ]; then
      cat "$_GOOGLE_TOKEN_CACHE"
      return 0
    fi
  fi

  local token
  token=$(gcloud auth print-access-token 2>/dev/null) || return 1
  echo -n "$token" > "$_GOOGLE_TOKEN_CACHE"
  echo -n "$token"
}

google_get_api_key() {
  local mode
  mode=$(grep '^mode=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
  [ -z "$mode" ] && mode="${GOOGLE_MODE:-studio}"

  if [ "$mode" = "vertex" ]; then
    _google_get_vertex_token
  else
    local api_key="${GOOGLE_API_KEY:-${GEMINI_KEY:-${API_KEY:-}}}"
    if [ -z "$api_key" ] && [ -f "$_GOOGLE_KEY_FILE" ]; then
      api_key=$(cat "$_GOOGLE_KEY_FILE")
    fi
    echo -n "$api_key"
  fi
}

google_extra_headers_json() {
  local mode
  mode=$(grep '^mode=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-) || true
  [ -z "$mode" ] && mode="${GOOGLE_MODE:-studio}"

  if [ "$mode" = "vertex" ]; then
    local api_key; api_key=$(google_get_api_key)
    # If it's a Vertex API key (AQ...), use x-goog-api-key and suppress Auth: Bearer
    if [[ "$api_key" == AQ.* ]]; then
      printf '{"Authorization": null, "x-goog-api-key": "%s"}' "$api_key"
      return 0
    fi

    # Vertex requires Project ID in headers if using global endpoint
    local project_id
    project_id=$(grep '^project_id=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-) || true
    if [ -n "$project_id" ]; then
      printf '{"x-goog-user-project": "%s"}' "$project_id"
      return 0
    fi
  fi
  echo "{}"
}

google_call_api() {
  local sys_prompt_override="$1"

  # If using OpenAI-compatible endpoint, fallback to standard call_api
  # Using subshell + unset trick to avoid recursion while keeping PROVIDER=google
  if [[ "$BASE_URL" == */openapi ]]; then
    (
      unset -f google_call_api
      call_api "$sys_prompt_override"
    )
    return $?
  fi

  local mode
  mode=$(grep '^mode=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
  [ -z "$mode" ] && mode="${GOOGLE_MODE:-studio}"

  local api_key; api_key=$(google_get_api_key)
  if [ -z "$api_key" ]; then
    echo "FAIL:no_api_key"
    return 1
  fi

  local url
  if [ "$mode" = "vertex" ]; then
    local project_id="${GOOGLE_PROJECT:-}"
    local region="${GOOGLE_REGION:-us-central1}"
    if [[ "$MODEL" =~ $_GOOGLE_GLOBAL_MODELS_RE ]]; then region="global"; fi
    url="https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/publishers/google/models/${MODEL}:generateContent"
  else
    url="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${api_key}"
  fi

  # Build Native Gemini Payload
  local system_prompt
  if [[ -n "$sys_prompt_override" ]]; then
    system_prompt="$sys_prompt_override"
  else
    system_prompt=$(cat brain/system_prompt.txt)
  fi

  local tools_json=$(cat brain/tools.json)

  local _extra_payload="{}"
  if type google_extra_payload_json >/dev/null 2>&1; then
      _extra_payload=$(google_extra_payload_json)
  fi

  # Conversion script for History (OpenAI -> Gemini Native)
  # This script handles multi-modal array content and tool calls.
  local payload
  payload=$(SYSTEM_PROMPT="$system_prompt" \
            HISTORY_JSON="${HISTORY:-[]}" \
            TOOLS_JSON="${tools_json:-[]}" \
            EXTRA_PAYLOAD="$_extra_payload" \
            python3 -c '
import json, os
s = os.environ.get("SYSTEM_PROMPT", "")
try: h = json.loads(os.environ.get("HISTORY_JSON") or "[]")
except: h = []
try: t = json.loads(os.environ.get("TOOLS_JSON") or "[]")
except: t = []

contents = []
for msg in h:
    role = "user" if msg["role"] == "user" else "model"
    parts = []

    if msg.get("content"):
        if isinstance(msg["content"], str):
            parts.append({"text": msg["content"]})
        elif isinstance(msg["content"], list):
            for p in msg["content"]:
                if p["type"] == "text":
                    parts.append({"text": p["text"]})
                elif p["type"] == "image_url":
                    # Extract base64
                    b64_data = p["image_url"]["url"].split(",")[-1]
                    mime = p["image_url"]["url"].split(";")[0].split(":")[-1]
                    parts.append({"inline_data": {"mime_type": mime, "data": b64_data}})
                elif p["type"] == "file_data":
                    parts.append({"file_data": p["file_data"]})

    if msg.get("tool_calls"):
        # For Gemini native, tool calls are parts of the content
        for tc in msg["tool_calls"]:
            parts.append({"function_call": {
                "name": tc["function"]["name"],
                "args": json.loads(tc["function"]["arguments"])
            }})

    if msg.get("role") == "tool":
        role = "user" # Gemini expects tool results in a "user" role content (functionResponse)
        parts = [{"function_response": {
            "name": msg["name"],
            "response": {"content": msg["content"]}
        }}]

    if parts:
        contents.append({"role": role, "parts": parts})

    # Gemini native payload
    body = {
        "contents": contents,
        "system_instruction": {"parts": [{"text": s}]},
    }
    if t:
        decls = []
        for tool in t:
            if "function" in tool:
                # OpenAI format: {"type": "function", "function": {...}}
                f = tool["function"]
            else:
                # Raw format: {"name": "...", "description": "...", "parameters": {...}}
                f = tool
            decls.append({
                "name": f.get("name"),
                "description": f.get("description", ""),
                "parameters": f.get("parameters", {"type": "object", "properties": {}})
            })
        body["tools"] = [{"function_declarations": decls}]

    try:
        ex = json.loads(os.environ.get("EXTRA_PAYLOAD", "{}"))
        if ex:
            if "thinking_level" not in ex:
                body.update(ex)
    except: pass

    print(json.dumps(body))
')

  local _curl_args=(-s -X POST "$url" -H "Content-Type: application/json")
  if [ "$mode" = "vertex" ]; then
    _curl_args+=(-H "Authorization: Bearer $api_key")
  fi

  local resp
  resp=$(curl "${_curl_args[@]}" -d "$payload")

  if [[ "$resp" == "FAIL:"* ]]; then
    echo "$resp"
    return 1
  fi

  if echo "$resp" | jq -e '.error' >/dev/null 2>&1; then
    echo "FAIL:google_error:$(echo "$resp" | jq -c '.error' 2>/dev/null)"
    return 1
  fi

  echo "$resp"
}

google_call_api_stream() {
  local chat_id="$1"
  local message_id="$2"
  local skill="$3"
  local sys_prompt_override="$4"

  # If using OpenAI-compatible endpoint, fallback to standard call_api_stream
  if [[ "$BASE_URL" == */openapi ]]; then
    (
      unset -f google_call_api_stream
      call_api_stream "$chat_id" "$message_id" "$skill" "$sys_prompt_override"
    )
    return $?
  fi

  local mode
  mode=$(grep '^mode=' "$_GOOGLE_CONFIG_FILE" 2>/dev/null | cut -d= -f2-)
  [ -z "$mode" ] && mode="${GOOGLE_MODE:-studio}"

  local api_key; api_key=$(google_get_api_key)

  local url
  if [ "$mode" = "vertex" ]; then
    local project_id="${GOOGLE_PROJECT:-}"
    local region="${GOOGLE_REGION:-us-central1}"
    if [[ "$MODEL" =~ $_GOOGLE_GLOBAL_MODELS_RE ]]; then region="global"; fi
    url="https://aiplatform.googleapis.com/v1/projects/${project_id}/locations/${region}/publishers/google/models/${MODEL}:generateContent"
  else
    url="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${api_key}"
  fi

  # Reuse the payload builder logic from google_call_api
  # But we need the payload now
  local system_prompt
  if [[ -n "$sys_prompt_override" ]]; then
    system_prompt="$sys_prompt_override"
  else
    system_prompt=$(cat brain/system_prompt.txt)
  fi
  local tools_json=$(cat brain/tools.json)

  local _extra_payload="{}"
  if type google_extra_payload_json >/dev/null 2>&1; then
      _extra_payload=$(google_extra_payload_json)
  fi

  # ... payload building is inside the python script in google_call_api ...
  # I will extract it to a shared function or just duplicate for now (caveman style).

  local payload
  payload=$(SYSTEM_PROMPT="$system_prompt" \
            HISTORY_JSON="${HISTORY:-[]}" \
            TOOLS_JSON="${tools_json:-[]}" \
            EXTRA_PAYLOAD="$_extra_payload" \
            python3 -c '
import sys, json, os
# h_raw = os.environ.get("HISTORY_JSON")
# sys.stderr.write(f"DEBUG HISTORY_RAW: {h_raw}\n")
s = os.environ.get("SYSTEM_PROMPT", "")
try: h = json.loads(os.environ.get("HISTORY_JSON") or "[]")
except: h = []
try: t = json.loads(os.environ.get("TOOLS_JSON") or "[]")
except: t = []
contents = []
for msg in h:
    role = "user" if msg["role"] == "user" else "model"
    parts = []
    if msg.get("content"):
        if isinstance(msg["content"], str):
            parts.append({"text": msg["content"]})
        elif isinstance(msg["content"], list):
            for p in msg["content"]:
                if p["type"] == "text": parts.append({"text": p["text"]})
                elif p["type"] == "image_url":
                    b64_data = p["image_url"]["url"].split(",")[-1]
                    mime = p["image_url"]["url"].split(";")[0].split(":")[-1]
                    parts.append({"inline_data": {"mime_type": mime, "data": b64_data}})
                elif p["type"] == "file_data":
                    parts.append({"file_data": p["file_data"]})
    if msg.get("tool_calls"):
        for tc in msg["tool_calls"]:
            parts.append({"function_call": {"name": tc["function"]["name"], "args": json.loads(tc["function"]["arguments"])}})
    if msg.get("role") == "tool":
        role = "user"
        parts = [{"function_response": {"name": msg["name"], "response": {"content": msg["content"]}}}]
    if parts: contents.append({"role": role, "parts": parts})
body = {"contents": contents, "system_instruction": {"parts": [{"text": s}]}}
if t:
    decls = []
    for tool in t:
        if "function" in tool:
            f = tool["function"]
        else:
            f = tool
        decls.append({
            "name": f.get("name"),
            "description": f.get("description", ""),
            "parameters": f.get("parameters", {"type": "object", "properties": {}})
        })
    body["tools"] = [{"function_declarations": decls}]

try:
    ex = json.loads(os.environ.get("EXTRA_PAYLOAD", "{}"))
    if ex:
        if "generationConfig" not in body:
            body["generationConfig"] = {}
        if "thinking_level" not in ex:
            body.update(ex)
except: pass

import sys
# DEBUG
# sys.stderr.write(f"DEBUG PAYLOAD: {json.dumps(body)}\n")
print(json.dumps(body))
')

  TG_TOKEN="$TG_TOKEN" \
  CHAT_ID="$chat_id" \
  MESSAGE_ID="$message_id" \
  GOOGLE_STREAM_URL="$url" \
  API_KEY="$api_key" \
  GOOGLE_MODE="$mode" \
  python3 core/mix/providers/google_stream.py <<EOF
$payload
EOF
}

# ─── Validate: check model availability ─────────────────────────────────────
google_validate_model() {
  local model_id="$1"
  for m in "${_GOOGLE_MODELS[@]}"; do
    [ "$m" = "$model_id" ] && return 0
  done

  local needle="${model_id,,}"
  local suggestions=()
  for m in "${_GOOGLE_MODELS[@]}"; do
    if [[ "${m,,}" == *"$needle"* ]] || [[ "$needle" == *"${m,,}"* ]]; then
      suggestions+=("$m")
    fi
  done

  if [ ${#suggestions[@]} -gt 0 ]; then
    echo "Did you mean: ${suggestions[*]}?"
  else
    echo "Unknown model '$model_id'. Available: ${_GOOGLE_MODELS[*]}"
  fi
  return 1
}

# ─── Filter history: sanitize tool_calls missing thought_signature ───────────
google_filter_history() {
  python3 -c '
import json, sys
history = json.load(sys.stdin)
for msg in history:
    # Ensure role "tool" has "tool_call_id" instead of "id" for standard OpenAI
    # But some surfaces want "tool_call_id".
    # IMPORTANT: Vertex OpenAI-compat strictly follows OpenAI spec.
    # In OpenAI: assistant has tool_calls[i].id
    #            tool has tool_call_id

    if msg.get("role") == "tool":
        if "id" in msg and "tool_call_id" not in msg:
            msg["tool_call_id"] = msg.pop("id")
        if not msg.get("tool_call_id"):
            msg["tool_call_id"] = "call_" + msg.get("name", "tool")

    if msg.get("role") == "assistant" and msg.get("tool_calls"):
        for tc in msg["tool_calls"]:
            if "extra_content" not in tc:
                tc["extra_content"] = {}
            if "google" not in tc["extra_content"]:
                tc["extra_content"]["google"] = {}
            sig = tc.pop("thought_signature", None)
            if not sig:
                sig = tc["extra_content"]["google"].get("thought_signature", "")
            if not sig:
                sig = "skip_thought_signature_validator"
            tc["extra_content"]["google"]["thought_signature"] = sig
            # Ensure "id" exists for assistant tool_calls
            if "id" not in tc or not tc["id"]:
                tc["id"] = "call_" + tc.get("function", {}).get("name", tc.get("name", "tool"))
            if "type" not in tc or not tc["type"]:
                tc["type"] = "function"

            # Ensure "function" exists if using raw name/args from Gemini output
            if "function" not in tc and "name" in tc:
                args_val = tc.get("args", "{}")
                if not isinstance(args_val, str):
                    args_val = json.dumps(args_val)
                tc["function"] = {"name": tc.pop("name"), "arguments": args_val}
                tc.pop("args", None)

print(json.dumps(history))
'
}
