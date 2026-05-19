# Architecture

AMA is a Bash-based agent harness that talks to Telegram, calls an LLM, runs tools, and persists state to disk. The whole thing is ~10k lines of shell + Python; one person can read and understand it in an afternoon.

## Turn flow

```
Telegram message
    │
    ▼
bot.sh ──── long-poll loop (curl getUpdates)
    │
    ▼
core/telegram/router.sh ──── parse update, detect slash commands,
    │                         auto-route to skill via keyword triggers
    ▼
run_agent (core/mix/24_agent_loop.sh)
    │
    ├── acquire flock on brain/state/locks/<sid>.lock
    ├── load_history (core/mix/11_history.sh)
    ├── build context_prompt (date, user, skill, budget, reply target)
    ├── per-task model/provider override (if [SCHEDULED #N])
    │
    └── loop up to MAX_TURNS:
        │
        ├── call_api_stream (core/mix/18_streaming_api_call.sh)
        │       │
        │       └── ${PROVIDER}_call_api_stream (providers/<name>.sh)
        │           or default OpenAI-compat path
        │
        ├── classify_error (core/mix/34_error_classifier.sh) — if failed
        │       │
        │       └── dispatch: rotate_pool | switch_model | disable_thinking |
        │                     reinline_cache | compress | fail_user | retry
        │
        ├── parse tool_calls
        │
        ├── execute tools (core/mix/22 or 23):
        │       single → process_tc (UI updates, run_tool, append result)
        │       batch  → execute_parallel_batch (when path-safe)
        │
        └── continue or break

    │
    ├── release lock
    │
    ├── goal-loop continuation? → judge (29_goal_loop.sh) → append to queue
    │
    └── post-turn background (detached subshell):
        ├── reflect_turn (LanceDB writes)
        ├── save_session_recap (session_recaps.jsonl)
        └── curate_session (edit MEMORY.md / USER.md / skill prompts)
            ↑ only on tool-heavy turns where learning likely
```

## Component map

| Component | Owns |
|---|---|
| `bot.sh` | Entry point. Single-instance lock, long-poll loop, SIGHUP hot-reload |
| `core/telegram/router.sh` | Update parsing, slash commands (/new, /goal, /btw, /schedule, ...), reply-context extraction |
| `core/telegram/api.sh` | Telegram HTTP helpers (`tg_send`, `tg_edit`, `tg_react`, ...) |
| `core/telegram/formatter.sh` | Markdown → Telegram HTML (delegates to `tools/md_to_html.py`) |
| `core/telegram/media.sh` | Photo/document download, base64 image part construction |
| `core/mix/init.sh` | Sources all engine files in order |
| `core/mix/01_config.sh` | Provider/model resolution, env precedence |
| `core/mix/11_history.sh` | History I/O, smart fold, decay, idle reset |
| `core/mix/13_tool_execution.sh` | `run_tool` dispatcher (TOOL_* env vars) |
| `core/mix/16_api.sh` | Payload build, prompt caching, error dispatch |
| `core/mix/17_response_parser.sh` | OpenAI-format normalization |
| `core/mix/18_streaming_api_call.sh` | Default streaming caller |
| `core/mix/22_process_one_tool_call.sh` | Single-tool dispatch + UI |
| `core/mix/23_parallel_tools.sh` | Parallel-safe batch executor |
| `core/mix/24_agent_loop.sh` | Main turn loop (`run_agent`) |
| `core/mix/25_btw.sh` | `/btw` ephemeral side-question |
| `core/mix/26_reflection.sh` | Post-turn reflection, session recap, curator |
| `core/mix/27_self_heal.sh` | Heal-request pickup at session start |
| `core/mix/29_goal_loop.sh` | `/goal` autonomous loop + judge |
| `core/mix/30_compression.sh` | LLM-based context compression at threshold |
| `core/mix/32_usage.sh` | Token usage logging + context warnings |
| `core/mix/34_error_classifier.sh` | 13-class error taxonomy + action verbs |
| `core/mix/35_provider_pool.sh` | Multi-provider routing, tier-based selection |
| `core/mix/36_think_scrubber.sh` | Strip reasoning blocks from visible output |
| `core/mix/38_rate_limit.sh` | Per-provider rate-limit tracking |
| `core/mix/40_trajectory.sh` | Log conversation trajectories |
| `core/mix/providers/*.sh` | Per-provider activation + custom streaming |
| `tools/*.sh` `*.py` | Every tool the agent can call (see `tools/README.md`) |
| `brain/system_prompt.md` | Base agent instructions (always injected) |
| `brain/tools.json` | Tool schemas, source of truth for `tools/README.md` |
| `brain/config.json` | Whitelist, default toolsets, topic→skill bindings |
| `brain/skills/*` | Domain skill prompts + per-skill toolsets (gitignored) |
| `extensions/cron/` | Background maintenance + scheduled-task firing |

## State files

| Path | Lifecycle |
|---|---|
| `brain/state/history_<sid>.json` | Per session, written every turn |
| `brain/state/sessions.db` | SQLite — metadata, FTS, lineage |
| `brain/state/session_recaps.jsonl` | Appended post-turn; last 100 kept |
| `brain/state/MEMORY.md` | Curated agent notes (curator + memory tool) |
| `brain/state/USER.md` | Curated user profile |
| `brain/state/scheduled_tasks.json` | Scheduler registry |
| `brain/state/locks/<sid>.lock` | flock — one agent per session |
| `brain/state/queue_<sid>` | Queued messages for next run_agent |
| `brain/state/run_<sid>.pid` | Active worker for `/stop` targeting |
| `brain/state/usage_log.jsonl` | Per-call token counts |
| `brain/state/error_log.jsonl` | Per-error structured log (for self-heal) |
| `brain/state/trajectories.jsonl` | Per-turn summary records |
| `~/ama_memory/` (LanceDB) | Vector memory (facts + session_recap blobs) |

## Key design choices

- **Bash-first.** Agent can self-modify any tool because tools are text files. Compile-time safety would have required a plugin layer; we picked editability.
- **Single source of truth per concern.** Markdown → HTML lives in `tools/md_to_html.py` only. Skill metadata in `brain/skills/*/prompt.md` only. Tool schemas in `brain/tools.json` only. No duplicates.
- **Detached background work.** Post-turn reflection/recap/curator run in `( ( cmd ) & )` orphan subshells so they survive `run_agent`'s EXIT trap. See [`feedback_bash_detach_idiom.md`](../memorybank/feedback_bash_detach_idiom.md) if you find this in our git history — it's load-bearing.
- **Per-turn context, cached prefix.** Date/cwd/token-budget/reply target go in the user message (volatile); base prompt + tools schema + skill prompt stay in `systemInstruction` (cacheable on providers that support it).
- **Errors are first-class.** Every non-200 is classified into one of 13 reasons with an explicit action verb the retry loop dispatches on. No bare `if status != 200: retry`.
