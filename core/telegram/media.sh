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
    
    # 3. Handle Voice/Audio
    local voice_id=$(echo "$update" | jq -r '.message.voice.file_id // .message.audio.file_id // empty')
    local voice_mime=$(echo "$update" | jq -r '.message.voice.mime_type // .message.audio.mime_type // "audio/ogg"')
    if [[ -n "$voice_id" ]]; then
        local file_info=$(tg_get_file "$voice_id")
        local file_path=$(echo "$file_info" | jq -r '.result.file_path')
        if [[ -n "$file_path" ]]; then
            local tmp_file=$(mktemp --suffix=".ogg")
            tg_download "$file_path" "$tmp_file"
            
            if [[ "$PROVIDER" == "google" ]]; then
                local g_key; g_key=$(google_get_api_key)
                if [[ -n "$g_key" ]]; then
                    # Upload to Gemini File API
                    local uri_line; uri_line=$(python3 tools/gemini_file_api.py "$tmp_file" "$g_key" | grep "FILE_URI:")
                    if [[ -n "$uri_line" ]]; then
                        local uri="${uri_line#FILE_URI:}"
                        media_json=$(echo "$media_json" | jq --arg uri "$uri" --arg mime "$voice_mime" \
                            '. + [{type: "file_data", file_data: {mime_type: $mime, file_uri: $uri}}]')
                    fi
                fi
            fi
            rm -f "$tmp_file"
        fi
    fi

    # 4. Handle Video
    local video_id=$(echo "$update" | jq -r '.message.video.file_id // empty')
    local video_mime=$(echo "$update" | jq -r '.message.video.mime_type // "video/mp4"')
    if [[ -n "$video_id" ]]; then
        local file_info=$(tg_get_file "$video_id")
        local file_path=$(echo "$file_info" | jq -r '.result.file_path')
        if [[ -n "$file_path" ]]; then
            local tmp_file=$(mktemp --suffix=".mp4")
            tg_download "$file_path" "$tmp_file"
            
            if [[ "$PROVIDER" == "google" ]]; then
                local g_key; g_key=$(google_get_api_key)
                if [[ -n "$g_key" ]]; then
                    local uri_line; uri_line=$(python3 tools/gemini_file_api.py "$tmp_file" "$g_key" | grep "FILE_URI:")
                    if [[ -n "$uri_line" ]]; then
                        local uri="${uri_line#FILE_URI:}"
                        media_json=$(echo "$media_json" | jq --arg uri "$uri" --arg mime "$video_mime" \
                            '. + [{type: "file_data", file_data: {mime_type: $mime, file_uri: $uri}}]')
                    fi
                fi
            fi
            rm -f "$tmp_file"
        fi
    fi

    echo "$media_json"
}
