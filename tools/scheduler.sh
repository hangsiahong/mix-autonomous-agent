#!/bin/bash
# tools/scheduler.sh — recurring task scheduler for AMA.
#
# Storage: brain/state/scheduled_tasks.json (JSON array, atomic writes via tmp+mv).
# Cron tick frequency: 5 min (extensions/cron/init.sh). So intervals shorter than
# ~10 min lose accuracy.
#
# Actions:
#   add      — create a recurring task with optional model/provider/skill override
#   list     — show all scheduled tasks for this chat (or all if admin)
#   remove   — delete a task by id
#   pause    — temporarily disable a task
#   resume   — re-enable a paused task
#   run_due  — internal: fired by cron each tick; runs any due tasks
#
# Failure policy (per user choice 2026-05-19): on failure, mark task as
# `consecutive_failures += 1`. Next cron tick retries. After 2 consecutive
# failures, set status=paused and alert TG_ADMIN.
#
# Output to user on every run: "Always message me" mode (per user choice).

_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ROOT_DIR="$(cd "$_TOOLS_DIR/.." && pwd)"
_STATE_FILE="${_ROOT_DIR}/brain/state/scheduled_tasks.json"

action="${TOOL_action:-list}"

# ── helpers ────────────────────────────────────────────────────────────────
_init_state() {
    [[ -f "$_STATE_FILE" ]] && return
    mkdir -p "$(dirname "$_STATE_FILE")"
    echo '[]' > "$_STATE_FILE"
}

_write_state() {
    local _json="$1"
    local _tmp; _tmp=$(mktemp "${_STATE_FILE}.XXXXXX")
    printf '%s' "$_json" > "$_tmp" && mv "$_tmp" "$_STATE_FILE"
}

# Parse a duration string like "12h", "30m", "1d", "2h30m" → seconds.
# Stdin: the string; stdout: integer seconds (0 on parse failure).
_parse_duration() {
    python3 -c "
import sys, re
s = sys.stdin.read().strip().lower().replace(' ','')
total = 0
matched = False
for n, u in re.findall(r'(\d+)\s*([dhms])', s):
    matched = True
    n = int(n)
    if u == 'd': total += n * 86400
    elif u == 'h': total += n * 3600
    elif u == 'm': total += n * 60
    elif u == 's': total += n
if not matched and s.isdigit():
    total = int(s)  # bare integer = seconds
print(total if total > 0 else 0)
"
}

# Find next available task id (1-based, fills gaps)
_next_id() {
    python3 -c "
import json
try: tasks = json.load(open('$_STATE_FILE'))
except: tasks = []
used = {t.get('id', 0) for t in tasks}
i = 1
while i in used: i += 1
print(i)
"
}

case "$action" in
add)
    # Required: prompt + every (interval). Optional: model, provider, skill, chat_id, thread_id.
    prompt="${TOOL_prompt}"
    every="${TOOL_every}"
    model="${TOOL_model:-}"
    provider="${TOOL_provider:-}"
    skill="${TOOL_skill:-}"
    chat_id="${TOOL_chat_id:-${TOOL_CHAT_ID:-}}"
    thread_id="${TOOL_thread_id:-${TOOL_THREAD_ID:-}}"

    if [[ -z "$prompt" || -z "$every" ]]; then
        echo "Error: 'prompt' and 'every' are required. Example: every=\"12h\" prompt=\"summarize today\""
        exit 1
    fi
    if [[ -z "$chat_id" ]]; then
        echo "Error: chat_id is required (the Telegram chat to deliver results to)."
        exit 1
    fi

    secs=$(echo "$every" | _parse_duration)
    if [[ "$secs" -lt 60 ]]; then
        echo "Error: minimum interval is 60s (cron tick is 5min — sub-minute intervals are pointless)."
        exit 1
    fi

    _init_state
    id=$(_next_id)
    now=$(date +%s)

    PROMPT="$prompt" EVERY="$every" SECS="$secs" MODEL="$model" PROVIDER="$provider" \
    SKILL="$skill" CHAT_ID="$chat_id" THREAD_ID="$thread_id" ID="$id" NOW="$now" \
    python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try: tasks = json.load(open(path))
except: tasks = []
now = int(os.environ['NOW'])
secs = int(os.environ['SECS'])
tasks.append({
    'id':       int(os.environ['ID']),
    'every':    os.environ['EVERY'],
    'every_secs': secs,
    'prompt':   os.environ['PROMPT'],
    'model':    os.environ.get('MODEL',''),
    'provider': os.environ.get('PROVIDER',''),
    'skill':    os.environ.get('SKILL',''),
    'chat_id':  os.environ['CHAT_ID'],
    'thread_id': os.environ.get('THREAD_ID',''),
    'status':   'active',
    'last_run': 0,
    'next_run': now + secs,
    'consecutive_failures': 0,
    'total_runs': 0,
    'created_at': now,
})
open(path, 'w').write(json.dumps(tasks, indent=2))
import datetime
nr = datetime.datetime.fromtimestamp(now + secs).strftime('%Y-%m-%d %H:%M')
override = []
if os.environ.get('MODEL'): override.append(f"model={os.environ['MODEL']}")
if os.environ.get('PROVIDER'): override.append(f"provider={os.environ['PROVIDER']}")
if os.environ.get('SKILL'): override.append(f"skill={os.environ['SKILL']}")
ov_str = (' · ' + ', '.join(override)) if override else ''
print(f"✓ Scheduled task #{os.environ['ID']} (every {os.environ['EVERY']}){ov_str}")
print(f"  Next run: {nr}")
print(f"  Prompt: {os.environ['PROMPT'][:120]}")
PYEOF
    ;;

list)
    _init_state
    chat_id="${TOOL_chat_id:-${TOOL_CHAT_ID:-}}"
    CHAT_ID="$chat_id" python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys, datetime
try: tasks = json.load(open(sys.argv[1]))
except: tasks = []
cid = os.environ.get('CHAT_ID','')
if cid:
    tasks = [t for t in tasks if str(t.get('chat_id','')) == str(cid)]
if not tasks:
    print('(no scheduled tasks)')
    sys.exit(0)
now = int(__import__('time').time())
print(f"{len(tasks)} scheduled task{'s' if len(tasks)!=1 else ''}:")
for t in tasks:
    nr = int(t.get('next_run', 0))
    rem = nr - now
    if rem < 0: rel = 'overdue'
    elif rem < 3600: rel = f'in {rem//60}m'
    elif rem < 86400: rel = f'in {rem//3600}h'
    else: rel = f'in {rem//86400}d'
    icon = {'active':'▸','paused':'⏸','failed':'⚠'}.get(t.get('status','?'),'•')
    over = []
    if t.get('model'): over.append(f"model={t['model']}")
    if t.get('provider'): over.append(f"provider={t['provider']}")
    if t.get('skill'): over.append(f"skill={t['skill']}")
    ov = (' · ' + ', '.join(over)) if over else ''
    runs = t.get('total_runs', 0)
    fails = t.get('consecutive_failures', 0)
    fstr = f' · {fails} fail(s)' if fails else ''
    print(f"  {icon} #{t.get('id')} every {t.get('every','?')} — \"{t.get('prompt','')[:60]}\"{ov}")
    print(f"     next: {rel} · runs: {runs}{fstr} · status: {t.get('status')}")
PYEOF
    ;;

remove|delete)
    id="${TOOL_id:-${TOOL_task_id:-}}"
    if [[ -z "$id" ]]; then
        echo "Error: 'id' is required."
        exit 1
    fi
    _init_state
    ID="$id" python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try: tasks = json.load(open(path))
except: tasks = []
tid = int(os.environ['ID'])
before = len(tasks)
tasks = [t for t in tasks if t.get('id') != tid]
open(path, 'w').write(json.dumps(tasks, indent=2))
print(f"Removed task #{tid}" if len(tasks) < before else f"No task with id {tid}")
PYEOF
    ;;

pause|resume)
    id="${TOOL_id:-${TOOL_task_id:-}}"
    new_status=$([[ "$action" == "pause" ]] && echo "paused" || echo "active")
    if [[ -z "$id" ]]; then
        echo "Error: 'id' is required."
        exit 1
    fi
    _init_state
    ID="$id" STATUS="$new_status" python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys
path = sys.argv[1]
try: tasks = json.load(open(path))
except: tasks = []
tid = int(os.environ['ID'])
new_status = os.environ['STATUS']
hit = False
for t in tasks:
    if t.get('id') == tid:
        t['status'] = new_status
        if new_status == 'active':
            t['consecutive_failures'] = 0
        hit = True
        break
open(path, 'w').write(json.dumps(tasks, indent=2))
print(f"Task #{tid} → {new_status}" if hit else f"No task with id {tid}")
PYEOF
    ;;

run_due)
    # Internal: invoked by cron. Walks tasks, fires any active ones whose
    # next_run <= now. Does NOT block on the actual agent run — fires them
    # via the detached subshell pattern so the cron can return quickly.
    _init_state
    python3 - "$_STATE_FILE" "$_ROOT_DIR" <<'PYEOF'
import json, os, sys, time, subprocess
path, root = sys.argv[1], sys.argv[2]
try: tasks = json.load(open(path))
except: tasks = []
now = int(time.time())
dirty = False
for t in tasks:
    if t.get('status') != 'active': continue
    if int(t.get('next_run', 0)) > now: continue
    # Print the fire command so the calling bash can spawn it
    overrides = []
    if t.get('model'):    overrides.append(f"MODEL='{t['model']}'")
    if t.get('provider'): overrides.append(f"PROVIDER='{t['provider']}'")
    skill = t.get('skill','')
    chat_id   = t.get('chat_id','')
    thread_id = t.get('thread_id','')
    prompt    = t.get('prompt','').replace("'", "'\\''")
    # Emit one record per due task. ASCII RS (\x1f) as delimiter — using
    # \t (tab) here would COLLAPSE empty fields, because bash's read treats
    # whitespace IFS chars as "any-run is one separator". With \x1f bash
    # treats each one as a discrete field separator and empty fields stay
    # empty. (Caught live 2026-05-19: an empty thread_id+skill caused model
    # value to shift into the thread_id slot, breaking the session path.)
    sep = "\x1f"
    print(f"FIRE{sep}{t['id']}{sep}{chat_id}{sep}{thread_id}{sep}{skill}{sep}{t.get('model','')}{sep}{t.get('provider','')}{sep}{prompt}")
    dirty = True
if dirty:
    # Don't update next_run / counters here — the shell loop reports back via
    # mark_done / mark_failed below.
    pass
PYEOF
    ;;

mark_done)
    # Called by the cron after a successful run: updates last_run, next_run,
    # total_runs, clears consecutive_failures.
    id="${TOOL_id:-}"
    [[ -z "$id" ]] && exit 1
    _init_state
    ID="$id" python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys, time
path = sys.argv[1]
try: tasks = json.load(open(path))
except: tasks = []
tid = int(os.environ['ID'])
now = int(time.time())
for t in tasks:
    if t.get('id') == tid:
        t['last_run'] = now
        t['next_run'] = now + int(t.get('every_secs', 3600))
        t['total_runs'] = int(t.get('total_runs', 0)) + 1
        t['consecutive_failures'] = 0
        break
open(path, 'w').write(json.dumps(tasks, indent=2))
PYEOF
    ;;

mark_failed)
    # Increment consecutive_failures; pause + alert after 2.
    id="${TOOL_id:-}"
    reason="${TOOL_reason:-unknown}"
    [[ -z "$id" ]] && exit 1
    _init_state
    ID="$id" REASON="$reason" python3 - "$_STATE_FILE" <<'PYEOF'
import json, os, sys, time
path = sys.argv[1]
try: tasks = json.load(open(path))
except: tasks = []
tid = int(os.environ['ID'])
now = int(time.time())
out_action = ''
for t in tasks:
    if t.get('id') == tid:
        f = int(t.get('consecutive_failures', 0)) + 1
        t['consecutive_failures'] = f
        if f >= 2:
            t['status'] = 'paused'
            out_action = f"PAUSED\t{tid}\t{os.environ.get('REASON','')}"
        else:
            # Retry on next tick: schedule next_run = now (so it fires immediately next tick)
            t['next_run'] = now
            out_action = f"RETRY\t{tid}"
        break
open(path, 'w').write(json.dumps(tasks, indent=2))
print(out_action)
PYEOF
    ;;

*)
    echo "Usage: scheduler.sh action=<add|list|remove|pause|resume|run_due|mark_done|mark_failed> ..."
    echo "  add:    every=<12h|30m|1d> prompt=\"...\" [model=...] [provider=...] [skill=...] chat_id=..."
    echo "  list:   [chat_id=...]"
    echo "  remove: id=<n>"
    echo "  pause/resume: id=<n>"
    exit 1
    ;;
esac
