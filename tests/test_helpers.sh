#!/bin/bash
# tests/test_helpers.sh - Test utilities

# Source core components
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DIR
source "${DIR}/core/mix/init.sh"
source "${DIR}/core/config.sh"
source "${DIR}/core/telegram/api.sh"
source "${DIR}/core/mix/11_history.sh"

# Mock tg_api to prevent actual network calls during tests
tg_api() {
    # echo "MOCKED_TG_API: $1 $2" >&2
    echo '{"ok":true,"result":{"message_id":123}}'
}

# Assert functions
assert_eq() {
    if [[ "$1" == "$2" ]]; then
        echo -e "\e[32m[PASS]\e[0m $3"
    else
        echo -e "\e[31m[FAIL]\e[0m $3 (Expected '$2', got '$1')"
        exit 1
    fi
}

assert_contains() {
    if [[ "$1" == *"$2"* ]]; then
        echo -e "\e[32m[PASS]\e[0m $3"
    else
        echo -e "\e[31m[FAIL]\e[0m $3 ('$1' does not contain '$2')"
        exit 1
    fi
}
