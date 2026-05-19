# Contributing to AMA

Thanks for the interest. AMA is a Bash-based Telegram agent harness — small enough that one person can read and understand the whole thing in an afternoon. This file tells you how to add to it without breaking it.

## Repo layout in 30 seconds

```
bot.sh                    # entry point, long-poll loop
core/
  mix/                    # the agent engine
    init.sh               # sources everything below
    11_history.sh         # message history (load/save/decay/compress)
    13_tool_execution.sh  # run_tool() dispatcher
    16_api.sh             # payload build + non-streaming API call
    18_streaming_api_call.sh   # streaming API call (default OpenAI-compat)
    22_process_one_tool_call.sh   # single-tool dispatch + UI
    23_parallel_tools.sh  # parallel-safe batch executor
    24_agent_loop.sh      # run_agent — the main turn loop
    25_btw.sh             # /btw ephemeral side-question
    26_reflection.sh      # post-turn reflection + curator
    29_goal_loop.sh       # /goal autonomous loop
    34_error_classifier.sh    # 13-class error taxonomy + actions
    35_provider_pool.sh   # multi-provider routing
    providers/            # per-provider streaming + auth (google, anthropic, kconsole, ...)
  telegram/
    router.sh             # update parsing + slash commands
    api.sh                # tg_send / tg_edit / tg_react / ...
    formatter.sh          # markdown → telegram-HTML
tools/                    # every TOOL_action=... bash script the agent can call
  README.md               # ← auto-generated tool index
brain/
  system_prompt.md        # base agent instructions
  tools.json              # tool schemas (source of truth for tools/README.md)
  config.example.json     # whitelist + topic skills (copy to config.json)
  provider_pool.json.example   # optional multi-provider pool
  skills/                 # gitignored — instance-specific skills
extensions/
  cron/                   # background maintenance + scheduler firing
```

A turn flows: Telegram → `bot.sh` → `router.sh` → `run_agent` (24_agent_loop.sh) → `call_api_stream` → tool dispatch → loop until done → render → save history.

## Adding a new tool

A tool is just a bash script under `tools/` that reads `TOOL_*` env vars and writes its result to stdout.

1. **Write `tools/<name>.sh`** that handles its arguments and prints an authoritative one-line result. Examples to model on: `tools/scheduler.sh`, `tools/access_control.sh`, `tools/send_file.sh`.

   ```bash
   #!/bin/bash
   # tools/my_tool.sh — one-line description
   action="${TOOL_action:-}"
   target="${TOOL_target:-}"
   if [[ -z "$target" ]]; then
       echo "Error: 'target' is required."
       exit 1
   fi
   # …do the work…
   echo "✓ my_tool: did <thing> on $target"
   ```

2. **Register in `brain/tools.json`** with name, one-sentence description, JSON-schema parameters, and a `toolset` (one of `core`/`search`/`memory`/`meta`/`inspect`/`media`/`kanban`). Keep the description tight — every word costs prompt tokens per turn.

3. **Regenerate the tool index:**
   ```sh
   python3 tools/_lib/gen_tool_index.py
   ```

4. **Smoke-test directly** without the bot:
   ```sh
   TOOL_action=foo TOOL_target=bar bash tools/my_tool.sh
   ```

**Output clarity matters.** Tools should return:
- Success → `✓ <action>: <one-line result>`
- Empty result → explicit `(no X found)` not just empty string
- Error → `Error: <reason>` prefix, exit non-zero

The agent reads the first non-empty line. Ambiguous output causes "let me verify" follow-up tool calls (waste of tokens).

## Adding a new skill

Skills are domain-specific prompts the agent auto-binds via keyword routing. They live in `brain/skills/<name>/` (gitignored — instance-specific) or `core/skills/<name>/` (shipped with AMA).

A skill is a directory:
```
brain/skills/my_skill/
  prompt.md     # YAML frontmatter + body
  tools.json    # optional — extra toolsets or per-skill tools
```

`prompt.md` frontmatter is **required** for auto-routing:
```markdown
---
description: One line — what this skill is for (shown in the skill index)
triggers: [keyword1, "phrase keyword", anothertrigger]
---
You are an expert assistant for <domain>.

## API contracts / templates / rules
…the actual skill body…
```

The router (`tools/skill_router.py`) matches user messages against `triggers` (phrases score 2, single short words score 1; min 2 to switch). Bake working contracts into the body — see `brain/skills/onedegree_walahe/prompt.md` for an example with full curl templates.

## Adding a new provider

A provider lives in `core/mix/providers/<name>.sh` and implements:

- `<name>_activate()` — set `BASE_URL` + `API_KEY` (called at bot start or per-turn override)
- Optional: `<name>_get_api_key()`, `<name>_extra_headers_json()`, `<name>_extra_payload_json()`, `<name>_filter_history()`, `<name>_call_api_stream()` for non-OpenAI-compat shapes

Most providers just need `<name>_activate`. Look at `core/mix/providers/kconsole.sh` for the minimum:

```bash
kconsole_activate() {
  BASE_URL="https://ai.koompi.cloud/v1"
  API_KEY="${KCONSOLE_AI_KEY:-${API_KEY:-}}"
}
```

For native streaming protocols (like Google's `streamGenerateContent`), see `core/mix/providers/google.sh` + `google_stream.py`.

## Code style

- **Bash strict-ish.** Use `local` inside functions. Quote variables. Prefer `[[ ]]` over `[ ]`. Don't shell out to `grep`/`awk` if a single python3 -c does it.
- **Top-of-file docstring** — 5-10 line block explaining what the file owns + the contract. See newer files (`24_agent_loop.sh`, `scheduler.sh`, `25_btw.sh`) for the style.
- **Tools return one-line summaries** (see above).
- **Comments explain *why*, not *what*.** The code shows what. The comment should explain the failure mode it's guarding against, the past incident, or the non-obvious constraint.

## Testing

There's a basic test runner in `scripts/run_all_tests.sh` and bash test stubs in `tests/`. Add tests for any non-trivial logic — the bugs we've hit historically (IFS-collapse, env-var-after-python, empty-history) would all have been caught by 20 lines of bats-style tests.

## Commit conventions

Match the existing log. Subject under 70 chars, body explains *why*, paragraphs separated by blank lines.

```
feat: short summary

Longer explanation of why this exists and the trade-off considered.
Reference incident logs or memory notes if relevant.

Co-Authored-By: <attribution if AI-assisted>
```

## When in doubt

Open an issue describing what you want to do before writing a lot of code. AMA is small enough that a 5-minute design check saves hours of rework.
