#!/bin/bash
# scripts/run_all_tests.sh - Automated testing suite (auto-discovery)

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=== AMA Automated Test Suite ==="
echo "Start: $(date)"

FAILED=0
TOTAL=0
SKIPPED=0
FAIL_NAMES=()

run_test() {
    local test_file="$1"
    TOTAL=$((TOTAL + 1))
    local name
    name="$(basename "$test_file")"
    printf 'Running %s... ' "$name"
    if bash "$test_file" > /tmp/test_out.log 2>&1; then
        printf '\e[32mPASS\e[0m\n'
    else
        printf '\e[31mFAIL\e[0m\n'
        sed 's/^/    | /' /tmp/test_out.log
        FAILED=$((FAILED + 1))
        FAIL_NAMES+=("$name")
    fi
}

# Discover every test_*.sh under tests/ regardless of executable bit.
# test_helpers.sh is a shared helper sourced by other tests, not a standalone
# test — skip it. Honor TEST_FILTER=<glob> for ad-hoc runs.
shopt -s nullglob
for f in tests/test_*.sh; do
    base="$(basename "$f")"
    if [[ "$base" == "test_helpers.sh" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [[ -n "${TEST_FILTER:-}" && "$base" != $TEST_FILTER ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    run_test "$f"
done
shopt -u nullglob

if [[ $TOTAL -eq 0 ]]; then
    echo "No test files discovered under tests/" >&2
    exit 1
fi

echo "-------------------------------"
echo "Results: $((TOTAL - FAILED))/$TOTAL passed ($SKIPPED skipped)."
if (( FAILED > 0 )); then
    printf 'Failed: %s\n' "${FAIL_NAMES[*]}"
    exit 1
fi
exit 0
