import os
import sys
import subprocess
import lancedb
import requests
import json

DB_PATH = os.path.expanduser("~/ama_memory")
TABLE_NAME = "memories"
# Sidecar file tracks which embedding model (and its dim) was used to build the DB
_DIM_SIDECAR = os.path.join(DB_PATH, ".embedding_meta.json")


def _ollama_embed(text):
    """Call local Ollama /api/embed endpoint (works with embeddinggemma and nomic-embed-text)."""
    ollama_url = os.environ.get("OLLAMA_URL", "http://localhost:11434").rstrip("/")
    model = os.environ.get("EMBEDDING_MODEL", "embeddinggemma")
    resp = requests.post(
        f"{ollama_url}/api/embed",
        json={"model": model, "input": text},
        timeout=60,
    )
    resp.raise_for_status()
    data = resp.json()
    # /api/embed returns {"embeddings": [[...]]} (list of lists)
    return data["embeddings"][0]


def _google_embed(text):
    """Call Google Vertex AI or AI Studio embeddings API."""
    mode = "vertex"
    project_id = ""
    region = "global"

    if os.environ.get("GOOGLE_MODE"):
        mode = os.environ.get("GOOGLE_MODE")
    if os.environ.get("GOOGLE_PROJECT"):
        project_id = os.environ.get("GOOGLE_PROJECT")
    if os.environ.get("GOOGLE_REGION"):
        region = os.environ.get("GOOGLE_REGION")

    config_path = os.path.expanduser("~/.mix/google_provider")
    if os.path.exists(config_path):
        with open(config_path) as f:
            for line in f:
                if line.startswith("mode="): mode = line.split("=", 1)[1].strip()
                if line.startswith("project_id="): project_id = line.split("=", 1)[1].strip()
                if line.startswith("region="): region = line.split("=", 1)[1].strip()

    if mode == "vertex" and project_id:
        token = None
        is_api_key = False
        try:
            token = subprocess.check_output(["gcloud", "auth", "print-access-token"]).decode().strip()
        except Exception:
            token = (os.environ.get("GOOGLE_VERTEX_KEY") or os.environ.get("GOOGLE_API_KEY")
                     or os.environ.get("GEMINI_KEY"))
            if not token:
                p = os.path.expanduser("~/.mix/google_api_key")
                if os.path.exists(p):
                    token = open(p).read().strip()
            if token:
                is_api_key = True
        if not token:
            raise ValueError("No Vertex token or API key found")

        base_domain = f"{region}-aiplatform.googleapis.com" if region != "global" else "aiplatform.googleapis.com"
        location_path = region if region != "global" else "us-central1"
        url = (f"https://{base_domain}/v1/projects/{project_id}/locations/{location_path}"
               f"/publishers/google/models/text-embedding-004:predict")
        headers = {"Content-Type": "application/json"}
        if is_api_key:
            headers["x-goog-api-key"] = token
        else:
            headers["Authorization"] = f"Bearer {token}"
        resp = requests.post(url, json={"instances": [{"content": text}]}, headers=headers)
        resp.raise_for_status()
        return resp.json()["predictions"][0]["embeddings"]["values"]
    else:
        api_key = os.environ.get("GOOGLE_API_KEY") or os.environ.get("GEMINI_KEY")
        if not api_key:
            p = os.path.expanduser("~/.mix/google_api_key")
            if os.path.exists(p):
                api_key = open(p).read().strip()
        if not api_key:
            raise ValueError("GOOGLE_API_KEY or GEMINI_KEY not set")
        url = (f"https://generativelanguage.googleapis.com/v1beta/models/"
               f"text-embedding-004:embedContent?key={api_key}")
        resp = requests.post(url, json={"model": "models/text-embedding-004",
                                         "content": {"parts": [{"text": text}]}})
        resp.raise_for_status()
        return resp.json()["embedding"]["values"]


def get_embedding(text):
    """Route to Ollama or Google based on PROVIDER env var."""
    provider = os.environ.get("PROVIDER", "google")
    if provider == "ollama":
        return _ollama_embed(text)
    return _google_embed(text)


def _load_dim_meta():
    if os.path.exists(_DIM_SIDECAR):
        with open(_DIM_SIDECAR) as f:
            return json.load(f)
    return {}


def _save_dim_meta(model, dim):
    os.makedirs(DB_PATH, exist_ok=True)
    with open(_DIM_SIDECAR, "w") as f:
        json.dump({"model": model, "dim": dim}, f)

def save_memory(text, metadata=None):
    embedding = get_embedding(text)
    dim = len(embedding)
    db = lancedb.connect(DB_PATH)

    provider = os.environ.get("PROVIDER", "google")
    cur_model = os.environ.get("EMBEDDING_MODEL", "embeddinggemma") if provider == "ollama" else "google"
    meta = _load_dim_meta()

    row = {"vector": embedding, "text": text, "metadata": json.dumps(metadata or {})}

    model_changed = meta.get("model") != cur_model
    try:
        db.open_table(TABLE_NAME)
        table_exists = True
    except Exception:
        table_exists = False

    if not table_exists or model_changed:
        # overwrite clears old data with incompatible embeddings then creates fresh
        db.create_table(TABLE_NAME, data=[row], mode="overwrite")
        _save_dim_meta(cur_model, dim)
    else:
        table = db.open_table(TABLE_NAME)
        table.add([row])

def search_memory(query, limit=5):
    embedding = get_embedding(query)
    db = lancedb.connect(DB_PATH)

    try:
        table = db.open_table(TABLE_NAME)
    except Exception:
        return []

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
        if not results:
            print("No memories found.")
        else:
            lines = []
            for i, r in enumerate(results, 1):
                score = r.get("_distance", r.get("score", ""))
                score_str = f" (score: {score:.3f})" if isinstance(score, float) else ""
                try:
                    meta = json.loads(r.get("metadata") or "{}")
                except Exception:
                    meta = {}
                topic = f" [{meta['topic']}]" if meta.get("topic") else ""
                lines.append(f"{i}.{topic}{score_str} {r.get('text', '')}")
            print("\n".join(lines))
