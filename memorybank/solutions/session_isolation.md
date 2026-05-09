# Session Isolation & Skill Binding in AMA

## Session Isolation
AMA uses a composite `session_id` to isolate conversations across different Telegram contexts:
- Format: `tg_{chat_id}_{thread_id}`
- Private DM: `thread_id` is empty.
- Forum Topics: `thread_id` is the topic ID.
- Storage: History is saved at `brain/state/history_{session_id}.json`.

## Skill Binding
Skills are bound to sessions (topics) via `brain/config.json`.
- A skill is a directory in `brain/skills/{name}/` containing `prompt.txt` and `tools.json`.
- When a skill is active, its prompt is appended to the system prompt and its tools are injected into the API payload.

## Context Injection
On every turn, AMA injects metadata about the current session into the user message:
- Platform (Telegram)
- Chat ID
- Topic ID
- Username
- Session Key

This allows the agent to be aware of its environment and maintain consistency across sessions.
