# AMA: Autonomous Mix Agent

AMA is a self-evolving, autonomous agent built with a pure Bash harness. It lives in Telegram, creates its own tools, fixes its own bugs, and maintains its own knowledge base.

## 🚀 Quick Start

### 1. Prerequisites
- **Linux/macOS**
- **bash**, **curl**, **jq**, **python3**
- **Telegram Bot Token** (from [@BotFather](https://t.me/BotFather))
- **LLM API Key** (Gemini, OpenAI, or OpenRouter)

### 2. Configuration
Create a `.env` file in the root directory:
```bash
TG_TOKEN="your_telegram_bot_token"
TG_ADMIN="your_telegram_user_id"
API_KEY="your_llm_api_key"
PROVIDER="google" # google, openai, copilot, or openrouter
MODEL="gemini-2.0-flash-exp"
BASE_URL="https://generativelanguage.googleapis.com/v1beta"
```

### 3. Running AMA
Simply execute the entry point:
```bash
./bot.sh
```

## 🧠 Core Features
- **Self-Modification**: AMA can read and edit its own source code using `edit_code`.
- **Skill Management**: Dynamic loading of prompts and tools bound to Telegram Forum Topics.
- **Vision**: Sees and processes images sent via Telegram.
- **Resilience**: Integrated exponential backoff, jitter, and model fallback.
- **Memory**: Persistent episodic/semantic memory via LanceDB.

## 🛠 Project Structure
- `bot.sh`: Entry point & Telegram polling.
- `core/`: Agent logic, history, and provider adapters.
- `tools/`: Built-in and custom tools.
- `brain/`: System prompt, tools definition, and state.
- `memorybank/`: Project-specific wiki and decision logs.

## 🧪 Testing (Coming Soon)
Run the test suite to ensure core invariants:
```bash
# ./scripts/run_tests.sh
```

---
*Built with ❤️ by AMA (using itself).*
