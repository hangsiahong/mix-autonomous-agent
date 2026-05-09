#!/bin/bash
# core/telegram/media.sh - Handle media extraction and processing

tg_extract_media() {
    local update="$1"
    local media_json="[]"

    # 1. Handle Photo
    local photo_id=$(echo "$update" | jq -r '.message.photo[-1].file_id // empty')
    if [[ -n "$photo_id" ]]; then
        local file_info=$(tg_get_file "$photo_id")
        local file_path=$(echo "$file_info" | jq -r '.result.file_path')
        if [[ -n "$file_path" ]]; then
            # We can either download and send as base64 or send as URL if the bot is public
            # Since we are minimalist, lets download and convert to base64 for vision LLMs
            local tmp_file=$(mktemp)
            tg_download "$file_path" "$tmp_file"
            local b64=$(base64 -w 0 < "$tmp_file")
            local mime="image/jpeg"
            rm -f "$tmp_file"
            
            media_json=$(jq -n --arg b64 "$b64" --arg mime "$mime" \
                '[{type: "image_url", image_url: {url: "data:\($mime);base64,\($b64)"}}]')
        fi
    fi

    # 2. Handle Document (Images sent as files)
    local doc_id=$(echo "$update" | jq -r '.message.document.file_id // empty')
    local doc_mime=$(echo "$update" | jq -r '.message.document.mime_type // empty')
    if [[ -n "$doc_id" && "$doc_mime" == image/* ]]; then
        local file_info=$(tg_get_file "$doc_id")
        local file_path=$(echo "$file_info" | jq -r '.result.file_path')
        if [[ -n "$file_path" ]]; then
            local tmp_file=$(mktemp)
            tg_download "$file_path" "$tmp_file"
            local b64=$(base64 -w 0 < "$tmp_file")
            rm -f "$tmp_file"
            
            media_json=$(jq -n --arg b64 "$b64" --arg mime "$doc_mime" \
                '[{type: "image_url", image_url: {url: "data:\($mime);base64,\($b64)"}}]')
        fi
    fi
    
    # 3. Handle Voice (Gemini supports audio)
    local voice_id=$(echo "$update" | jq -r '.message.voice.file_id // empty')
    if [[ -n "$voice_id" ]]; then
        local file_info=$(tg_get_file "$voice_id")
        local file_path=$(echo "$file_info" | jq -r '.result.file_path')
        if [[ -n "$file_path" ]]; then
             # Gemini/OpenAI vision usually doesn't support audio via image_url
             # But Gemini API supports it. For OpenAI compatible API, 
             # we might need to use a different format if supported, 
             # or just mention we received a voice message.
             # For now, lets just download it to a local 'uploads' dir and tell the agent.
             mkdir -p uploads
             local dest="uploads/voice_$(date +%s).ogg"
             tg_download "$file_path" "$dest"
             echo "MEDIA_FILE:$dest"
        fi
    fi

    echo "$media_json"
}
