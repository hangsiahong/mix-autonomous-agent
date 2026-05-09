#!/bin/bash
path="${TOOL_path}"
old_text="${TOOL_old_text}"
new_text="${TOOL_new_text}"

if [[ ! -f "$path" ]]; then
    echo "Error: File $path not found."
    exit 1
fi

# Create backup for self-healing
cp "$path" "${path}.bak"

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

# Self-Healing/Validation
if [[ "$path" == *.sh ]]; then
    if ! bash -n "$path" 2>/tmp/bash_err; then
        # Revert change
        mv "${path}.bak" "$path" 2>/dev/null
        echo "Error: Syntax error in bash script. Edit rejected."
        cat /tmp/bash_err
        exit 1
    fi
fi

echo "File $path updated successfully."
