#!/bin/bash
# tools/_fn/list_files.fn.sh — function-form of tools/list_files.sh.
#
# When sourced into the harness shell, defines `tool_list_files` which
# does what `bash tools/list_files.sh` does but without paying the bash
# subprocess exec cost on every call. Dispatch happens via `$(tool_list_files)`
# in run_tool — the $() still forks (so the subshell is isolated), but
# skips the exec, the shebang lookup, and the cold script load.
#
# This file is the PROOF for the function-dispatch path. Other pure-bash
# tools can follow the same pattern: name the file `<tool>.fn.sh`, define
# `tool_<tool>` here, and the dispatcher picks it up automatically.

tool_list_files() {
    local dir="${TOOL_directory:-.}"

    # BASH_SOURCE[0] inside a sourced function points to THIS file. We
    # already know the tools/ root from that, so compute the project
    # root once.
    local _tools_root
    _tools_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local _project_root="$(cd "$_tools_root/.." && pwd)"
    local _resolved
    _resolved="$(realpath -m "$dir")"

    if [[ "$_resolved" != "$_project_root"* ]]; then
        echo "Error: Access denied. You can only list files within the project directory ($_project_root)."
        return 1
    fi

    find "$dir" -maxdepth 2 -not -path '*/.*'
    # Subdirectory context discovery (kept as a script call — context_discovery
    # is its own tool with its own lifecycle).
    bash "$_tools_root/context_discovery.sh" "$dir"
}
