# Tool Index

Every tool the agent can call, grouped by toolset. This file is auto-generated from [`brain/tools.json`](../brain/tools.json) — regenerate with `python3 tools/_lib/gen_tool_index.py` whenever you add or change a tool.

Toolsets the agent loads by default come from `brain/config.json` → `default_toolsets`. Skills can pull in additional toolsets via their own `tools.json` (`_enabled_toolsets`).

## `core` toolset

_Always loaded. The agent's bread-and-butter._

### `access_control`

Manage whitelist. Actions: whitelist (add), revoke (remove), sethome (set home_chat), log (show last 20 changes). Every mutation auto-logged to brain/state/access_control.log — use action=log to find who was last added/removed instead of grepping session history.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `whitelist | revoke | sethome | log` |
| `target_id` |  | User or chat ID. Required for whitelist/revoke/sethome. |

**Source:** [`tools/access_control.sh`](../tools/access_control.sh)

### `bash`

Run a bash command in the project directory. Capped at `timeout` seconds (default 30, max 120).

**Parameters**

| Name | Required | Description |
|---|---|---|
| `command` | ✓ | The command. |
| `timeout` |  | Kill after N seconds. Default 30, max 120. |

**Source:** [`tools/bash.sh`](../tools/bash.sh)

### `clarify`

Ask the user a clarifying question. Stops the turn and waits.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `question` | ✓ |  |

**Source:** [`tools/clarify.sh`](../tools/clarify.sh)

### `edit_code`

Replace old_string with new_string in a file. Tolerates whitespace drift. Match must be unique unless replace_all=true. Returns unified diff.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `path` | ✓ |  |
| `old_string` | ✓ | Multi-line OK. |
| `new_string` | ✓ | Multi-line OK. |
| `replace_all` |  |  |

**Source:** [`tools/edit_code.sh`](../tools/edit_code.sh)

### `patch`

Apply a V4A-format multi-file/multi-hunk patch. Validates all hunks before writing any.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `patch` | ✓ | Full V4A patch text incl. *** Begin Patch / *** End Patch. |

**Source:** [`tools/patch.sh`](../tools/patch.sh)

### `read_code`

Read a file with line numbers. Use this before edit_code/patch — never guess content.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `path` | ✓ | Relative path within the project. |
| `offset` |  | 1-based starting line. Default 1. |
| `limit` |  | Max lines (default 500, max 2000). |

**Source:** [`tools/read_code.sh`](../tools/read_code.sh)

### `send_file`

Send a file from disk to the Telegram chat. Use when user asks to download/share a file.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `path` | ✓ |  |
| `caption` |  |  |
| `chat_id` |  | Default: current chat. |
| `thread_id` |  |  |

**Source:** [`tools/send_file.sh`](../tools/send_file.sh)

### `write_file`

Create or overwrite a file. Prefer edit_code/patch for existing files. Syntax-checked for .sh/.py/.json.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `path` | ✓ | Relative path. |
| `content` | ✓ | Full content. |
| `append` |  | Append instead of overwrite. |

**Source:** [`tools/write_file.sh`](../tools/write_file.sh)


## `search` toolset

_Always loaded. Reach out to the web / filesystem for information._

### `browser`

Headless Chromium for JS-heavy pages. Use when fetch_url fails. Actions: navigate, snapshot, click, type, scroll.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `navigate | snapshot | click | type | scroll` |
| `url` |  | Required for navigate. |
| `selector` |  | CSS selector or visible text. |
| `text` |  | Required for type. |

**Source:** [`tools/browser.sh`](../tools/browser.sh)

### `fetch_url`

Fetch a URL as clean Markdown via Jina Reader. Pass `query` to extract a specific portion.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `url` | ✓ | Public http/https URL. |
| `query` |  | Optional: what to extract from the page. |
| `max_chars` |  | Truncation cap, default 8000. |

**Source:** [`tools/fetch_url.sh`](../tools/fetch_url.sh)

### `list_files`

List files in a project directory (depth=2, hidden files excluded).

**Parameters**

| Name | Required | Description |
|---|---|---|
| `directory` |  | Relative path. Default: project root. |

**Source:** [`tools/list_files.sh`](../tools/list_files.sh)

### `search_files`

grep a pattern across project files. Returns file:line matches.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `pattern` | ✓ | Text or regex. |
| `path` |  | Directory or file. Default: project root. |
| `file_glob` |  | e.g. '*.sh'. |
| `ignore_case` |  |  |

**Source:** [`tools/search_files.sh`](../tools/search_files.sh)

### `web_search`

Search the web. Returns titles, URLs, snippets.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `query` | ✓ | Search query. |
| `limit` |  | 1-15, default 8. |

**Source:** [`tools/web_search.sh`](../tools/web_search.sh)


## `memory` toolset

_Always loaded. Persistent + vector + session memory._

### `last_session`

Instant recall of recent session recaps (~0.1s, no embeddings). Use when user asks about past sessions.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `n` |  | Default 3. |
| `session` |  |  |

**Source:** [`tools/last_session.sh`](../tools/last_session.sh)

### `memory`

Curated MEMORY.md / USER.md notes (injected every turn). Actions: add, replace, remove, read.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `add | replace | remove | read` |
| `target` |  | `memory | user` — memory=agent notes (3KB cap), user=user profile (2KB cap). |
| `content` |  | Required for add. |
| `old_text` |  | Unique substring. Required for replace/remove. |
| `new_content` |  | Required for replace. |

**Source:** [`tools/memory.sh`](../tools/memory.sh)

### `memory_recall`

Semantic search over long-term memory. Try 2-3 phrasings if empty.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `query` | ✓ |  |
| `limit` |  | Default 3. |

**Source:** [`tools/memory_recall.sh`](../tools/memory_recall.sh)

### `memory_remember`

Save text to long-term vector memory (LanceDB). Include topic in metadata_json.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `text` | ✓ |  |
| `metadata_json` |  | e.g. '{"topic":"..."}'. |

**Source:** [`tools/memory_remember.sh`](../tools/memory_remember.sh)

### `recap`

Summarize current session (or specific session) from raw logs. Faster than session_search for current chat.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `session_id` |  | Auto-detected if omitted. |
| `last_n` |  | Default 20. |

**Source:** [`tools/recap.sh`](../tools/recap.sh)

### `session_search`

Search past sessions by keyword/topic. Returns ranked summaries.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `query` | ✓ |  |
| `session` |  | Optional: specific session ID. |
| `limit` |  | 1-5, default 3. |

**Source:** [`tools/session_search.sh`](../tools/session_search.sh)


## `meta` toolset

_Always loaded. Tools that act on the harness itself._

### `custom_tool_manager`

Create/list/delete custom tools (saved to tools/custom/, survives Docker rebuilds).

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `create | list | delete` |
| `name` |  | No spaces. |
| `description` |  |  |
| `code` |  | Bash script body. |
| `parameters_json` |  | JSON schema of params. |

**Source:** [`tools/custom_tool_manager.sh`](../tools/custom_tool_manager.sh)

### `process`

Run/manage background shell processes. Actions: run, list, output, kill.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `run | list | output | kill` |
| `command` |  | Required for run. |
| `name` |  | Label for output/kill. Auto-generated otherwise. |

**Source:** [`tools/process.sh`](../tools/process.sh)

### `repo_map`

File tree + symbols via ripgrep. Use before editing to locate logic.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `depth` |  | Default 3. |

**Source:** [`tools/repo_map.sh`](../tools/repo_map.sh)

### `scheduler`

Schedule recurring tasks. Actions: add (create), list (show all for this chat), remove (delete by id), pause, resume. For add: requires `prompt` + `every` (e.g. '12h', '30m', '1d'). Optional model/provider/skill override pins the task to a specific (e.g. cheap) backend instead of the default. The scheduled task fires via the existing queue mechanism — result lands in the same Telegram chat as a normal turn, tagged [SCHEDULED #N].

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `add | list | remove | pause | resume` |
| `every` |  | Interval like '12h', '30m', '2h30m', '1d'. Min 60s. Required for add. |
| `prompt` |  | What the agent should do each time. Required for add. |
| `model` |  | Pin to a specific model (e.g. 'koompi-free') — optional, otherwise uses session default. |
| `provider` |  | Pin to a specific provider (e.g. 'kconsole') — optional. |
| `skill` |  | Pin to a specific skill — optional. |
| `chat_id` |  | Telegram chat to deliver results to. Defaults to current chat. |
| `thread_id` |  | Telegram thread/topic. Defaults to current. |
| `id` |  | Task id. Required for remove/pause/resume. |

**Source:** [`tools/scheduler.sh`](../tools/scheduler.sh)

### `skill_install`

Clone a public skill repo and install to brain/skills/<name>/. Reads SKILL.md for prompt.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `skill` | ✓ | Short name. |
| `repo` | ✓ | https:// git URL. |
| `toolsets` |  | Optional extras. |

**Source:** [`tools/skill_install.sh`](../tools/skill_install.sh)

### `skill_manager`

Manage skills. list / create / bind / unbind (bind attaches to a Telegram topic).

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `list | create | bind | unbind` |
| `skill` |  | Required for create/bind/unbind. |
| `prompt` |  | Required for create. |
| `toolsets` |  | Space-separated extras, e.g. 'inspect media'. |
| `chat_id` |  | Required for bind/unbind. |
| `thread_id` |  | Required for bind/unbind. |

**Source:** [`tools/skill_manager.sh`](../tools/skill_manager.sh)

### `todo`

Per-session task list. Actions: add, list, done, delete, clear.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `add | list | done | delete | clear` |
| `session` |  | Default 'default'. |
| `text` |  | Required for add. |
| `id` |  | Required for done/delete. |

**Source:** [`tools/todo.sh`](../tools/todo.sh)


## `inspect` toolset

_On-demand (skill toolsets / TOOL_EXTRA_TOOLSETS). Heavy or specialized._

### `ast_edit`

AST-aware Python editor. Cannot produce syntax errors. Actions: validate, list_symbols, get_symbol, replace_func, add_import, rename.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `action` | ✓ | `validate | list_symbols | get_symbol | replace_func | add_import | rename` |
| `path` | ✓ |  |
| `name` |  | Function/class name. |
| `new_body` |  | Full replacement source. |
| `import` |  | e.g. 'import os'. |
| `old_name` |  |  |
| `new_name` |  |  |

**Source:** [`tools/ast_edit.py`](../tools/ast_edit.py)

### `delegate`

Delegate to a sub-agent (Claude Code / Codex / self). sync blocks; async returns a session name — poll with mode=check. For async always pass notify_session+notify_msg_id so the watcher sends Telegram progress.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `mode` |  | `sync | async | check | kill | list` — Default sync. |
| `goal` |  | Required for sync/async. |
| `context` |  | File paths, constraints, patterns. |
| `session` |  | tmux session name. Required for check/kill. |
| `notify_session` |  | AMA session_id for async progress notifications. |
| `notify_msg_id` |  | Original user msg_id for reply-to. |
| `backend` |  | `auto | claude | codex | self` |
| `timeout` |  | Seconds. Default 300. |
| `max_turns` |  | self backend. Default 20. |

**Source:** [`tools/delegate.sh`](../tools/delegate.sh)

### `insights`

Token + tool usage stats.

**Source:** [`tools/insights.sh`](../tools/insights.sh)

### `read_error_log`

Recent agent errors for diagnosis.

**Source:** [`tools/read_error_log.sh`](../tools/read_error_log.sh)

### `sys_info`

CPU, memory, disk, uptime stats.

**Source:** [`tools/sys_info.sh`](../tools/sys_info.sh)


## `media` toolset

_On-demand. Image generation and media handling._

### `image_generate`

Generate an image via Pollinations. Returns a URL.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `prompt` | ✓ |  |
| `width` |  | Default 1024. |
| `height` |  | Default 1024. |

**Source:** [`tools/image_generate.sh`](../tools/image_generate.sh)


## `kanban` toolset

_On-demand. Multi-task project tracking._

### `kanban_block`

Block task pending human input.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `task_id` | ✓ |  |
| `reason` | ✓ |  |

### `kanban_complete`

Mark task done with handoff summary.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `task_id` | ✓ |  |
| `summary` | ✓ | 1-3 sentences. |
| `metadata` |  |  |

### `kanban_create`

Create a kanban task.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `title` | ✓ |  |
| `assignee` | ✓ |  |
| `body` |  | Full spec. |
| `parents` |  |  |
| `priority` |  |  |

### `kanban_show`

Read a kanban task's state and dependencies.

**Parameters**

| Name | Required | Description |
|---|---|---|
| `task_id` | ✓ |  |

