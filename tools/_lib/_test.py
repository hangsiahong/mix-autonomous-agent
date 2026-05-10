"""Smoke tests for the new edit/patch infrastructure."""

import os
import sys
import tempfile

# Project root = parent of tools/
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))

from tools._lib.fuzzy_match import fuzzy_find_and_replace, format_no_match_hint
from tools._lib.patch_parser import parse_v4a_patch, validate, apply
from tools._lib.file_backend import make_file_ops


def test_fuzzy():
    content = """def hello():
    print('hello world')
    return 42

def goodbye():
    print('bye')
"""
    new, n, s, err = fuzzy_find_and_replace(content, "print('hello world')", "print('HI')")
    assert n == 1 and err is None and "print('HI')" in new, f"exact: {err}"
    print("  fuzzy.exact ok")

    # Multi-line
    pat = "print('hello world')\n    return 42"
    rep = "print('hi')\n    return 99"
    new, n, s, err = fuzzy_find_and_replace(content, pat, rep)
    assert n == 1 and err is None, f"multi: {err}"
    print("  fuzzy.multi-line ok")

    # Indentation drift (LLM forgot indent)
    new, n, s, err = fuzzy_find_and_replace(content, "print('bye')", "print('farewell')")
    assert n == 1, f"indent: {err}"
    print(f"  fuzzy.indent ok (strategy={s})")

    # No match -> hint
    new, n, s, err = fuzzy_find_and_replace(content, "print('hello universe')", "x")
    assert n == 0 and err is not None
    hint = format_no_match_hint(err, n, "print('hello universe')", content)
    assert "Did you mean" in hint
    print("  fuzzy.did-you-mean ok")


def test_v4a():
    with tempfile.TemporaryDirectory() as root:
        p = os.path.join(root, "a.py")
        with open(p, "w") as f:
            f.write("x = 1\ny = 2\nz = 3\n")

        patch = f"""*** Begin Patch
*** Update File: {p}
@@ y = 2 @@
 x = 1
-y = 2
+y = 22
 z = 3
*** End Patch
"""
        ops, err = parse_v4a_patch(patch)
        assert err is None and len(ops) == 1, f"parse: {err}"

        backend = make_file_ops(root)
        verrs = validate(ops, backend)
        assert not verrs, f"validate: {verrs}"

        result = apply(ops, backend)
        assert result["ok"], f"apply: {result['errors']}"
        assert result["modified"] == [p]
        with open(p) as f:
            assert "y = 22" in f.read()
        print("  v4a.update ok")

        # Multi-op: update + add
        new_p = os.path.join(root, "new.txt")
        patch2 = f"""*** Begin Patch
*** Update File: {p}
@@
-x = 1
+x = 11
 y = 22
*** Add File: {new_p}
+hello
+world
*** End Patch
"""
        ops2, err = parse_v4a_patch(patch2)
        assert err is None
        verrs = validate(ops2, backend)
        assert not verrs, verrs
        r = apply(ops2, backend)
        assert r["ok"], r["errors"]
        assert os.path.exists(new_p)
        print("  v4a.multi ok")

        # Validate-then-fail: no files touched
        bad = f"""*** Begin Patch
*** Update File: {p}
@@
-NOT IN FILE
+x
*** End Patch
"""
        ops3, _ = parse_v4a_patch(bad)
        verrs = validate(ops3, backend)
        assert verrs, "should fail validation"
        print("  v4a.validate-fails-cleanly ok")


def test_safety():
    with tempfile.TemporaryDirectory() as root:
        backend = make_file_ops(root)
        # Path escape
        err = backend.validate_path("/etc/passwd")
        assert err and "sensitive" in err.lower(), err
        # Outside root
        err = backend.validate_path("/tmp/elsewhere.txt")
        assert err and "outside" in err.lower(), err
        # Bash syntax check
        bad_sh = "function broken( {\n  echo bad\n"
        err = backend.validate_syntax("a.sh", bad_sh)
        assert err, "should reject unbalanced function"
        good_sh = "echo hello\n"
        err = backend.validate_syntax("a.sh", good_sh)
        assert err is None, err
        print("  safety.* ok")


if __name__ == "__main__":
    print("fuzzy_match:")
    test_fuzzy()
    print("patch_parser (v4a):")
    test_v4a()
    print("safety:")
    test_safety()
    print("\nall ok")
