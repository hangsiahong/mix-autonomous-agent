import os
import sys
import subprocess
import lancedb
import requests
import json

DB_PATH = os.path.expanduser("~/ama_memory")
TABLE_NAME = "memories"

def get_embedding(text):
    # Try to load Google Provider config
    mode = "studio"
    project_id = ""
    region = "us-central1"
    
    config_path = os.path.expanduser("~/.mix/google_provider")
    if os.path.exists(config_path):
        with open(config_path, "r") as f:
            for line in f:
                if line.startswith("mode="): mode = line.split("=")[1].strip()
                if line.startswith("project_id="): project_id = line.split("=")[1].strip()
                if line.startswith("region="): region = line.split("=")[1].strip()

    if mode == "vertex" and project_id:
        # Vertex AI Embedding
        token = None
        is_api_key = False
        try:
            token = subprocess.check_output(["gcloud", "auth", "print-access-token"]).decode().strip()
        except:
            token = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_KEY")
            if not token and os.path.exists(os.path.expanduser("~/.mix/google_api_key")):
                with open(os.path.expanduser("~/.mix/google_api_key"), "r") as f:
                    token = f.read().strip()
            if token:
                is_api_key = True

        if not token:
            raise ValueError("No Vertex token or API key found")

        url = f"https://{region}-aiplatform.googleapis.com/v1/projects/{project_id}/locations/{region}/publishers/google/models/text-embedding-004:predict"
        headers = {
            "Content-Type": "application/json"
        }
        if is_api_key:
            headers["x-goog-api-key"] = token
        else:
            headers["Authorization"] = f"Bearer {token}"

        # Vertex uses "instances"
        payload = {
            "instances": [{"content": text}]
        }
        resp = requests.post(url, json=payload, headers=headers)
        resp.raise_for_status()
        return resp.json()["predictions"][0]["embeddings"]["values"]
    else:
        # AI Studio Embedding (Standard)
        api_key = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_KEY")
        if not api_key and os.path.exists(os.path.expanduser("~/.mix/google_api_key")):
             with open(os.path.expanduser("~/.mix/google_api_key"), "r") as f:
                 api_key = f.read().strip()

        if not api_key:
            raise ValueError("GOOGLE_API_KEY or GEMINI_KEY not set")
        
        url = f"https://generativelanguage.googleapis.com/v1beta/models/text-embedding-004:embedContent?key={api_key}"
        payload = {
            "model": "models/text-embedding-004",
            "content": {"parts": [{"text": text}]}
        }
        resp = requests.post(url, json=payload)
        resp.raise_for_status()
        return resp.json()["embedding"]["values"]

def save_memory(text, metadata=None):
    embedding = get_embedding(text)
    db = lancedb.connect(DB_PATH)
    
    if TABLE_NAME not in db.table_names():
        db.create_table(TABLE_NAME, data=[{
            "vector": embedding,
            "text": text,
            "metadata": json.dumps(metadata or {})
        }])
    else:
        table = db.open_table(TABLE_NAME)
        table.add([{
            "vector": embedding,
            "text": text,
            "metadata": json.dumps(metadata or {})
        }])

def search_memory(query, limit=5):
    embedding = get_embedding(query)
    db = lancedb.connect(DB_PATH)
    
    if TABLE_NAME not in db.table_names():
        return []
    
    table = db.open_table(TABLE_NAME)
    results = table.search(embedding).limit(limit).to_list()
    return results

if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "save":
        text = sys.argv[2]
        meta = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        save_memory(text, meta)
        print("Memory saved.")
    elif mode == "search":
        query = sys.argv[2]
        limit = int(sys.argv[3]) if len(sys.argv) > 3 else 5
        results = search_memory(query, limit)
        print(json.dumps(results, indent=2))
