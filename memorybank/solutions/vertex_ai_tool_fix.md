# Solution: Vertex AI Tool Validation and History Integrity

## Problem
Vertex AI's OpenAI-compatible surface (especially for Gemini 3 models) is extremely strict about the structure of tool calls and history. Missing `id` fields in `assistant` messages or using `id` instead of `tool_call_id` in `tool` messages results in `400 Bad Request` errors. Additionally, Gemini 3 models require a `thought_signature` (or a placeholder) in history when tools are used.

## Fixes

### 1. Streaming Tool Call Reconstruction
In `core/mix/18_streaming_api_call.sh`, the Python delta parser was simplified and omitted `id` and `type` fields. It also used `args` instead of `arguments`.
- **Action**: Updated the parser to accumulate `id` and use the correct `function: {name, arguments}` structure.

### 2. Provider Parity
The Gemini-native streaming logic in `core/mix/providers/google_stream.py` also used `args` instead of `arguments`.
- **Action**: Renamed `args` to `arguments` to align with the OpenAI format used in history.

### 3. History Filtering and Sanitization
The `google_filter_history` function in `core/mix/providers/google.sh` was enhanced to:
- Ensure every `assistant` tool call has an `id`.
- Ensure `tool` messages use `tool_call_id` (migrating from `id` if necessary).
- Inject a placeholder `thought_signature` into `extra_content.google` if missing, as required by Gemini 3.

### 4. Tool Wrapping
Vertex AI requires tools in the `tools` array to be wrapped in `{"type": "function", "function": tool_def}`.
- **Action**: Verified and ensured `core/mix/16_api.sh` performs this wrapping.

## Verification
Tested with `gemini-3-flash-preview` on Vertex AI. Multi-turn tool use now works without 400 errors or history integrity failures.
