#!/bin/bash
# Tool: image_generate
# Description: Generate an image from a text prompt via Pollinations AI (free, no key).
# Arguments:
#   prompt: The image description.
#   width:  Image width  in px (default 1024).
#   height: Image height in px (default 1024).
#
# Returns a direct https URL to a JPEG. The harness's process_one_tool_call.sh
# pipes the URL through tg_send_photo so the user gets the rendered image in
# Telegram, not just a link.

prompt="${TOOL_prompt}"
width="${TOOL_width:-1024}"
height="${TOOL_height:-1024}"

if [[ -z "$prompt" ]]; then
    echo "Error: prompt is required."
    exit 1
fi

# URL-encode the prompt
encoded_prompt=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.stdin.read().strip()))" <<< "$prompt")

# Random seed prevents Pollinations from returning a cached duplicate
SEED=$RANDOM

# CORRECT endpoint: image.pollinations.ai serves image/jpeg.
# The previous pollinations.ai/p/ URL returned the marketing HTML page —
# Telegram couldn't render it as a photo, which is why the tool felt broken.
URL="https://image.pollinations.ai/prompt/${encoded_prompt}?width=${width}&height=${height}&seed=${SEED}&model=flux&nologo=true"

# Quick HEAD check so the model knows immediately if generation failed,
# rather than trusting the URL string and silently letting Telegram fail.
_status=$(curl -sIL --max-time 25 -o /dev/null -w '%{http_code}|%{content_type}' "$URL" 2>/dev/null || echo '000|')
_code="${_status%%|*}"
_ctype="${_status##*|}"

if [[ "$_code" != "200" ]] || [[ "$_ctype" != image/* ]]; then
    echo "Error: image generation failed (HTTP ${_code:-?}, type ${_ctype:-?}). URL: $URL"
    exit 1
fi

echo "IMAGE_URL: $URL"
echo "Image generated successfully (${width}x${height}). Sent to user."
