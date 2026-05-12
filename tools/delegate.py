#!/usr/bin/env python3
"""
AMA Delegate Tool — spawn a focused sub-agent to complete a specific task.

Hermes-pattern: orchestrate coding agents (Claude Code, Codex, or self)
to handle complex coding subtasks while the parent agent stays focused
on communication and coordination.

Backends (auto-detected):
  claude  — Claude Code CLI (-p non-interactive mode)
  codex   — OpenAI Codex CLI (exec non-interactive mode)
  self    — Mini AMA sub-agent (same model/API, fresh context)

Usage via TOOL_ env vars:
  TOOL_goal="Refactor auth module to use JWT"
  TOOL_context="Auth is in src/auth.py. Use PyJWT library."
  TOOL_backend="auto"      # claude | codex | self | auto (default)
  TOOL_timeout="300"       # seconds (default 300)
  TOOL_max_turns="20"      # for self backend only
  TOOL_workdir="."         # working directory (default: current)
"""
import json, sys, os, subprocess, time, shutil, re
from pathlib import Path

DIR = Path(os.environ.get("AMA_DIR", str(Path(__file__).parent.parent))).resolve()


# ── Backend: Claude Code CLI ──────────────────────────────────────────────────

def run_claude(goal: str, context: str, timeout: int, workdir: str) -> dict:
    """Delegate to Claude Code CLI (-p non-interactive mode)."""
    prompt = goal
    if context:
        prompt = f"{goal}\n\nContext:\n{context}"

    cmd = [
        "claude", "-p", prompt,
        "--add-dir", workdir,
        "--dangerously-skip-permissions",
    ]
    if context:
        cmd += ["--append-system-prompt", f"ADDITIONAL CONTEXT:\n{context}"]

    t0 = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True, text=True,
            cwd=workdir, timeout=timeout,
            env={**os.environ, "CLAUDE_CODE_SIMPLE": "1"}
        )
        output = result.stdout.strip()
        err    = result.stderr.strip()
        if not output and err:
            output = err
        return {
            "status": "completed" if result.returncode == 0 else "error",
            "backend": "claude",
            "result": output or "(no output)",
            "exit_code": result.returncode,
            "duration_s": round(time.time() - t0, 1),
        }
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "backend": "claude",
                "result": f"Claude Code timed out after {timeout}s",
                "duration_s": timeout}
    except FileNotFoundError:
        return {"status": "error", "backend": "claude",
                "result": "claude CLI not found", "duration_s": 0}


# ── Backend: Codex CLI ────────────────────────────────────────────────────────

def run_codex(goal: str, context: str, timeout: int, workdir: str) -> dict:
    """Delegate to OpenAI Codex CLI (exec non-interactive mode)."""
    prompt = goal
    if context:
        prompt = f"{goal}\n\nContext:\n{context}"

    cmd = ["codex", "exec", prompt]

    t0 = time.time()
    try:
        result = subprocess.run(
            cmd,
            capture_output=True, text=True,
            cwd=workdir, timeout=timeout,
        )
        output = result.stdout.strip()
        err    = result.stderr.strip()
        if not output and err:
            output = err
        return {
            "status": "completed" if result.returncode == 0 else "error",
            "backend": "codex",
            "result": output or "(no output)",
            "exit_code": result.returncode,
            "duration_s": round(time.time() - t0, 1),
        }
    except subprocess.TimeoutExpired:
        return {"status": "timeout", "backend": "codex",
                "result": f"Codex timed out after {timeout}s",
                "duration_s": timeout}
    except FileNotFoundError:
        return {"status": "error", "backend": "codex",
                "result": "codex CLI not found", "duration_s": 0}


# ── Backend: Self (mini AMA sub-agent) ────────────────────────────────────────

def call_tool_sh(name: str, args_json: str, workdir: str) -> str:
    """Execute a tool script and return its output."""
    script = DIR / "tools" / f"{name}.sh"
    if not script.exists():
        script = DIR / "tools" / "custom" / f"{name}.sh"
    if not script.exists():
        return f"Error: tool '{name}' not found"

    env = {**os.environ, "AMA_DIR": str(DIR)}
    try:
        args = json.loads(args_json or "{}")
        for k, v in args.items():
            env[f"TOOL_{k}"] = str(v) if not isinstance(v, (str, int, float)) else str(v)
    except Exception:
        pass

    try:
        res = subprocess.run(
            ["bash", str(script)],
            capture_output=True, text=True,
            env=env, cwd=workdir, timeout=120
        )
        out = (res.stdout + res.stderr).strip()
        return out[:5000] if len(out) > 5000 else out
    except subprocess.TimeoutExpired:
        return f"[Tool {name} timed out]"
    except Exception as e:
        return f"[Tool {name} error: {e}]"


def run_self(goal: str, context: str, timeout: int, workdir: str,
             max_turns: int) -> dict:
    """Delegate to a mini AMA sub-agent using the same API credentials."""
    import requests

    provider  = os.environ.get("PROVIDER", "default")
    base_url  = os.environ.get("BASE_URL", "https://generativelanguage.googleapis.com/v1beta/openai")
    api_key   = os.environ.get("API_KEY", "")
    model     = os.environ.get("MODEL", "")
    # Apply Vertex model prefix if needed (google/ prefix for Vertex OpenAI-compat)
    vertex_prefix = os.environ.get("_GOOGLE_VERTEX_MODEL_PREFIX", "")
    if vertex_prefix and not model.startswith(vertex_prefix):
        model = vertex_prefix + model
    # Ensure base_url ends with /openai for OpenAI-compat (Vertex has /endpoints/openapi)
    if base_url.endswith("/openapi") and not base_url.endswith("/openai"):
        base_url = base_url  # keep as-is, it's the Vertex OpenAI-compat endpoint

    # Load + filter tools to core only (no delegation recursion)
    tools_raw = []
    try:
        tools_raw = json.loads((DIR / "brain" / "tools.json").read_text())
        extra_f = DIR / "brain" / "tools_extra.json"
        if extra_f.exists():
            extra = json.loads(extra_f.read_text())
            names = {t.get("name") for t in tools_raw}
            tools_raw += [t for t in extra if t.get("name") not in names]
    except Exception:
        pass

    active = {"core", "search"}
    blocked = {"delegate", "clarify"}  # no recursion, no blocking
    tools = [
        t for t in tools_raw
        if t.get("toolset", "core") in active and t.get("name") not in blocked
    ]
    for t in tools:
        t.pop("toolset", None)
    wrapped = [
        {"type": "function", "function": t} if "type" not in t else t
        for t in tools
    ]

    sys_prompt = (
        "You are a focused sub-agent completing a specific delegated task.\n"
        "Use tools to accomplish the goal. Work autonomously.\n"
        "When fully done, begin your final message with 'DONE: ' followed by a summary.\n"
        "If blocked, begin with 'BLOCKED: ' followed by the reason.\n"
        "Do not ask for clarification — make reasonable decisions and proceed."
    )

    user_msg = f"GOAL: {goal}"
    if context:
        user_msg += f"\n\nCONTEXT:\n{context}"

    history = [{"role": "user", "content": user_msg}]
    tool_calls_count = 0
    final_text = ""
    t0 = time.time()

    for turn in range(max_turns):
        if time.time() - t0 > timeout:
            return {"status": "timeout", "backend": "self",
                    "result": f"Sub-agent timed out after {timeout}s",
                    "tool_calls": tool_calls_count,
                    "turns": turn, "duration_s": round(time.time()-t0, 1)}

        payload = {
            "model": model,
            "messages": [{"role": "system", "content": sys_prompt}] + history,
            "tools": wrapped,
            "tool_choice": "auto",
            "stream": False,
        }

        try:
            resp = requests.post(
                f"{base_url}/chat/completions",
                headers={"Authorization": f"Bearer {api_key}",
                         "Content-Type": "application/json"},
                json=payload, timeout=60,
            )
            resp.raise_for_status()
            data = resp.json()
        except Exception as e:
            return {"status": "error", "backend": "self",
                    "result": f"API error: {e}",
                    "turns": turn, "duration_s": round(time.time()-t0, 1)}

        msg = data.get("choices", [{}])[0].get("message", {})
        content = msg.get("content") or ""
        tcs = msg.get("tool_calls") or []

        if content:
            history.append({"role": "assistant", "content": content})
            final_text = content

        if not tcs:
            break  # no tool calls → done

        # Execute tool batch
        if content is not None:
            history.append({"role": "assistant", "content": content or None, "tool_calls": tcs})
        else:
            history.append({"role": "assistant", "content": None, "tool_calls": tcs})

        for tc in tcs:
            tool_calls_count += 1
            name = tc.get("function", {}).get("name", "")
            args = tc.get("function", {}).get("arguments", "{}")
            out  = call_tool_sh(name, args, workdir)
            history.append({
                "role": "tool",
                "tool_call_id": tc.get("id", f"call_{tool_calls_count}"),
                "name": name,
                "content": out,
            })

    status = "completed"
    if not final_text:
        status = "no_response"
    elif final_text.upper().startswith("BLOCKED:"):
        status = "blocked"

    return {
        "status": status,
        "backend": "self",
        "result": final_text or "(no response generated)",
        "tool_calls": tool_calls_count,
        "turns": min(turn + 1, max_turns),
        "duration_s": round(time.time() - t0, 1),
    }


# ── Auto-detect backend ───────────────────────────────────────────────────────

def detect_backend() -> str:
    """Pick the best available and authenticated backend."""
    if shutil.which("claude"):
        # Quick auth check — fails fast if not logged in
        try:
            r = subprocess.run(
                ["claude", "-p", "hi", "--bare"],
                capture_output=True, text=True, timeout=10,
                env={**os.environ, "CLAUDE_CODE_SIMPLE": "1"}
            )
            if "Not logged in" not in r.stdout and "Not logged in" not in r.stderr:
                return "claude"
        except Exception:
            pass
    if shutil.which("codex"):
        return "codex"
    return "self"


# ── Format result for agent ───────────────────────────────────────────────────

def format_result(r: dict, goal: str) -> str:
    status  = r.get("status", "?")
    backend = r.get("backend", "?")
    result  = r.get("result", "")
    dur     = r.get("duration_s", 0)
    tcs     = r.get("tool_calls", "")
    turns   = r.get("turns", "")

    icon = {"completed": "✅", "error": "❌", "timeout": "⏰",
            "blocked": "🚧", "no_response": "❓"}.get(status, "🔧")

    meta = f"[{backend} | {dur}s"
    if tcs:
        meta += f" | {tcs} tool calls"
    if turns:
        meta += f" | {turns} turns"
    meta += "]"

    lines = [
        f"{icon} Sub-agent {status} {meta}",
        f"Goal: {goal[:100]}",
        "─" * 40,
        result,
    ]
    return "\n".join(lines)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    goal    = os.environ.get("TOOL_goal", "").strip()
    context = os.environ.get("TOOL_context", "").strip()
    backend = os.environ.get("TOOL_backend", "auto").strip().lower()
    timeout = int(os.environ.get("TOOL_timeout", "300"))
    max_turns = int(os.environ.get("TOOL_max_turns", "20"))
    workdir = os.environ.get("TOOL_workdir", str(DIR)).strip() or str(DIR)

    if not goal:
        print("Error: TOOL_goal is required")
        print(__doc__)
        sys.exit(1)

    if backend == "auto":
        backend = detect_backend()

    print(f"[delegate → {backend}] {goal[:80]}...")

    if backend == "claude":
        result = run_claude(goal, context, timeout, workdir)
    elif backend == "codex":
        result = run_codex(goal, context, timeout, workdir)
    elif backend == "self":
        result = run_self(goal, context, timeout, workdir, max_turns)
    else:
        print(f"Unknown backend '{backend}'. Use: claude | codex | self | auto")
        sys.exit(1)

    print(format_result(result, goal))

    # Machine-readable for piping/parsing
    sys.stderr.write(f"DELEGATE_RESULT:{json.dumps(result)}\n")
