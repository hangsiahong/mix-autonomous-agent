#!/bin/bash
# tests/test_skills.sh - Test skill binding logic

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

echo "Running Skill Logic Tests..."

# Mock brain/skills
SKILL_DIR="brain/skills/test_skill"
mkdir -p "$SKILL_DIR"
echo "YOU ARE A TEST SKILL" > "${SKILL_DIR}/prompt.txt"

# Test Case 1: Skill lookup in config
chat_id="test_chat"
thread_id="42"
topic_data='{"thread_id": "42", "skill": "test_skill", "name": "Testing"}'
set_topic_config "$chat_id" "$thread_id" "$topic_data"

found_skill=$(get_topic_config "$chat_id" "$thread_id" | jq -r '.skill')
assert_eq "$found_skill" "test_skill" "Skill lookup in topic config"

# Test Case 2: API Payload Construction with Skill
HISTORY="[]"
# We need to simulate _api_build_payload
source "${DIR}/core/mix/16_api.sh"

# Mock brain/system_prompt.txt
if [ ! -f brain/system_prompt.txt ]; then
    echo "BASE SYSTEM PROMPT" > brain/system_prompt.txt
fi
if [ ! -f brain/tools.json ]; then
    echo "[]" > brain/tools.json
fi

payload=$(_api_build_payload "false" "" "test_skill")
assert_contains "$payload" "YOU ARE A TEST SKILL" "Skill prompt injection into payload"

# Test Case 3: Custom Extension
mkdir -p "${SKILL_DIR}/custom"
echo "EXTENDED LOGIC" > "${SKILL_DIR}/custom/prompt.txt"
payload=$(_api_build_payload "false" "" "test_skill")
assert_contains "$payload" "EXTENDED LOGIC" "Skill custom extension injection"

# Cleanup
rm "${SKILL_DIR}/custom/prompt.txt"
rmdir "${SKILL_DIR}/custom"
rm "${SKILL_DIR}/prompt.txt"
rmdir "${SKILL_DIR}"
# Reset config for other tests (manually remove the test chat from group_topics)
config=$(load_config | jq --arg cid "$chat_id" '.group_topics |= map(select(.chat_id != $cid))')
save_config "$config"

echo "Skill Tests Completed."
