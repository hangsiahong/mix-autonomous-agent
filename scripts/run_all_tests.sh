#!/bin/bash
# scripts/run_all_tests.sh - Automated testing suite

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=== AMA Automated Test Suite ==="
echo "Start: $(date)"

FAILED=0
TOTAL=0

run_test() {
    local test_file="$1"
    TOTAL=$((TOTAL + 1))
    echo -n "Running $test_file... "
    if bash "$test_file" > /tmp/test_out.log 2>&1; then
        echo -e "\e[32mPASS\e[0m"
    else
        echo -e "\e[31mFAIL\e[0m"
        cat /tmp/test_out.log
        FAILED=$((FAILED + 1))
    fi
}

# Run tests
for f in tests/test_*.sh; do
    [[ -x "$f" ]] && run_test "$f"
done

echo "-------------------------------"
echo "Results: $((TOTAL - FAILED))/$TOTAL passed."

if [ $FAILED -gt 0 ]; then
    exit 1
fi
exit 0
