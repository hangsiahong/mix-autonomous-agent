#!/bin/bash
path="${TOOL_path}"
old_text="${TOOL_old_text}"
new_text="${TOOL_new_text}"

if [[ ! -f "$path" ]]; then
    echo "Error: File $path not found."
    exit 1
fi

python3 -c "
import sys
path = sys.argv[1]
old = sys.argv[2]
new = sys.argv[3]
with open(path, 'r') as f:
    content = f.read()
if content.count(old) != 1:
    print(f'Error: old_text found {content.count(old)} times (must be exactly 1)')
    sys.exit(1)
new_content = content.replace(old, new)
with open(path, 'w') as f:
    f.write(new_content)
" "$path" "$old_text" "$new_text"
