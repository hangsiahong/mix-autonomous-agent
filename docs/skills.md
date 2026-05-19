# Skills

Skills are domain-specific prompts the agent loads on demand. They let one bot be a financial assistant, a web designer, a code reviewer, etc. — without bloating the base system prompt.

## How skills get picked

Three layers, in priority order:

1. **Topic binding** (`brain/config.json` `group_topics[].skill`) — when you message in a specific Telegram topic, the agent uses the bound skill as the default for that turn.
2. **Auto-router** (`tools/skill_router.py`) — scans your message text for each skill's `triggers:` keywords and overrides the topic default if a different skill matches more strongly (≥2 trigger points).
3. **Active-skill persistence** (`brain/state/active_skill_<sid>`) — once a session is on a skill, follow-up messages stay on that skill unless a NEW skill scores higher. Prevents "did you do it?" from snapping back to the topic default.

The agent can also call `skill_manager(action=bind, name=<X>)` explicitly. But auto-routing usually handles it without a tool call.

## Skill anatomy

A skill is a directory:

```
brain/skills/my_skill/
├── prompt.md      # required — YAML frontmatter + body
├── tools.json     # optional — extra toolsets or per-skill tools
└── custom/        # optional — additive override layer
    ├── prompt.md  # appended after prompt.md body
    └── tools.json # additive tools
```

Or in `core/skills/<name>/` for skills shipped with AMA (only `ama` ships by default).

**Brain overrides core** — if a skill exists in both `core/skills/X/` and `brain/skills/X/`, the brain version wins. Use this to customize a stock skill without forking.

## Required frontmatter

```markdown
---
description: One-line — what this skill is for. Shows up in the skill index.
triggers: [keyword1, "two-word phrase", anothertrigger, "case insensitive"]
---
You are an expert <X>.

## Rules / contracts / templates
…
```

**`description`** (string, ≤120 chars) — shown to the agent when no skill is bound, in the "Available Skills" index. Be specific so the model can route correctly.

**`triggers`** (list of strings) — keywords that match user messages. Matching:
- Phrase match: trigger appears as a whole word/phrase in the user's message (case-insensitive, whitespace/punctuation boundaries)
- Scoring: phrases (with spaces) or trigger length >6 = 2 points each; short single words = 1 point each
- Minimum to switch: 2 points total
- Won't re-route to the currently-active skill (no churn)

Good triggers: specific domain nouns/verbs. Bad triggers: generic words like `fix`, `do`, `make`.

Example from `onedegree_walahe`:
```yaml
triggers: [transaction, transactions, income, expense, payment, balance,
           account, dashboard, onedegree, walahe, finance, money,
           KHR, USD, rent, sales, "today's sales"]
```

## Body — what to put in the prompt

The body is appended to the base `brain/system_prompt.md` when the skill is active. Treat it as **the agent's playbook for this domain**.

**What works well:**
- API contracts in copy-pasteable form (curl templates with placeholders)
- Required headers / auth schemes
- Field name reminders ("uses camelCase, NOT snake_case")
- Common errors + how to handle them
- Reply format expectations ("one-line confirmation, no prose")

**Example — OneDegree skill:**
```markdown
## API Endpoints
- POST `/api/transactions` — create

## Headers (every request)
```
Authorization: Bearer <token>
X-Company-Id: <id>
Content-Type: application/json
```

## Creating a transaction — exact format
JSON body with camelCase keys (snake_case fails with "Missing fields"):
```json
{
  "accountId":   "<uuid>",
  "categoryId":  "<uuid>",
  "type":        "expense" | "income",
  "amount":      200,
  "description": "Claude Opus",
  "date":        "2026-05-19"
}
```

## Workflow rules
- After a successful POST, reply with one line: `✓ Logged $200 expense`
- Do NOT read /home/.../onedegree-fullstack/ source code — this contract is authoritative.
```

**What to avoid:**
- Generic personality stuff (use `SOUL.md` for that)
- Information that's already in MEMORY.md
- Long prose explanations (the model wastes tokens echoing them)
- Mixed concerns (one skill = one domain)

## Optional `tools.json`

A skill can request additional toolsets that aren't loaded by default:

```json
[
  {"_enabled_toolsets": ["inspect", "media"]}
]
```

That activates the `inspect` toolset (repo_map, sys_info, insights, read_error_log, ast_edit, delegate) and `media` toolset (image_generate) for any turn this skill is active.

It can also declare tools directly (rare):

```json
[
  {
    "_enabled_toolsets": ["media"]
  },
  {
    "name": "custom_skill_tool",
    "description": "...",
    "parameters": {...}
  }
]
```

These tools merge with `brain/tools.json` at runtime. Names collide → skill version wins (dedupe by name).

## Custom extension layer

If you want to *extend* a stock skill without replacing its body, drop additions in `brain/skills/<name>/custom/prompt.md`. It's appended to the main body with a `### CUSTOM EXTENSION` separator. Same for `custom/tools.json` — additive.

## Auto-routing in detail

```bash
$ echo "show me last 10 transactions" | python3 tools/skill_router.py route ama
onedegree_walahe

$ echo "build an awwwards landing for a coffee shop" | python3 tools/skill_router.py route ama
awwwards_dev

$ echo "thanks!" | python3 tools/skill_router.py route onedegree_walahe
# (no output — stays on onedegree_walahe)
```

The router is called by `core/telegram/router.sh` before every non-slash user message. Output is empty when no switch is warranted.

You can debug your trigger list with the CLI directly:
```bash
echo "your test message" | python3 tools/skill_router.py route ""
```

## Skill index in the system prompt

When **no skill** is bound, the system prompt includes:

```
## Available Skills
Bind with: skill_manager(action=bind, name="<name>")
The router auto-binds when your message matches a skill's triggers — usually no manual call needed.
  • ama — AMA harness self-modification — edit core/tools/brain files, manage providers, debug bot itself
  • awwwards_dev — Awwwards-style web design — GSAP, Tailwind, Lenis, asymmetric layouts, premium experiential sites
  • onedegree_walahe — OneDegree Finance / Walahe — query transactions, balances, accounts, dashboard via REST API
  ...
```

When a skill **is** bound, this is replaced by a one-line "Active Skill: <name>" hint to save tokens. The skill body itself carries all the detail.

## Creating a new skill

```bash
mkdir -p brain/skills/my_skill
cat > brain/skills/my_skill/prompt.md <<'EOF'
---
description: My new skill for X
triggers: [foo, bar, "exact phrase"]
---
You are an expert at X.

## Rules
- Do this
- Don't do that

## Working command template
```bash
curl ...
```
EOF
```

That's it. The router and skill index pick it up on the next turn. No restart.

## Editing a skill at runtime

The curator (`core/mix/26_reflection.sh`) automatically patches skill prompts when it sees the agent discovering things that should be persisted. You can also tell the agent: "update the onedegree skill prompt to add the new endpoint" — it'll use `edit_code` on the skill's `prompt.md`.

To prevent accidental harness modifications, the curator and agent **cannot** edit `core/*` or `tools/*` from within the agent loop. They can only edit `brain/skills/*/prompt.md`, `brain/state/MEMORY.md`, and `brain/state/USER.md`.
