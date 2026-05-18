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
    system_prompt=$(cat brain/system_prompt.md)
    _scan_for_injection "$system_prompt" "brain/system_prompt.md" || system_prompt="[System prompt blocked due to injection pattern detected]"

    # Inject current date/time and working directory so the agent always knows "today"
    local _now _cwd
    _now=$(date '+%A, %B %-d, %Y at %H:%M %Z')
    _cwd=$(pwd)
    system_prompt="Current date and time: ${_now}\nCurrent directory: ${_cwd}\n\n${system_prompt}"

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

    # Inject active todo/plan list (state awareness: LLM sees its own checklist every turn)
  # Prevents the "forgot I tried this 3 turns ago" failure mode
  local _todo_block=""
  for _todo_file in "brain/state/todo_default.json" "brain/state/todo_${session_id:-unknown}.json"; do
    if [[ -f "$_todo_file" && -s "$_todo_file" ]]; then
      local _pending
      _pending=$(python3 -c "
import json, sys
try:
    tasks = json.load(open(sys.argv[1]))
    pending = [t for t in tasks if not t.get('done', False)]
    if pending:
        lines = ['[ ] ' + t.get('text','') for t in pending[:10]]
        print('\n'.join(lines))
except: pass
" "$_todo_file" 2>/dev/null)
      if [[ -n "$_pending" ]]; then
        _todo_block="## Active Plan (your checklist — update with the todo tool)\n${_pending}\n\n"
        break
      fi
    fi
  done
  [[ -n "$_todo_block" ]] && system_prompt="${_todo_block}${system_prompt}"

  # Inject curated memory snapshot (hermes pattern: treat as authoritative background reference)
    local _mem_block=""
    if [[ -f "brain/state/MEMORY.md" && -s "brain/state/MEMORY.md" ]]; then
        local _mem_raw
        _mem_raw=$(cat "brain/state/MEMORY.md")
        _mem_block="${_mem_block}## My Notes\n${_mem_raw}\n"
    fi
    if [[ -f "brain/state/USER.md" && -s "brain/state/USER.md" ]]; then
        local _user_raw
        _user_raw=$(cat "brain/state/USER.md")
        _mem_block="${_mem_block}## About the User\n${_user_raw}\n"
    fi

    # Inject skill index — cached per session to avoid disk I/O + Python on every turn.
    # Cache invalidated when core/skills or brain/skills directory mtime changes.
    local _skill_index
    local _skill_cache="${DIR:-$(pwd)}/brain/state/skill_cache_${session_id:-default}.txt"
    local _skill_mtime_file="${DIR:-$(pwd)}/brain/state/skill_mtime_${session_id:-default}"
    local _cur_mtime; _cur_mtime=$(stat -c '%Y' core/skills brain/skills 2>/dev/null | md5sum | cut -c1-8)
    local _cached_mtime; _cached_mtime=$(cat "$_skill_mtime_file" 2>/dev/null || echo "")
    if [[ -f "$_skill_cache" && "$_cur_mtime" == "$_cached_mtime" ]]; then
        _skill_index=$(cat "$_skill_cache")
    else
        _skill_index=$(python3 tools/skill_router.py index 2>/dev/null)
        printf '%s' "$_skill_index" > "$_skill_cache"
        printf '%s' "$_cur_mtime" > "$_skill_mtime_file"
    fi
    [[ -n "$_skill_index" ]] && _mem_block="${_mem_block}${_skill_index}\n"
    # Inject recent session recaps prominently — these answer "what did we do last session?"
    # Placed FIRST so the agent sees them immediately before any other memory.
    # Cache keyed by mtime of session_recaps.jsonl — only rebuild when file changes.
    if [[ -f "brain/state/session_recaps.jsonl" ]]; then
        local _recaps_raw=""
        local _recaps_cache="${DIR:-$(pwd)}/brain/state/recaps_cache_${session_id:-default}.txt"
        local _recaps_mtime_file="${DIR:-$(pwd)}/brain/state/recaps_mtime_${session_id:-default}"
        local _cur_recaps_mtime; _cur_recaps_mtime=$(stat -c '%Y' "brain/state/session_recaps.jsonl" 2>/dev/null || echo "0")
        local _cached_recaps_mtime; _cached_recaps_mtime=$(cat "$_recaps_mtime_file" 2>/dev/null || echo "")
        if [[ -f "$_recaps_cache" && "$_cur_recaps_mtime" == "$_cached_recaps_mtime" ]]; then
            _recaps_raw=$(cat "$_recaps_cache" 2>/dev/null || true)
        else
            _recaps_raw=$(python3 -c "
import json, sys
lines = open('brain/state/session_recaps.jsonl').readlines()
recent = []
for line in lines[-3:]:
    try:
        e = json.loads(line)
        ts = e.get('ts','')[:10]
        sid = e.get('session_id','?')
        recap = e.get('recap','').strip()
        if recap:
            recent.append(f'[{ts} | {sid}]\n{recap}')
    except: pass
if recent:
    print('\n\n---\n'.join(recent))
" 2>/dev/null || true)
            if [[ -n "$_recaps_raw" ]]; then
                printf '%s' "$_recaps_raw" > "$_recaps_cache"
                printf '%s' "$_cur_recaps_mtime" > "$_recaps_mtime_file"
            fi
        fi
        if [[ -n "$_recaps_raw" ]]; then
            system_prompt="## Recent Session Recaps — READ THIS FIRST for questions about past sessions
${_recaps_raw}

---

${system_prompt}"
        fi
    fi
    if [[ -n "$_mem_block" ]]; then
        system_prompt="[PERSISTENT MEMORY — REFERENCE ONLY]\n\n${_mem_block}\n---\n\n${system_prompt}"
    fi
  fi

  # Load all tools then filter to active toolsets.
  # Default toolsets come from brain/config.json:default_toolsets.
  # A skill can expand by listing extra toolsets in its tools.json as:
  #   {"_enabled_toolsets": ["inspect", "media"]}
  # TOOL_EXTRA_TOOLSETS env var also accepted (space-separated) for ad-hoc expansion.
  #
  # brain/tools_extra.json (gitignored) holds agent-added custom tools.
  # It is merged at runtime so upstream brain/tools.json never conflicts.
  # AMA_TOOLS_OVERRIDE: reflection/recap use this to pass their own tool subset
  # without touching the shared brain/tools.json (prevents race condition corruption).
  # When not overriding, merge tools + read config in a single Python subprocess.
  local _all_tools _default_ts
  if [[ -n "${AMA_TOOLS_OVERRIDE:-}" ]]; then
    _all_tools="$AMA_TOOLS_OVERRIDE"
    _default_ts=$(python3 -c "
import json
try:
    ts = json.load(open('brain/config.json')).get('default_toolsets',['core','search','memory','meta'])
    print(' '.join(ts))
except: print('core search memory meta')
" 2>/dev/null || echo "core search memory meta")
  else
    local _combined
    _combined=$(python3 -c "
import json, sys
# Merge tools.json + tools_extra.json
try:
    base = json.load(open('brain/tools.json'))
    try:
        extra = json.load(open('brain/tools_extra.json'))
        base_names = {t.get('name') for t in base}
        base += [t for t in extra if t.get('name') not in base_names]
    except FileNotFoundError:
        pass
    except Exception as e:
        sys.stderr.write(f'tools_extra merge warning: {e}\n')
    tools_json = json.dumps(base)
except Exception as e:
    sys.stderr.write(f'tools load error: {e}\n')
    tools_json = open('brain/tools.json').read()
# Read default_toolsets from config
try:
    ts = json.load(open('brain/config.json')).get('default_toolsets',['core','search','memory','meta'])
    ts_str = ' '.join(ts)
except:
    ts_str = 'core search memory meta'
print(ts_str)
print(tools_json)
" 2>/dev/null)
    _default_ts=$(printf '%s' "$_combined" | head -1)
    _all_tools=$(printf '%s' "$_combined" | tail -n +2)
    [[ -z "$_default_ts" ]] && _default_ts="core search memory meta"
    [[ -z "$_all_tools" ]] && _all_tools=$(cat brain/tools.json 2>/dev/null || echo '[]')
  fi
  local _active_ts="${TOOL_EXTRA_TOOLSETS:-} $_default_ts"
  local tools
  tools=$(python3 -c "
import json, sys
raw = open(sys.argv[1]).read()
try:
    all_tools = json.loads(raw)
except:
    print(raw); sys.exit(0)
active = set(sys.argv[2].split())
# Always include tools with no toolset field (legacy/custom tools)
filtered = [t for t in all_tools if t.get('toolset','core') in active or 'toolset' not in t]
# Strip internal 'toolset' field before sending to API
for t in filtered:
    t.pop('toolset', None)
print(json.dumps(filtered, separators=(',',':')))
" <(printf '%s' "$_all_tools") "$_active_ts" 2>/dev/null)
  # Fallback: if filter fails, send all tools (minus toolset field)
  if [[ -z "$tools" || "$tools" == "null" ]]; then
    tools=$(python3 -c "
import json,sys
t=json.loads(open(sys.argv[1]).read())
for x in t: x.pop('toolset',None)
print(json.dumps(t,separators=(',',':')))
" <(cat brain/tools.json) 2>/dev/null || cat brain/tools.json)
  fi

  # Skill-specific prompt injection
  if [[ -n "$skill" ]]; then
    local skill_prompt=""
    local skill_tools="[]"

    # 1. Load from core (system skills) — prefer .md, fall back to .txt
    local _core_prompt_file=""
    if [[ -f "core/skills/${skill}/prompt.md" ]]; then
        _core_prompt_file="core/skills/${skill}/prompt.md"
    elif [[ -f "core/skills/${skill}/prompt.txt" ]]; then
        _core_prompt_file="core/skills/${skill}/prompt.txt"
    fi
    if [[ -n "$_core_prompt_file" ]]; then
        # Use a temporary python snippet to expand environment variables safely
        skill_prompt=$(python3 -c '
import sys
content = open(sys.argv[1]).read()
print(content.replace("$(pwd)", sys.argv[2]))
' "$_core_prompt_file" "$(pwd)")
    fi
    if [[ -f "core/skills/${skill}/tools.json" ]]; then
        skill_tools=$(cat "core/skills/${skill}/tools.json")
    fi

    # 2. Load from brain (user overrides/new skills) — prefer .md, fall back to .txt
    local _brain_prompt_file=""
    if [[ -f "brain/skills/${skill}/prompt.md" ]]; then
        _brain_prompt_file="brain/skills/${skill}/prompt.md"
    elif [[ -f "brain/skills/${skill}/prompt.txt" ]]; then
        _brain_prompt_file="brain/skills/${skill}/prompt.txt"
    fi
    if [[ -n "$_brain_prompt_file" ]]; then
        local user_prompt=$(cat "$_brain_prompt_file")
        skill_prompt="${skill_prompt}\n\n${user_prompt}"
    fi
    if [[ -f "brain/skills/${skill}/tools.json" ]]; then
        local user_tools=$(cat "brain/skills/${skill}/tools.json")
        skill_tools=$(python3 -c "import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).read())+json.loads(open(sys.argv[2]).read()),separators=(',',':')))" <(printf '%s' "$skill_tools") <(printf '%s' "$user_tools"))
    fi

    # 3. Load from custom folder — prefer .md, fall back to .txt
    local _custom_prompt_file=""
    if [[ -f "brain/skills/${skill}/custom/prompt.md" ]]; then
        _custom_prompt_file="brain/skills/${skill}/custom/prompt.md"
    elif [[ -f "brain/skills/${skill}/custom/prompt.txt" ]]; then
        _custom_prompt_file="brain/skills/${skill}/custom/prompt.txt"
    fi
    if [[ -n "$_custom_prompt_file" ]]; then
        local custom_prompt=$(cat "$_custom_prompt_file")
        skill_prompt="${skill_prompt}\n\n### CUSTOM EXTENSION\n${custom_prompt}"
    fi
    if [[ -f "brain/skills/${skill}/custom/tools.json" ]]; then
        local custom_tools=$(cat "brain/skills/${skill}/custom/tools.json")
        skill_tools=$(python3 -c "import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).read())+json.loads(open(sys.argv[2]).read()),separators=(',',':')))" <(printf '%s' "$skill_tools") <(printf '%s' "$custom_tools"))
    fi

    if [[ -n "$skill_prompt" ]]; then
        system_prompt="${system_prompt}\n\n## ACTIVE SKILL: ${skill}\n${skill_prompt}"
    fi
    # If skill_tools contains "_enabled_toolsets", pull in additional toolsets from all_tools
    if [[ "$skill_tools" != "[]" ]]; then
        local _extra_ts
        _extra_ts=$(python3 -c "
import json,sys
try:
    st=json.loads(open(sys.argv[1]).read())
    extra=[x for x in st if isinstance(x,dict) and '_enabled_toolsets' in x]
    if extra:
        ts=extra[0]['_enabled_toolsets']
        print(' '.join(ts) if isinstance(ts,list) else str(ts))
except:
    pass
" <(printf '%s' "$skill_tools") 2>/dev/null)
        if [[ -n "$_extra_ts" ]]; then
            # Re-filter all_tools with expanded toolset list
            local _expanded_ts="$_active_ts $_extra_ts"
            local _extra_tool_defs
            _extra_tool_defs=$(python3 -c "
import json,sys
all_tools=json.loads(open(sys.argv[3]).read())
already=set(t.get('name') for t in json.loads(open(sys.argv[1]).read()))
active=set(sys.argv[2].split())
extra=[t for t in all_tools if t.get('toolset','core') in active and t.get('name') not in already]
for t in extra: t.pop('toolset',None)
print(json.dumps(extra,separators=(',',':')))
" <(printf '%s' "${tools:-[]}") "$_expanded_ts" <(cat brain/tools.json) 2>/dev/null || echo "[]")
            tools=$(python3 -c "
import json,sys
base=json.loads(open(sys.argv[2]).read())
extra=json.loads(open(sys.argv[1]).read())
print(json.dumps(base+extra,separators=(',',':')))
" <(printf '%s' "$_extra_tool_defs") <(printf '%s' "$tools") 2>/dev/null || echo "$tools")
            # Remove the meta _enabled_toolsets entry from skill_tools before merge
            skill_tools=$(python3 -c "
import json,sys
st=json.loads(open(sys.argv[1]).read())
print(json.dumps([x for x in st if not (isinstance(x,dict) and '_enabled_toolsets' in x)],separators=(',',':')))
" <(printf '%s' "$skill_tools") 2>/dev/null || echo "$skill_tools")
        fi
        tools=$(python3 -c "import json,sys; print(json.dumps(json.loads(open(sys.argv[1]).read())+json.loads(open(sys.argv[2]).read()),separators=(',',':')))" <(printf '%s' "$tools") <(printf '%s' "$skill_tools"))
    fi
  fi
  
  local _hist_for_api
  _hist_for_api=$(_apply_provider_history_filter "$HISTORY") || _hist_for_api="$HISTORY"

  local _extra_payload="{}"
  if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_extra_payload_json" >/dev/null 2>&1; then
    _extra_payload=$(${PROVIDER}_extra_payload_json 2>/dev/null) || _extra_payload="{}"
  fi

  # Memory auto-prefetch (hermes queue_prefetch_all pattern):
  # Results are pre-warmed by the PREVIOUS turn into a cache file — zero latency hot path.
  # If cache is cold (first turn), fall back to a quick inline search (1.5s timeout).
  local _mem_prefetch=""
  if [[ "${MEMORY_PREFETCH:-1}" != "0" ]]; then
    local _prefetch_cache="${DIR:-$(pwd)}/brain/state/prefetch_${session_id:-default}"
    if [[ -f "$_prefetch_cache" ]]; then
        # Hot path: use pre-warmed result from previous turn
        _mem_prefetch=$(cat "$_prefetch_cache" 2>/dev/null || true)
        rm -f "$_prefetch_cache"  # consume it
    else
        # Cold path: inline search with short timeout (first turn or cache miss)
        local _prefetch_query
        _prefetch_query=$(python3 -c "
import json, sys, re
h = json.loads(open(sys.argv[1]).read())
for msg in reversed(h):
    if msg.get('role') == 'user':
        c = msg.get('content','')
        if isinstance(c, list): c = ' '.join(p.get('text','') for p in c if isinstance(p,dict))
        c = re.sub(r'\[SYSTEM: Context Updated\].*?\n\n', '', str(c), flags=re.DOTALL).strip()
        print(c[:300])
        break
" <(printf '%s' "$_hist_for_api") 2>/dev/null || true)
        if [[ ${#_prefetch_query} -gt 20 ]]; then
            _mem_prefetch=$(timeout 2 python3 tools/memory_helper.py search "$_prefetch_query" 3 2>/dev/null || true)
        fi
    fi
  fi

  # Write large blobs to tempfiles to avoid ARG_MAX / env-size limits.
  local _hist_file _sys_file _mem_file
  _hist_file=$(mktemp)
  _sys_file=$(mktemp)
  _mem_file=$(mktemp)
  printf '%s' "$_hist_for_api" > "$_hist_file"
  printf '%s' "$system_prompt" > "$_sys_file"
  printf '%s' "$_mem_prefetch" > "$_mem_file"

  TOOLS="$tools" \
  HIST_FILE="$_hist_file" \
  SYS_FILE="$_sys_file" \
  MEM_FILE="$_mem_file" \
  MODEL_NAME="$_model" \
  EXTRA_PAYLOAD="$_extra_payload" \
  STREAM_MODE="$stream" \
  PROVIDER_NAME="$PROVIDER" \
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

# Memory auto-prefetch injection (hermes build_memory_context_block pattern):
# inject into last user message only — preserves system prompt prefix cache
mem_raw = ""
try:
    mem_file = os.environ.get("MEM_FILE", "")
    if mem_file:
        mem_raw = open(mem_file).read().strip()
except Exception:
    pass
if mem_raw and "No memories found" not in mem_raw:
    fence = (
        "<memory-context>\n"
        "[System note: The following is recalled memory context, "
        "NOT new user input. Treat as authoritative reference — "
        "this is the agent persistent memory.]\n\n"
        f"{mem_raw}\n"
        "</memory-context>"
    )
    for i in range(len(h)-1, -1, -1):
        if h[i].get("role") == "user":
            c = h[i].get("content", "") or ""
            if isinstance(c, str):
                h[i] = dict(h[i], content=c + "\n\n" + fence)
            elif isinstance(c, list):
                h[i] = dict(h[i], content=list(c) + [{"type": "text", "text": "\n\n" + fence}])
            break

# Guard: Vertex/Gemini rejects payloads with no user messages ("Model input cannot be empty")
# If history has no user/assistant messages, bail early with a clear error
has_user = any(msg.get("role") in ("user", "assistant") for msg in h)
if not h or not has_user:
    sys.stderr.write("GUARD: empty history — no user messages, skipping API call\n")
    sys.exit(2)

provider = os.environ.get("PROVIDER_NAME", "")
is_anthropic = provider == "anthropic"

if is_anthropic:
    # Anthropic native format: system as array + cache_control for 90% cost reduction
    # System prompt is stable across turns → qualifies for 5-min ephemeral cache
    system_msg = [{"type": "text", "text": s, "cache_control": {"type": "ephemeral"}}]
    msg = h  # no system role in messages for Anthropic native
    body = {"model": m, "system": system_msg, "messages": msg}
else:
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
    if not is_anthropic:
        body["stream_options"] = {"include_usage": True}
body.update(ex)
print(json.dumps(body))
'
  local _py_status=$?
  rm -f "$_hist_file" "$_sys_file" "$_mem_file"
  return $_py_status
}

call_api() {
  local sys_prompt_override="$1"

  local attempt=1
  local max_attempts=5
  while [ "$attempt" -le "$max_attempts" ]; do
      # Pool: pick best available provider/key for this attempt
      pool_apply "$attempt"

      # Provider-specific call_api override (e.g. ollama native API)
      if [ "$PROVIDER" != "default" ] && type "${PROVIDER}_call_api" >/dev/null 2>&1; then
          "${PROVIDER}_call_api" "$sys_prompt_override"
          local _ret=$?
          if [[ $_ret -eq 0 ]]; then return 0; fi
          # Failed — if pool can try another entry, rotate
          if [[ "$(pool_is_enabled)" == "true" && "$attempt" -lt "$max_attempts" ]]; then
              pool_mark_limited "${_POOL_IDX:-}" 60
              local _jdelay; _jdelay=$(python3 -c "import random; a=$attempt; d=min(5.0*(2**(a-1)),60.0); print(f'{d+random.uniform(0,0.5*d):.1f}')" 2>/dev/null || echo $((5 * attempt)))
              attempt=$((attempt + 1)); sleep "$_jdelay"; continue
          fi
          return $_ret
      fi

      if ! check_rate_limit "$PROVIDER" "$MODEL"; then
          if [[ "$(pool_is_enabled)" == "true" ]]; then
              sleep 3  # pool will rotate to next entry
          else
              # No pool — wait the actual remaining backoff time instead of making a
              # doomed API call that just re-extends the 60s rate limit timer.
              local _rl_remaining
              _rl_remaining=$(python3 -c "
import json, time
try:
    d = json.load(open('brain/state/rate_limits.json'))
    until = float(d.get('${PROVIDER}_${MODEL}', 0))
    print(max(5, int(until - time.time()) + 3))
except: print(10)
" 2>/dev/null || echo 10)
              echo "AMA: Rate-limited, waiting ${_rl_remaining}s for quota reset..." >&2
              sleep "$_rl_remaining"
          fi
      fi

      # Build payload and request args fresh for this attempt (provider/model may differ)
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
          _extra_pairs=$(python3 -c '
import json,sys
for k,v in json.loads(open(sys.argv[1]).read()).items():
    if v is None:
        if k.lower()=="authorization": print("SUPPRESS_AUTH")
    else:
        print(f"{k}\t{v}")
' <(printf '%s' "$_pheaders") 2>/dev/null) || true
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
      _cls_parsed=$(python3 -c "
import json, sys
d = json.loads(open(sys.argv[1]).read())
print(d.get('reason','unknown'))
print(d.get('retryable','false'))
print(d.get('should_compress','false'))
" <(printf '%s' "$classification") 2>/dev/null)
      local reason retryable should_compress
      IFS=$'\n' read -r reason retryable should_compress <<< "$_cls_parsed"

      if [[ "$reason" == "rate_limit" ]]; then
          mark_rate_limited "$PROVIDER" "$MODEL" 60
          pool_mark_limited "${_POOL_IDX:-}" 60
      fi

      # Log error for reflection
      local err_entry
      err_entry=$(python3 -c "
import json, sys
ts, prov, mod, code, rsn = sys.argv[1:6]
body = open(sys.argv[6]).read()
print(json.dumps({'ts': ts, 'provider': prov, 'model': mod, 'code': code, 'reason': rsn, 'body': body}))
" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$PROVIDER" "$MODEL" "$code" "$reason" <(printf '%s' "$body"))
      echo "$err_entry" >> "brain/state/error_log.jsonl"

      if [[ "$retryable" == "true" && "$attempt" -lt "$max_attempts" ]]; then
          local delay
          if [[ "$reason" == "rate_limit" ]]; then
              # Wait until the actual rate limit expires — short waits just re-extend it.
              delay=$(python3 -c "
import json, time
try:
    d = json.load(open('brain/state/rate_limits.json'))
    until = float(d.get('${PROVIDER}_${MODEL}', 0))
    print(max(15, int(until - time.time()) + 5))
except: print(60)
" 2>/dev/null || echo 60)
          else
              delay=$(python3 -c "import random; a=$attempt; d=min(5.0*(2**(a-1)),60.0); print(int(d+random.uniform(0,0.5*d)))" 2>/dev/null || echo $((5 * attempt)))
          fi
          echo "AMA: API Error $code ($reason), retrying in ${delay}s ($attempt/$max_attempts)" >&2

          # Pool handles rotation; static FALLBACK_PROVIDER only applies when pool is off
          if [[ "$(pool_is_enabled)" != "true" ]]; then
              if [[ "$attempt" -ge 2 && -n "${FALLBACK_PROVIDER:-}" ]]; then
                  local _fb_provider _fb_model
                  _fb_provider=$(echo "$FALLBACK_PROVIDER" | cut -d: -f1)
                  _fb_model=$(echo "$FALLBACK_PROVIDER" | cut -d: -f2-)
                  if [[ -n "$_fb_provider" && "$PROVIDER" != "$_fb_provider" ]]; then
                      echo "AMA: Activating fallback provider $_fb_provider:${_fb_model}" >&2
                      PROVIDER="$_fb_provider"
                      [[ -n "$_fb_model" ]] && MODEL="$_fb_model"
                      if type "${PROVIDER}_activate" >/dev/null 2>&1; then
                          ${PROVIDER}_activate 2>/dev/null || true
                      fi
                  fi
              elif [[ ("$reason" == "rate_limit" || "$reason" == "server_error") && -n "${FALLBACK_MODEL:-}" && "$MODEL" != "$FALLBACK_MODEL" ]]; then
                  echo "AMA: Switching to fallback model $FALLBACK_MODEL" >&2
                  MODEL="$FALLBACK_MODEL"
              fi
          fi

          sleep "$delay"
          attempt=$((attempt + 1))
          continue
      fi

      echo "FAIL:$code:$body"
      return 1
  done
}
