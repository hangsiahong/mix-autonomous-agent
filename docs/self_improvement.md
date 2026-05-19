# Self-Improvement & Autonomy

AMA includes several mechanisms that let it learn from itself, work autonomously, and recover from failures without user intervention.

## Curator — async self-learning { #curator }

**What**: After every tool-heavy turn (≥3 tool calls + clean completion), a background sub-agent reviews the conversation and patches durable knowledge into persistent state.

**Implementation**: [`core/mix/26_reflection.sh::curate_session`](../core/mix/26_reflection.sh). Spawned via the `( ( cmd ) & )` detach idiom so it survives `run_agent`'s EXIT trap.

**What it can edit**:
- `brain/state/MEMORY.md` — agent notes (preferences, env quirks, recurring issues)
- `brain/state/USER.md` — user profile facts
- `brain/skills/*/prompt.md` — skill prompts (e.g. bake a discovered API contract)

**What it cannot edit**:
- `core/*` or `tools/*` — harness code stays off-limits to autonomous edits

**Inputs**:
- Current MEMORY.md / USER.md / active skill prompt
- Trajectory of the just-completed session (last 14 messages, args truncated)
- Cross-session patterns from `error_log.jsonl` + `tool_usage.jsonl` (recurring errors/tools)

**Output**:
- Up to 3 changes per pass
- Logs to `logs/curator.log`
- One-line summaries like `Curator applied 2 change(s)`

**Disable**: `AMA_CURATOR=0` in env.

**Cost**: ~0.5-2k tokens per curation, runs only on substantial turns. Net positive — bakes-in discoveries that would otherwise be re-discovered every session.

**Example**: agent burns 5 tool calls discovering an API uses camelCase → curator notices this in the trajectory → patches the skill prompt to include a working curl template → next session the agent does the task in 1 call.

## `/goal` — autonomous goal loop { #goal-loop }

**What**: User sets a standing goal. Agent runs one turn, a tiny judge call decides DONE / CONTINUE / FAIL. CONTINUE re-queues the goal; loop repeats up to max_turns.

**Implementation**: [`core/mix/29_goal_loop.sh`](../core/mix/29_goal_loop.sh).

**Usage**:
```
/goal scrape today's top 5 Hacker News posts and save titles+links to /tmp/hn.md
/goal status     ← see current goal + judge verdict
/goal pause      ← stop looping; /goal resume to continue
/goal stop       ← clear goal entirely
/goal max 30     ← change max turns
```

**State**: `brain/state/goal_<sid>.json` — `{text, max_turns, turns_used, status, started_at, last_verdict, last_reason}`.

**Auto-pause**: any non-/goal user message during an active loop pauses it so your message takes priority. `/goal resume` to continue.

**Judge**: separate API call per loop iteration with `THINKING_BUDGET=none` and `AMA_TOOLS_OVERRIDE=[]` (no tools, no thinking — ~200 tokens). Returns one of:
- `DONE` — loop ends
- `CONTINUE: <hint>` — re-queue with the hint appended
- `FAIL: <reason>` — loop ends with an alert

**Failure modes the judge catches**:
- Agent asked the user a clarifying question → `FAIL: agent needs user input`
- Hit auth/permission wall it can't fix → `FAIL: <reason>`

**Disable**: `AMA_GOAL_LOOP=0` in env.

## `/btw` — ephemeral side-question { #btw }

**What**: Ask the agent a quick question that uses the current session as context but doesn't write to history, doesn't run tools, doesn't think (forced fast/cheap).

**Implementation**: [`core/mix/25_btw.sh`](../core/mix/25_btw.sh).

**Usage**:
```
You: build me an awwwards landing for a coffee shop
Agent: [working on it, multiple tool calls...]
You: /btw what colour palette did I mention earlier?
Agent: 💡 You said muted earth tones — sand, terracotta, deep olive.
       — /btw side answer (not saved to history)
```

**Properties**:
- Reads history file for context but never writes
- Tools disabled (`AMA_TOOLS_OVERRIDE=[]`)
- Thinking disabled (`THINKING_BUDGET=none`)
- `_AMA_NO_RATE_MARK=1` so failures don't poison the main session's rate-limit state
- Dispatched via detached subshell — runs in parallel with active turn
- Reply prefixed with 💡 + dim "not saved" footer for visual distinction

Lifted from openclaw's `/btw` pattern with their `<btw_side_question>` + `<in_flight_main_task>` XML tag trick to stop the model from continuing the user's main task.

## Scheduler — recurring tasks { #scheduler }

**What**: Schedule any prompt to run every N hours/days, optionally pinned to a specific (cheap) model/provider.

**Implementation**: [`tools/scheduler.sh`](../tools/scheduler.sh) + [`extensions/cron/run.sh`](../extensions/cron/run.sh).

**Usage** — both work, same tool under the hood:

Natural language:
```
You: ama, every 12 hours summarize today's transactions, use koompi-free to save cost
Agent: ✓ Scheduled task #1 (every 12h) · model=koompi-free, provider=kconsole
       Next run: 2026-05-20 01:50
```

Slash command:
```
/schedule add every=12h "summarize today's transactions" model=koompi-free provider=kconsole
/schedule list           ← show all
/schedule remove 1
/schedule pause 1        /schedule resume 1
```

**State**: `brain/state/scheduled_tasks.json` — atomic writes via tmp+mv.

**Firing**:
1. Cron tick (every 5min) runs `scheduler.sh run_due` → emits one record per due task
2. For each record: cron writes `[SCHEDULED #N] <prompt>` to `queue_<sid>` + sidecar `sched_override_<sid>_<N>.json` containing `{model, provider, skill}`
3. The bot's queue handler at the end of `run_agent` picks up the queued message
4. `run_agent` detects the `[SCHEDULED #N]` prefix, reads the sidecar, applies model/provider/skill override **for that one turn only**, runs normally, replies in the same chat

**Skipping duplicates**: if a task's previous fire is still pending in the queue (e.g. user has been idle), cron skips re-firing instead of piling up. Prevents "user types after 1h → gets flooded with 12 reminders" failure mode.

**Failure policy**: on failure, scheduler.sh marks `consecutive_failures += 1` and bumps `next_run = now` so the next tick retries. After 2 consecutive failures, status → `paused` and TG_ADMIN gets a Telegram alert.

**Min interval**: 60s, but cron tick is 5min so anything under ~5m fires at the cron cadence (effectively once per 5 minutes). For sub-5-min you'd need to drop the cron sleep — see `extensions/cron/init.sh`.

## Reflection + session recap

Two lighter background tasks that run after every tool-heavy turn (before the curator):

**`reflect_turn`** (`core/mix/26_reflection.sh`): a read-only inspection pass. Looks at recent errors via `read_error_log` and saves any high-signal facts to LanceDB via `memory_remember`. Tools allowed: only memory/inspect/search/clarify — no file editing.

**`save_session_recap`** (`core/mix/26_reflection.sh`): asks the LLM to produce a 4-section recap (Summary / Key Facts / Unresolved / Next Steps) and appends to `brain/state/session_recaps.jsonl`. The last 3 recaps are auto-injected into every subsequent session's system prompt under `## Recent Session Recaps`. Also stored as discrete LanceDB entries for semantic recall.

These together with the curator form the self-learning loop:
- **Reflection** notices things → stores them
- **Recap** summarizes → enables continuity across sessions
- **Curator** decides what's worth baking into the persistent prompts → does it

## Self-healing — `heal_request.json`

A separate, cron-driven loop for HARNESS-level errors (vs. session-level learning above).

**Implementation**: [`tools/error_analyzer.py`](../tools/error_analyzer.py) + [`extensions/cron/run.sh`](../extensions/cron/run.sh) + [`core/mix/27_self_heal.sh`](../core/mix/27_self_heal.sh).

**Flow**:
1. Cron runs `error_analyzer.py report` every 5min on `brain/state/error_log.jsonl`
2. If patterns are detected (same error 3+ times in 24h), writes `brain/state/heal_request.json`
3. On next agent session, `self_heal_if_needed` picks up the request and runs an autonomous diagnostic+fix turn
4. TG_ADMIN gets a Telegram alert with the pattern summary

**Disable cron**: comment out the loop in `extensions/cron/init.sh`.

## Token budget self-awareness

Every turn, `context_prompt` includes a budget bullet:

```
- **Token budget**: session 23.4k (5 turns, 4.7k avg) · last turn 5.2k · ctx 12% used
```

Computed from `usage_log.jsonl` filtered to the current session (anchored by the history file's mtime — resets on `/new`). If the current session is burning >1.5× the rolling baseline avg/turn, a `⚠ above baseline` flag is added — nudges the model to self-throttle.

**Implementation**: [`core/mix/24_agent_loop.sh`](../core/mix/24_agent_loop.sh) inline Python that reads `usage_log.jsonl`.

## Knobs summary

| Env var | What it does |
|---|---|
| `AMA_CURATOR=0` | Disable async curator |
| `AMA_GOAL_LOOP=0` | Disable goal loop |
| `AMA_GOAL_MAX_TURNS=N` | Default max turns for goal loops (default 20) |
| `MEMORY_PREFETCH=0` | Disable per-turn vector-memory prefetch |
| `THINKING_BUDGET=none\|low\|medium\|high` | Gemini thinking depth per session |
| `TASK_TIER=fast\|standard\|power` | Route to specific pool tier |
| `DECAY_KEEP=4` | History decay: keep last N tool exchanges in full |
| `DECAY_ARG_CAP=2000` | History decay: redact long write args after this many chars |
| `SESSION_IDLE_HOURS=N` | Auto-reset session after N hours idle (0 = never) |
| `ENABLE_GEMINI_CACHE=0` | Skip Vertex `cachedContents` lookups |
| `GEMINI_CACHE_TTL=3600` | Vertex cache TTL in seconds |
