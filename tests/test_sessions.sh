#!/bin/bash
# tests/test_sessions.sh - Test session isolation

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

echo "Running Session Isolation Tests..."

# Test Case 1: Private DM Session ID
chat_id="12345"
thread_id=""
session_id="tg_${chat_id}"
[[ -n "$thread_id" ]] && session_id="tg_${chat_id}_${thread_id}"
assert_eq "$session_id" "tg_12345" "Private DM session ID generation"

# Test Case 2: Forum Topic Session ID
chat_id="-100123"
thread_id="99"
session_id="tg_${chat_id}"
[[ -n "$thread_id" ]] && session_id="tg_${chat_id}_${thread_id}"
assert_eq "$session_id" "tg_-100123_99" "Forum topic session ID generation"

# Test Case 3: History Loading/Saving
HISTORY="[]"
load_history "test_session"
assert_eq "$HISTORY" "[]" "Load empty history"

append_text "user" "hello world"
# load_history sanity-trims trailing orphan user messages (Gemini 400 guard).
# Pair with an assistant reply so the round-trip preserves content.
append_text "assistant" "hi there"
save_history "test_session"
assert_contains "$(cat brain/state/history_test_session.json)" "hello world" "Save history content"

HISTORY="[]"
load_history "test_session"
assert_contains "$HISTORY" "hello world" "Reload history content"

# Cleanup
rm brain/state/history_test_session.json

echo "Session Tests Completed."
