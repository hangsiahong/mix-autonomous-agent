import os
import sys
import time
import requests
import json

def upload_file(file_path, api_key):
    """Uploads a file to Gemini File API (AI Studio)."""
    # Note: This is for AI Studio. Vertex has a different flow (GCS).
    # Since we use OpenAI-compatible endpoint mostly, for File API we use the native one.
    
    url = f"https://generativelanguage.googleapis.com/v1beta/files?key={api_key}"
    
    mime_type = "application/octet-stream"
    if file_path.endswith(".ogg") or file_path.endswith(".oga"):
        mime_type = "audio/ogg"
    elif file_path.endswith(".mp4"):
        mime_type = "video/mp4"
    elif file_path.endswith(".mp3"):
        mime_type = "audio/mpeg"

    num_bytes = os.path.getsize(file_path)
    
    # Initial upload request
    headers = {
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": str(num_bytes),
        "X-Goog-Upload-Header-Content-Type": mime_type,
        "Content-Type": "application/json"
    }
    
    body = {"file": {"display_name": os.path.basename(file_path)}}
    
    r = requests.post(url, headers=headers, json=body)
    if r.status_code != 200:
        print(f"ERROR: Start upload failed: {r.text}")
        return None
        
    upload_url = r.headers.get("X-Goog-Upload-URL")
    
    # Actual data upload
    with open(file_path, "rb") as f:
        headers = {
            "Content-Length": str(num_bytes),
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize"
        }
        r = requests.post(upload_url, headers=headers, data=f)
        
    if r.status_code != 200:
        print(f"ERROR: Data upload failed: {r.text}")
        return None
        
    file_info = r.json().get("file", {})
    file_uri = file_info.get("uri")
    
    # Poll until ACTIVE
    file_name = file_info.get("name")
    status_url = f"https://generativelanguage.googleapis.com/v1beta/{file_name}?key={api_key}"
    
    for _ in range(10):
        r = requests.get(status_url)
        state = r.json().get("state")
        if state == "ACTIVE":
            return file_uri
        elif state == "FAILED":
            print(f"ERROR: File processing failed: {r.text}")
            return None
        time.sleep(2)
        
    return file_uri

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python3 gemini_file_api.py <file_path> <api_key>")
        sys.exit(1)
    
    uri = upload_file(sys.argv[1], sys.argv[2])
    if uri:
        print(f"FILE_URI:{uri}")
    else:
        sys.exit(1)
