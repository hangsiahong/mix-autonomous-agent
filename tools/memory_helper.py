import os
import sys
import subprocess
import warnings
warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=DeprecationWarning)
import lancedb
import requests
import json
import time

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
    """Route to Ollama or Google based on EMBEDDING_PROVIDER env var.

    Falls back to PROVIDER for backward compat, but EMBEDDING_PROVIDER lets
    you use kconsole/openrouter/etc for LLM while keeping a separate embedding backend.
    """
    provider = os.environ.get("EMBEDDING_PROVIDER") or os.environ.get("PROVIDER", "google")
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

# ── Chunking ────────────────────────────────────────────────────────────────
CHUNK_SIZE = 400       # target words per chunk
CHUNK_OVERLAP = 50     # words of overlap between consecutive chunks


def _chunk_text(text: str) -> list[str]:
    """Split text into overlapping word-based chunks.

    Short texts (≤ CHUNK_SIZE words) are returned as-is (single chunk).
    """
    words = text.split()
    if len(words) <= CHUNK_SIZE:
        return [text]
    chunks = []
    start = 0
    while start < len(words):
        end = min(start + CHUNK_SIZE, len(words))
        chunks.append(" ".join(words[start:end]))
        if end == len(words):
            break
        start += CHUNK_SIZE - CHUNK_OVERLAP
    return chunks


def _ensure_table(db, first_row):
    """Get or create the memory table, handling model changes."""
    provider = os.environ.get("EMBEDDING_PROVIDER") or os.environ.get("PROVIDER", "google")
    cur_model = (
        os.environ.get("EMBEDDING_MODEL", "embeddinggemma")
        if provider == "ollama"
        else "google"
    )
    meta = _load_dim_meta()
    model_changed = meta.get("model") != cur_model

    try:
        db.open_table(TABLE_NAME)
        table_exists = True
    except Exception:
        table_exists = False

    if not table_exists or model_changed:
        table = db.create_table(TABLE_NAME, data=[first_row], mode="overwrite")
        _save_dim_meta(cur_model, len(first_row["vector"]))
        return table, True  # first_row already added
    return db.open_table(TABLE_NAME), False


def save_memory(text, metadata=None):
    """Save text to memory, automatically chunking long inputs."""
    chunks = _chunk_text(text)
    db = lancedb.connect(DB_PATH)
    base_meta = metadata or {}

    rows = []
    for i, chunk in enumerate(chunks):
        embedding = get_embedding(chunk)
        chunk_meta = dict(base_meta)
        if len(chunks) > 1:
            chunk_meta["chunk"] = i + 1
            chunk_meta["total_chunks"] = len(chunks)
        rows.append({"vector": embedding, "text": chunk, "metadata": json.dumps(chunk_meta)})

    table, first_added = _ensure_table(db, rows[0])
    remaining = rows[1:] if first_added else rows
    if remaining:
        table.add(remaining)

    return len(chunks)


def search_memory(query, limit=5):
    embedding = get_embedding(query)
    db = lancedb.connect(DB_PATH)

    try:
        table = db.open_table(TABLE_NAME)
    except Exception:
        return []

    # Fetch more candidates than needed to deduplicate chunks from the same source
    raw = table.search(embedding).limit(limit * 3).to_list()

    # Deduplicate: if multiple chunks from the same topic/source return, keep best
    seen_topics = {}
    for r in raw:
        try:
            meta = json.loads(r.get("metadata") or "{}")
        except Exception:
            meta = {}
        key = meta.get("topic") or r.get("text", "")[:60]
        dist = r.get("_distance", 1.0)
        if key not in seen_topics or dist < seen_topics[key][1]:
            seen_topics[key] = (r, dist, meta)

    deduped = sorted(seen_topics.values(), key=lambda x: x[1])[:limit]

    # Update access metadata for each recalled entry (track last_accessed + access_count)
    now = int(time.time())
    all_rows = table.to_arrow().to_pylist()
    updated = False
    for r, _dist, meta in deduped:
        text_key = r.get("text", "")
        for row in all_rows:
            if row.get("text") == text_key:
                try:
                    m = json.loads(row.get("metadata") or "{}")
                except Exception:
                    m = {}
                m["last_accessed"] = now
                m["access_count"] = m.get("access_count", 0) + 1
                row["metadata"] = json.dumps(m)
                updated = True
    if updated:
        try:
            import pyarrow as pa
            table.create_fts_index  # probe — if table supports overwrite update
            db.create_table(TABLE_NAME, data=all_rows, mode="overwrite")
        except Exception:
            pass  # non-critical — don't break search if update fails

    return [x[0] for x in deduped]


def prune_memory(days_unused: int = 30, dry_run: bool = False) -> dict:
    """Remove memories not accessed in `days_unused` days.

    Returns a summary dict: {kept, pruned, dry_run}.
    """
    db = lancedb.connect(DB_PATH)
    try:
        table = db.open_table(TABLE_NAME)
    except Exception:
        return {"kept": 0, "pruned": 0, "dry_run": dry_run, "error": "No memory table found"}

    all_rows = table.to_arrow().to_pylist()
    cutoff = int(time.time()) - (days_unused * 86400)

    keep = []
    pruned = []
    for row in all_rows:
        try:
            m = json.loads(row.get("metadata") or "{}")
        except Exception:
            m = {}
        last_accessed = m.get("last_accessed", 0)
        saved_at = m.get("saved_at", 0)
        # Keep if: accessed recently, OR never accessed but saved recently, OR access_count > 2
        recently_saved = saved_at > cutoff
        recently_accessed = last_accessed > cutoff
        frequently_used = m.get("access_count", 0) > 2
        if recently_accessed or recently_saved or frequently_used:
            keep.append(row)
        else:
            pruned.append(row)

    if not dry_run and pruned:
        if keep:
            db.create_table(TABLE_NAME, data=keep, mode="overwrite")
        else:
            db.drop_table(TABLE_NAME)

    return {"kept": len(keep), "pruned": len(pruned), "dry_run": dry_run}


if __name__ == "__main__":
    mode = sys.argv[1]
    if mode == "save":
        text = sys.argv[2]
        meta = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        meta["saved_at"] = int(time.time())
        n = save_memory(text, meta)
        print(f"Memory saved ({n} chunk{'s' if n > 1 else ''}).")
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
                chunk_info = f" (chunk {meta['chunk']}/{meta['total_chunks']})" if meta.get("chunk") else ""
                access = f" [used {meta['access_count']}x]" if meta.get("access_count") else ""
                lines.append(f"{i}.{topic}{chunk_info}{access}{score_str} {r.get('text', '')}")
            print("\n".join(lines))
    elif mode == "prune":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 30
        dry = "--dry-run" in sys.argv
        result = prune_memory(days_unused=days, dry_run=dry)
        if dry:
            print(f"[dry-run] Would prune {result['pruned']} entries, keep {result['kept']}.")
        else:
            print(f"Memory pruned: removed {result['pruned']}, kept {result['kept']}.")
    elif mode == "stats":
        db = lancedb.connect(DB_PATH)
        try:
            table = db.open_table(TABLE_NAME)
            rows = table.to_arrow().to_pylist()
            total = len(rows)
            never_accessed = sum(1 for r in rows if not json.loads(r.get("metadata") or "{}").get("last_accessed"))
            print(f"Total memories: {total}")
            print(f"Never recalled: {never_accessed}")
            print(f"Active (recalled ≥1x): {total - never_accessed}")
        except Exception:
            print("No memory table found.")
