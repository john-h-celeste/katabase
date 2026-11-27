#!/usr/bin/env python3

import hashlib
import os
import re
import sys
import time
from pathlib import Path

import psycopg2
import requests

# --------------------------------------------------------------------------
# CONFIGURATION
# --------------------------------------------------------------------------
DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("POSTGRES_DB", "ragdb")
DB_USER = os.getenv("POSTGRES_USER", "raguser")
DB_PASSWORD = os.environ["POSTGRES_PASSWORD"] 

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://inference-lb:11434")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")
EMBED_DIM = int(os.getenv("EMBED_DIM", "768"))

DOCS_DIR = Path(os.getenv("DOCS_DIR", "data/documents"))
SCHEMA_FILE = Path(os.getenv("SCHEMA_FILE", "scripts/sql/schema.sql"))

CHUNK_WORDS = int(os.getenv("CHUNK_WORDS", "300"))
CHUNK_OVERLAP = int(os.getenv("CHUNK_OVERLAP", "50"))

DOC_PREFIX = "search_document: "

SUPPORTED_EXTENSIONS = {".md", ".txt"}

# --------------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------------

# for debugging
def log(msg: str) -> None:
    print(f"[ingest] {msg}", flush=True)

# keep running the check() function until it works or runs out of attempts
def wait_for(description: str, check, attempts: int = 60, delay: float = 5.0):
    for i in range(1, attempts + 1):
        try:
            return check()
        except Exception as exc:
            log(f"waiting for {description} ({i}/{attempts}): {exc}")
            time.sleep(delay)
    log(f"ERROR: {description} never became ready")
    sys.exit(1)


def connect_db():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, connect_timeout=5,
    )

# reads the filepath and splits the header content (title, source, etc) from the body
def parse_document(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    meta = {}
    match = re.match(r"^---\s*\n(.*?)\n---\s*\n", text, re.DOTALL)
    
    if match:
        for line in match.group(1).splitlines():
            if ":" in line:
                key, value = line.split(":", 1)
                meta[key.strip().lower()] = value.strip()
        text = text[match.end():]
        
    return {
        "file": path.name,
        "title": meta.get("title", path.stem),
        # `source` is what the web app shows to the user as the citation.
        "source": meta.get("source", path.name),
        "body": text.strip(),
    }

# (should) split text into overlapping windows of words
def chunk_words(text: str, size: int, overlap: int) -> list[str]:
    words = text.split()
    
    if not words:
        return []
    
    step = max(size - overlap, 1)
    chunks = []
    
    for start in range(0, len(words), step):
        window = words[start:start + size]
        chunks.append(" ".join(window))
        
        if start + size >= len(words):
            break
        
    return chunks

# map the filename and index to a specific row (should be the same)
def chunk_id(file_name: str, index: int) -> str:
    return hashlib.sha256(f"{file_name}:{index}".encode("utf-8")).hexdigest()

# get embedding from the local model
def embed(text: str) -> list[float]:
    resp = requests.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": DOC_PREFIX + text},
        timeout=120,
    )
    
    resp.raise_for_status()
    vector = resp.json()["embeddings"][0]
    
    if len(vector) != EMBED_DIM:
        raise ValueError(f"expected {EMBED_DIM} dims, got {len(vector)}; check EMBED_MODEL/schema")
    
    return vector

# converts the list of floats to a pgvector
def to_pgvector(vector: list[float]) -> str:
    return "[" + ",".join(f"{x:.8f}" for x in vector) + "]"

def main() -> None:
    files = sorted(p for p in DOCS_DIR.glob("**/*") if p.suffix.lower() in SUPPORTED_EXTENSIONS)
    if not files:
        log(f"ERROR: no documents found in {DOCS_DIR}")
        sys.exit(1)

    conn = wait_for("database", connect_db)
    conn.autocommit = False
    cur = conn.cursor()

    # ensure the schema exists
    cur.execute(SCHEMA_FILE.read_text(encoding="utf-8"))
    conn.commit()

    # make sure the embedding service is up
    wait_for("embedding service", lambda: requests.get(f"{OLLAMA_URL}/api/tags", timeout=5).raise_for_status())

    # load existing chunks so unchanged ones can be skipped
    cur.execute("SELECT id, content FROM chunks")
    existing = dict(cur.fetchall())

    inserted = updated = skipped = 0
    seen_ids = set()

    for path in files:
        doc = parse_document(path)
        chunks = chunk_words(doc["body"], CHUNK_WORDS, CHUNK_OVERLAP)
        log(f"{doc['file']}: {len(chunks)} chunk(s)")

        for index, content in enumerate(chunks):
            cid = chunk_id(doc["file"], index)
            seen_ids.add(cid)

            if existing.get(cid) == content:
                skipped += 1
                continue

            vector = to_pgvector(embed(content))
            cur.execute(
                """
                INSERT INTO chunks (id, source, title, chunk_index, content, embedding)
                VALUES (%s, %s, %s, %s, %s, %s::vector)
                ON CONFLICT (id) DO UPDATE SET
                    source      = EXCLUDED.source,
                    title       = EXCLUDED.title,
                    chunk_index = EXCLUDED.chunk_index,
                    content     = EXCLUDED.content,
                    embedding   = EXCLUDED.embedding
                """,
                (cid, doc["source"], doc["title"], index, content, vector),
            )
            if cid in existing:
                updated += 1
            else:
                inserted += 1

        conn.commit()  # commit per document so partial progress is kept

    # remove chunks from files that were deleted or shortened
    stale = [cid for cid in existing if cid not in seen_ids]
    if stale:
        cur.execute("DELETE FROM chunks WHERE id = ANY(%s)", (stale,))
        conn.commit()

    cur.execute("SELECT COUNT(*) FROM chunks")
    total = cur.fetchone()[0]
    log(f"done: {inserted} inserted, {updated} updated, {skipped} unchanged, {len(stale)} removed; {total} total chunks")

    cur.close()
    conn.close()


if __name__ == "__main__":
    main()