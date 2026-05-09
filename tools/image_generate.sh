#!/bin/bash
# Tool: image_generate
# Description: Generate an image from a prompt.
# Arguments:
#   prompt: The image description.
#   width: Image width (default 1024).
#   height: Image height (default 1024).

prompt="${TOOL_prompt}"
width="${TOOL_width:-1024}"
height="${TOOL_height:-1024}"

if [[ -z "$prompt" ]]; then
    echo "Error: prompt is required."
    exit 1
fi

# URL Encode prompt
encoded_prompt=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$prompt")

# Using pollinations.ai for free, fast generation
# We add a random seed to prevent caching
SEED=$RANDOM
URL="https://pollinations.ai/p/${encoded_prompt}?width=${width}&height=${height}&seed=${SEED}&model=flux"

echo "IMAGE_URL: $URL"
echo "Image generated successfully. Sent to user."
