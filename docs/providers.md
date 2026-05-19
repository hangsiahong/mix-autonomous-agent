# Providers

How to configure each LLM provider AMA supports. The `core/mix/providers/<name>.sh` file for each provider implements at minimum `<name>_activate()` which sets `BASE_URL` + `API_KEY` at startup or per-turn override.

## Google Vertex AI (recommended)

Best for: Gemini 3 Flash Preview (fast + multimodal + thinking). Free tier via OAuth.

### Setup with gcloud (full features incl. prompt caching)

```bash
# Install gcloud
curl https://sdk.cloud.google.com | bash
gcloud auth application-default login
gcloud config set project YOUR_GCP_PROJECT
```

Then in `.env`:
```bash
PROVIDER=google
GOOGLE_MODE=vertex
GOOGLE_PROJECT=your-gcp-project-id
GOOGLE_REGION=global         # use global for Gemini 3.x preview
MODEL=gemini-3-flash-preview
```

The env var names are `GOOGLE_PROJECT` / `GOOGLE_REGION` (the short, code-internal
names) — not the gcloud-style `GOOGLE_CLOUD_*`.

### Setup with API key (no prompt caching)

If you only have a Vertex API key (`AQ.*` form, not gcloud OAuth):

```bash
GOOGLE_VERTEX_KEY=AQ.Ab8...
```

Chat works fine. **Prompt caching (`cachedContents`) is unreachable** — that endpoint requires OAuth2. AMA detects this and skips caching with a one-time stderr note.

### Google AI Studio (key works for everything including caching)

```bash
PROVIDER=google
GOOGLE_MODE=studio
GOOGLE_API_KEY=AIza...
MODEL=gemini-2.5-flash
```

Studio's `cachedContents` accepts the API key (unlike Vertex).

## Anthropic Claude

```bash
PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
MODEL=claude-opus-4-7   # or claude-sonnet-4-6, claude-haiku-4-5
```

AMA automatically enables `cache_control: ephemeral` on the system prompt block, giving ~90% cost reduction on repeated turns within the 5-minute cache window.

## KConsole AI (Koompi Cloud Gateway)

OpenAI-compatible proxy for Gemini, Imagen, GLM models, etc. Sign up at [ai.koompi.cloud](https://ai.koompi.cloud).

```bash
PROVIDER=kconsole
KCONSOLE_AI_KEY=kpi_...
MODEL=koompi-fast   # or koompi-free, gemini-3-flash-preview, glm-5-turbo, ...
```

KConsole models routed through this provider also work as **per-task overrides** for the scheduler — see [`self_improvement.md#scheduler`](self_improvement.md#scheduler).

## Other OpenAI-compatible providers

`Groq`, `DeepSeek`, `Mistral`, `Z.AI`, `xAI`, `OpenRouter`, `Minimax`, `Ollama` — all use the standard OpenAI chat-completions shape. Set:

```bash
PROVIDER=<groq|deepseek|mistral|...>
<NAME>_API_KEY=...   # e.g. GROQ_API_KEY
MODEL=...
```

Each provider's `<name>_activate()` in `core/mix/providers/` documents its specific env vars.

## Ollama (local models)

```bash
PROVIDER=ollama
OLLAMA_HOST=http://localhost:11434   # default
MODEL=llama-3.3-70b-instruct
```

Vision support depends on the model — `llava`, `bakllava`, `pixtral`, `qwen-vl` work; plain text models (`gemma`, `mistral`, `llama`) don't and the agent's per-turn `Vision: disabled` flag will tell it not to pretend to see images.

## Google Cloud Code OAuth (free tier)

Free Gemini access via the `gemini-cli` OAuth client. No API key needed.

```bash
PROVIDER=google_cloudcode
MODEL=gemini-2.5-flash   # or gemini-3-flash-preview if your account has access
```

Setup:
1. In Telegram: `/google_login`
2. Open the URL the bot sends, authorize
3. Send `/google_login_callback <redirect-url>` to complete

Stores token at `~/.mix/google_oauth.json`. Auto-refreshes.

## GitHub Copilot

```bash
PROVIDER=copilot
MODEL=gpt-5
```

Uses your GitHub Copilot subscription via the device-code OAuth flow:
```bash
# First time only:
python3 tools/copilot_oauth.py login
```

Stores token at `~/.mix/copilot_github_token`. Auto-refreshes.

## Provider pool — fallback + round-robin + tier routing { #pool }

Multiple providers with automatic failover. Copy the template:

```bash
cp brain/provider_pool.json.example brain/provider_pool.json
```

Schema:

```json
{
  "strategy": "fallback",   // or "round-robin"
  "pool": [
    {
      "label": "Google-1",
      "provider": "google",
      "key": "AIza...",
      "model": "gemini-3-flash-preview",
      "tier": "standard"
    },
    {
      "label": "Groq-fast",
      "provider": "groq",
      "key": "gsk_...",
      "model": "llama-3.3-70b-versatile",
      "tier": "fast"
    }
  ]
}
```

**Strategy:**
- `fallback` — try entries in order, skip rate-limited ones
- `round-robin` — distribute load across entries

**Tier-based routing:** set `TASK_TIER=fast` env var (or per-task in scheduler) to prefer entries with `tier: "fast"`. Falls back to other tiers if no fast entry is available. Available tiers: `fast | standard | power`.

## Adding a new provider

See [CONTRIBUTING.md → Adding a new provider](../CONTRIBUTING.md#adding-a-new-provider).

The minimal provider is ~10 lines:

```bash
# core/mix/providers/myprovider.sh
myprovider_activate() {
  BASE_URL="https://api.myprovider.com/v1"
  API_KEY="${MYPROVIDER_API_KEY:-}"
}
```

For native (non-OpenAI-compat) streaming protocols, look at `core/mix/providers/google.sh` + `google_stream.py` for the pattern.

## Error handling

When a provider call fails, AMA's error classifier ([34_error_classifier.sh](../core/mix/34_error_classifier.sh)) maps the response to one of 13 reasons + an action verb:

| Reason | Action | What happens |
|---|---|---|
| `rate_limit` | `retry_after_delay` | Wait for the actual quota window |
| `billing_exhausted` | `rotate_pool` | Mark this pool entry limited, try the next |
| `auth` (401) | `rotate_pool` | Try next pool entry |
| `provider_policy` (403/400 safety) | `fail_user` | Don't retry — surface the policy block to user |
| `model_unavailable` (404) | `switch_model` | Try FALLBACK_MODEL |
| `model_overloaded` (503) | `switch_model` | Same |
| `thinking_signature` (400) | `disable_thinking` | Set THINKING_BUDGET=none, retry |
| `cache_miss` (400 cachedContent) | `reinline_cache` | Purge cache state, retry with inline |
| `context_overflow` | `compress` | Run history compression, retry |
| `payload_too_large` (413) | `compress` | Same |
| `timeout` (408) | `retry_after_delay` | Backoff + retry |
| `server_error` (5xx) | `retry_after_delay` | Backoff + retry |
| `bad_request_permanent` | `fail` | Don't retry |
