#!/bin/bash
# core/mix/35_provider_pool.sh - Multi-Provider Pool with Auto-Routing
#
# Reads brain/provider_pool.json and picks the best available (provider, key)
# for each API call. On 429, marks the entry rate-limited and retries with
# the next available entry.
#
# Config file: brain/provider_pool.json
# Rate limits:  brain/state/pool_limits.json

_POOL_FILE="brain/provider_pool.json"
_POOL_LIMITS_FILE="brain/state/pool_limits.json"
_POOL_IDX=""  # set by pool_apply; used by callers for pool_mark_limited

pool_is_enabled() {
    [[ -f "$_POOL_FILE" ]] || { echo "false"; return; }
    python3 -c "
import json, sys
try:
    d = json.load(open('brain/provider_pool.json'))
    print('true' if d.get('pool') else 'false')
except:
    print('false')
" 2>/dev/null || echo "false"
}

# Pick best pool entry for this attempt and export globals:
#   PROVIDER, API_KEY, BASE_URL, MODEL, _POOL_IDX
pool_apply() {
    local attempt="${1:-1}"
    [[ "$(pool_is_enabled)" != "true" ]] && return 0

    local _result
    _result=$(export _POOL_ATTEMPT="$attempt"; python3 - <<'PYEOF' 2>/dev/null
import json, time, os, sys

pool_file = 'brain/provider_pool.json'
limits_file = 'brain/state/pool_limits.json'
attempt = int(os.environ.get('_POOL_ATTEMPT', '1'))

try:
    data = json.load(open(pool_file))
    pool = data.get('pool', [])
except Exception:
    sys.exit(0)

if not pool:
    sys.exit(0)

limits = {}
try:
    limits = json.load(open(limits_file))
except Exception:
    pass

now = time.time()
strategy = data.get('strategy', 'fallback')

# Entries not currently rate-limited
available = [(i, e) for i, e in enumerate(pool)
             if now >= float(limits.get(str(i), 0))]

if not available:
    # All limited — pick entry whose limit expires soonest
    idx = min(range(len(pool)), key=lambda i: float(limits.get(str(i), 0)))
    entry = pool[idx]
elif strategy == 'round-robin':
    counter_file = 'brain/state/pool_counter'
    try:
        c = int(open(counter_file).read().strip())
    except Exception:
        c = 0
    pick = c % len(available)
    try:
        open(counter_file, 'w').write(str(c + 1))
    except Exception:
        pass
    idx, entry = available[pick]
else:
    # fallback: rotate through available entries by attempt number
    # so attempt 1→first, attempt 2→second, etc.
    pick = (attempt - 1) % len(available)
    idx, entry = available[pick]

print(json.dumps({
    'idx': idx,
    'provider': entry.get('provider', ''),
    'key': entry.get('key', ''),
    'model': entry.get('model', ''),
    'base_url': entry.get('base_url', ''),
    'label': entry.get('label', f'pool-{idx}'),
}))
PYEOF
    )

    [[ -z "$_result" ]] && return 0

    # Parse fields from JSON result
    local _p_idx _p_provider _p_key _p_model _p_base_url _p_label
    _p_idx=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('idx',''))" 2>/dev/null)
    _p_provider=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('provider',''))" 2>/dev/null)
    _p_key=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('key',''))" 2>/dev/null)
    _p_model=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('model',''))" 2>/dev/null)
    _p_base_url=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('base_url',''))" 2>/dev/null)
    _p_label=$(printf '%s' "$_result" | python3 -c "import json,sys; print(json.loads(sys.stdin.read()).get('label','pool'))" 2>/dev/null)

    _POOL_IDX="$_p_idx"
    [[ -n "$_p_provider" ]] && PROVIDER="$_p_provider"

    if [[ -n "$_p_key" ]]; then
        API_KEY="$_p_key"
        # For Google Studio: set env vars google_get_api_key() reads
        if [[ "$PROVIDER" == "google" ]]; then
            GOOGLE_API_KEY="$_p_key"
            GEMINI_KEY="$_p_key"
        fi
    fi

    [[ -n "$_p_model" ]] && MODEL="$_p_model"

    # Set BASE_URL: explicit override > google studio > provider activate
    if [[ -n "$_p_base_url" ]]; then
        BASE_URL="$_p_base_url"
    elif [[ "$PROVIDER" == "google" && -n "$_p_key" ]]; then
        # Pool google entries always use Studio (API key) mode, not Vertex
        BASE_URL="https://generativelanguage.googleapis.com/v1beta/openai"
    elif [[ "$PROVIDER" != "default" ]] && type "${PROVIDER}_activate" >/dev/null 2>&1; then
        ${PROVIDER}_activate 2>/dev/null || true
        # If entry had explicit base_url, override what activate set
        [[ -n "$_p_base_url" ]] && BASE_URL="$_p_base_url"
    fi

    echo "AMA: Pool → [${_p_label}] ${PROVIDER}/${MODEL}" >&2
    return 0
}

# Mark a pool entry as rate-limited for <delay> seconds
pool_mark_limited() {
    local idx="${1:-}"
    local delay="${2:-60}"
    [[ -z "$idx" ]] && return 0

    mkdir -p "brain/state"
    local _until=$(( $(date +%s) + delay ))
    python3 -c "
import json, sys
f = 'brain/state/pool_limits.json'
try: d = json.load(open(f))
except: d = {}
d[sys.argv[1]] = int(sys.argv[2])
open(f, 'w').write(json.dumps(d))
" "$idx" "$_until" 2>/dev/null || true
    echo "AMA: Pool entry ${idx} rate-limited for ${delay}s" >&2
}

# Returns formatted HTML status string for /providers command
pool_status_html() {
    [[ "$(pool_is_enabled)" != "true" ]] && echo "No pool configured." && return 0

    python3 - <<'PYEOF' 2>/dev/null
import json, time, os

pool_file = 'brain/provider_pool.json'
limits_file = 'brain/state/pool_limits.json'

try:
    data = json.load(open(pool_file))
    pool = data.get('pool', [])
    strategy = data.get('strategy', 'fallback')
except Exception:
    print("Error reading pool config.")
    import sys; sys.exit(0)

limits = {}
try:
    limits = json.load(open(limits_file))
except Exception:
    pass

now = time.time()
lines = [f"<b>Provider Pool</b>  strategy: <code>{strategy}</code>  ({len(pool)} entries)\n"]

for i, entry in enumerate(pool):
    label = entry.get('label', f'pool-{i}')
    provider = entry.get('provider', '?')
    model = (entry.get('model', '') or '')[:28]
    key = entry.get('key', '')
    key_hint = f"…{key[-5:]}" if len(key) >= 5 else ''

    limited_until = float(limits.get(str(i), 0))
    if limited_until > now:
        secs = int(limited_until - now)
        icon = '🔴'
        status = f"limited {secs}s"
    else:
        icon = '✅'
        status = 'active'

    model_str = f"/{model}" if model else ''
    lines.append(f"{icon} <code>{label}</code>  {provider}{model_str}  {key_hint}  [{status}]")

print("\n".join(lines))
PYEOF
}
