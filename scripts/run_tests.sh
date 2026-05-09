#!/bin/bash
# scripts/run_tests.sh - Run all tests

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DIR

echo "=== AMA Test Suite ==="

# Initialize environment for testing
export PROVIDER="default"
export MODEL="test-model"

FAILED=0

for test_script in "${DIR}/tests"/test_*.sh; do
    echo "--- Executing $(basename "$test_script") ---"
    bash "$test_script"
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[FAILED]\e[0m $test_script"
        FAILED=1
    fi
done

if [ $FAILED -eq 0 ]; then
    echo -e "\n\e[32mALL TESTS PASSED\e[0m"
    exit 0
else
    echo -e "\n\e[31mSOME TESTS FAILED\e[0m"
    exit 1
fi
