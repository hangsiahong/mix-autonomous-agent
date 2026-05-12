#!/usr/bin/env python3
"""
AST-aware Python editor. Operations are structurally safe — impossible to
produce syntax errors since we parse before and after every change.

Usage (via TOOL_ env vars):
  TOOL_action=list_symbols  TOOL_path=file.py
  TOOL_action=get_symbol    TOOL_path=file.py  TOOL_name=my_func
  TOOL_action=replace_func  TOOL_path=file.py  TOOL_name=my_func  TOOL_new_body="def my_func(...):\n    ..."
  TOOL_action=add_import    TOOL_path=file.py  TOOL_import="import os"
  TOOL_action=rename        TOOL_path=file.py  TOOL_old_name=foo  TOOL_new_name=bar
  TOOL_action=validate      TOOL_path=file.py
"""
import ast, sys, os, re, textwrap

def _read(path):
    with open(path) as f:
        return f.read()

def _write(path, source):
    # Validate before writing
    try:
        ast.parse(source)
    except SyntaxError as e:
        raise ValueError(f"Would produce invalid Python: {e}")
    with open(path, 'w') as f:
        f.write(source)

def validate(path):
    """Parse file and report any syntax errors."""
    source = _read(path)
    try:
        tree = ast.parse(source)
        funcs = [n.name for n in ast.walk(tree) if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))]
        classes = [n.name for n in ast.walk(tree) if isinstance(n, ast.ClassDef)]
        return f"✅ Valid Python\nFunctions: {', '.join(funcs) or '(none)'}\nClasses: {', '.join(classes) or '(none)'}"
    except SyntaxError as e:
        return f"❌ Syntax error at line {e.lineno}: {e.msg}\n  {e.text}"

def list_symbols(path):
    """List all top-level functions and classes with their line numbers."""
    source = _read(path)
    tree = ast.parse(source)
    lines = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            kind = "async def" if isinstance(node, ast.AsyncFunctionDef) else "def"
            args = [a.arg for a in node.args.args]
            lines.append(f"  {kind} {node.name}({', '.join(args)})  [line {node.lineno}]")
        elif isinstance(node, ast.ClassDef):
            bases = [ast.unparse(b) for b in node.bases] if hasattr(ast, 'unparse') else []
            base_str = f"({', '.join(bases)})" if bases else ""
            lines.append(f"  class {node.name}{base_str}  [line {node.lineno}]")
    return f"Symbols in {path}:\n" + ("\n".join(sorted(set(lines))) or "  (none found)")

def get_symbol(path, name):
    """Extract the source of a function or class by name."""
    source = _read(path)
    src_lines = source.splitlines()
    tree = ast.parse(source)
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name == name:
                end = node.end_lineno if hasattr(node, 'end_lineno') else node.lineno + 20
                chunk = src_lines[node.lineno - 1 : end]
                return f"# {name} (lines {node.lineno}-{end})\n" + "\n".join(chunk)
    return f"Symbol '{name}' not found in {path}"

def replace_func(path, name, new_body):
    """Replace an entire function or class definition. new_body must be valid Python."""
    # Validate new_body first
    try:
        ast.parse(textwrap.dedent(new_body))
    except SyntaxError as e:
        return f"❌ new_body has syntax error: {e}"

    source = _read(path)
    src_lines = source.splitlines()
    tree = ast.parse(source)

    target = None
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if node.name == name:
                target = node
                break

    if target is None:
        return f"❌ Symbol '{name}' not found in {path}"

    start = target.lineno - 1  # 0-indexed
    end = target.end_lineno if hasattr(target, 'end_lineno') else start + 20

    # Preserve indentation of original
    original_indent = len(src_lines[start]) - len(src_lines[start].lstrip())
    indent_str = " " * original_indent

    # Apply original indentation to new body
    new_lines = new_body.rstrip().splitlines()
    if new_lines and new_lines[0].lstrip() == new_lines[0]:  # no indent yet
        indented = [indent_str + l if l.strip() else l for l in new_lines]
    else:
        indented = new_lines

    new_source_lines = src_lines[:start] + indented + src_lines[end:]
    new_source = "\n".join(new_source_lines) + "\n"

    try:
        _write(path, new_source)
    except ValueError as e:
        return f"❌ {e}"

    return f"✅ Replaced '{name}' in {path} (lines {start+1}-{end} → {len(indented)} lines)"

def add_import(path, import_stmt):
    """Add an import statement if not already present."""
    source = _read(path)

    # Check if already imported
    clean = import_stmt.strip()
    if clean in source:
        return f"ℹ️ Already present: {clean}"

    # Validate the import statement
    try:
        ast.parse(clean)
    except SyntaxError as e:
        return f"❌ Invalid import statement: {e}"

    lines = source.splitlines()
    # Find the last existing import line
    last_import_idx = 0
    for i, line in enumerate(lines):
        stripped = line.strip()
        if stripped.startswith('import ') or stripped.startswith('from '):
            last_import_idx = i

    insert_after = last_import_idx if last_import_idx > 0 else 0
    new_lines = lines[:insert_after + 1] + [clean] + lines[insert_after + 1:]
    new_source = "\n".join(new_lines) + "\n"

    try:
        _write(path, new_source)
    except ValueError as e:
        return f"❌ {e}"

    return f"✅ Added import at line {insert_after + 2}: {clean}"

def rename_symbol(path, old_name, new_name):
    """Rename all occurrences of a function/class/variable name in the file."""
    if not re.match(r'^[A-Za-z_]\w*$', new_name):
        return f"❌ Invalid Python identifier: {new_name}"

    source = _read(path)
    # Use word-boundary replacement to avoid partial matches
    new_source = re.sub(r'\b' + re.escape(old_name) + r'\b', new_name, source)

    if new_source == source:
        return f"ℹ️ '{old_name}' not found in {path}"

    count = len(re.findall(r'\b' + re.escape(old_name) + r'\b', source))
    try:
        _write(path, new_source)
    except ValueError as e:
        return f"❌ Rename produced invalid Python: {e}"

    return f"✅ Renamed '{old_name}' → '{new_name}' ({count} occurrence(s)) in {path}"

def main():
    action    = os.environ.get("TOOL_action", "")
    path      = os.environ.get("TOOL_path", "")
    name      = os.environ.get("TOOL_name", "")
    new_body  = os.environ.get("TOOL_new_body", "")
    import_s  = os.environ.get("TOOL_import", "")
    old_name  = os.environ.get("TOOL_old_name", "")
    new_name  = os.environ.get("TOOL_new_name", "")

    if not action:
        print(__doc__)
        sys.exit(1)

    if action in ("validate", "list_symbols", "get_symbol", "replace_func",
                  "add_import", "rename") and not path:
        print("Error: TOOL_path is required")
        sys.exit(1)

    if not os.path.exists(path) and action != "validate":
        # validate gives a clear error; others need the file
        if action != "validate":
            print(f"Error: file not found: {path}")
            sys.exit(1)

    if action == "validate":
        print(validate(path) if os.path.exists(path) else f"File not found: {path}")
    elif action == "list_symbols":
        print(list_symbols(path))
    elif action == "get_symbol":
        if not name:
            print("Error: TOOL_name required for get_symbol")
            sys.exit(1)
        print(get_symbol(path, name))
    elif action == "replace_func":
        if not name or not new_body:
            print("Error: TOOL_name and TOOL_new_body required for replace_func")
            sys.exit(1)
        print(replace_func(path, name, new_body))
    elif action == "add_import":
        if not import_s:
            print("Error: TOOL_import required for add_import")
            sys.exit(1)
        print(add_import(path, import_s))
    elif action == "rename":
        if not old_name or not new_name:
            print("Error: TOOL_old_name and TOOL_new_name required for rename")
            sys.exit(1)
        print(rename_symbol(path, old_name, new_name))
    else:
        print(f"Unknown action: {action}\n{__doc__}")
        sys.exit(1)

if __name__ == "__main__":
    main()
