#!/bin/bash
# core/telegram/media.sh - Handle media extraction and processing

# Internal helper: build image_url media_json from a local file path
# Reads b64 via tempfile to avoid ARG_MAX (kernel limit on env+args combined size)
_media_image_json() {
    local file_path="$1"
    local mime="$2"
    local b64_file
    b64_file=$(mktemp)
    base64 -w 0 < "$file_path" > "$b64_file"
    local b64_size
    b64_size=$(wc -c < "$b64_file")
    if [[ "$b64_size" -lt 10 ]]; then
        echo "MEDIA_DEBUG: base64 is empty (file_path=$file_path, size=$(wc -c < "$file_path" 2>/dev/null || echo unknown))" >&2
        rm -f "$b64_file"
        echo "[]"
        return
    fi
    local result
    result=$(MIME="$mime" B64FILE="$b64_file" python3 -c '
import json, os
mime = os.environ["MIME"]
b64 = open(os.environ["B64FILE"]).read().strip()
print(json.dumps([{"type": "image_url", "image_url": {"url": "data:" + mime + ";base64," + b64}}]))
')
    rm -f "$b64_file"
    if [[ -z "$result" ]]; then
        echo "MEDIA_DEBUG: python json build failed" >&2
        echo "[]"
        return
    fi
    echo "$result"
}

tg_extract_media() {
    local update="$1"
    local media_json="[]"

    # 1. Handle Photo
    local photo_id
    photo_id=$(echo "$update" | python3 -c "import json,sys; photos=json.load(sys.stdin).get('message',{}).get('photo',[]); print(photos[-1].get('file_id','') if photos else '')" 2>/dev/null)
    if [[ -n "$photo_id" ]]; then
        local file_info
        file_info=$(tg_get_file "$photo_id")
        local file_path
        file_path=$(echo "$file_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
        if [[ -n "$file_path" ]]; then
            local tmp_file
            tmp_file=$(mktemp)
            tg_download "$file_path" "$tmp_file"
            if [[ -s "$tmp_file" ]]; then
                media_json=$(_media_image_json "$tmp_file" "image/jpeg")
            fi
            rm -f "$tmp_file"
        fi
    fi

    # 2. Handle Document (Images sent as files)
    local doc_id
    doc_id=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',{}).get('document',{}).get('file_id',''))" 2>/dev/null)
    local doc_mime
    doc_mime=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',{}).get('document',{}).get('mime_type',''))" 2>/dev/null)
    if [[ -n "$doc_id" && "$doc_mime" == image/* ]]; then
        local file_info
        file_info=$(tg_get_file "$doc_id")
        local file_path
        file_path=$(echo "$file_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
        if [[ -n "$file_path" ]]; then
            local tmp_file
            tmp_file=$(mktemp)
            tg_download "$file_path" "$tmp_file"
            if [[ -s "$tmp_file" ]]; then
                media_json=$(_media_image_json "$tmp_file" "$doc_mime")
            fi
            rm -f "$tmp_file"
        fi
    elif [[ -n "$doc_id" ]]; then
        # Non-image document (PDF, txt, csv, py, docx …)
        # Download to brain/state/uploads/ and pass path to agent — no extraction in harness.
        # Agent uses bash tool: pdftotext /path - | head -200  or  cat /path | head -100
        local _doc_name
        _doc_name=$(echo "$update" | python3 -c "
import json,sys
print(json.load(sys.stdin).get('message',{}).get('document',{}).get('file_name','document'))" 2>/dev/null)
        local file_info
        file_info=$(tg_get_file "$doc_id")
        local file_path
        file_path=$(echo "$file_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
        if [[ -n "$file_path" ]]; then
            local _uploads="${DIR}/brain/state/uploads"
            mkdir -p "$_uploads"
            # Safe filename: timestamp prefix avoids collisions, strips path traversal
            local _safe; _safe=$(echo "$_doc_name" | tr ' /' '__' | tr -dc 'a-zA-Z0-9._-')
            local _dest="${_uploads}/$(date +%s)_${_safe}"
            tg_download "$file_path" "$_dest"
            if [[ -s "$_dest" ]]; then
                echo "MEDIA_FILE:${_dest} [${doc_mime:-file}]"
            fi
        fi
    fi

    # 3. Handle Voice/Audio
    local voice_id
    voice_id=$(echo "$update" | python3 -c "import json,sys; m=json.load(sys.stdin).get('message',{}); print(m.get('voice',{}).get('file_id','') or m.get('audio',{}).get('file_id',''))" 2>/dev/null)
    local voice_mime
    voice_mime=$(echo "$update" | python3 -c "import json,sys; m=json.load(sys.stdin).get('message',{}); print(m.get('voice',{}).get('mime_type','') or m.get('audio',{}).get('mime_type','') or 'audio/ogg')" 2>/dev/null)
    if [[ -n "$voice_id" ]]; then
        local file_info
        file_info=$(tg_get_file "$voice_id")
        local file_path
        file_path=$(echo "$file_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
        if [[ -n "$file_path" ]]; then
            local tmp_file
            tmp_file=$(mktemp --suffix=".ogg")
            tg_download "$file_path" "$tmp_file"

            if [[ -s "$tmp_file" ]]; then
                # Use inline base64 for voice — works on both AI Studio and Vertex.
                # The File API only accepts AI Studio keys; Vertex tokens can't use it.
                media_json=$(_media_image_json "$tmp_file" "$voice_mime")
            fi
            rm -f "$tmp_file"
        fi
    fi

    # 4. Handle Video
    local video_id
    video_id=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',{}).get('video',{}).get('file_id',''))" 2>/dev/null)
    local video_mime
    video_mime=$(echo "$update" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',{}).get('video',{}).get('mime_type','') or 'video/mp4')" 2>/dev/null)
    if [[ -n "$video_id" ]]; then
        local file_info
        file_info=$(tg_get_file "$video_id")
        local file_path
        file_path=$(echo "$file_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result',{}).get('file_path',''))" 2>/dev/null)
        if [[ -n "$file_path" ]]; then
            local tmp_file
            tmp_file=$(mktemp --suffix=".mp4")
            tg_download "$file_path" "$tmp_file"

            if [[ -s "$tmp_file" ]]; then
                # Use inline base64 for video (same reason as voice — File API needs AI Studio key).
                # Telegram caps video at 20 MB; Gemini inline limit is also ~20 MB, so this is safe.
                media_json=$(_media_image_json "$tmp_file" "$video_mime")
            fi
            rm -f "$tmp_file"
        fi
    fi

    echo "$media_json"
}
