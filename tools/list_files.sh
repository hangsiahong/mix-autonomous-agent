#!/bin/bash
dir="${TOOL_directory:-.}"
find "$dir" -maxdepth 2 -not -path '*/.*'
