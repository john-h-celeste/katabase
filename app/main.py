import asyncio
import json
import logging
import os
import socket
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
import psycopg2
from fastapi import FastAPI, Request
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

# ==================================================================
# CONSTANT DATA THIS FILE USES TO CONFIGURE ITSELF
# ==================================================================

DB_HOST = os.getenv("DB_HOST", "db")
DB_PORT = int(os.getenv("DB_PORT", "5432"))
DB_NAME = os.getenv("POSTGRES_DB", "ragdb")
DB_USER = os.getenv("POSTGRES_USER", "raguser")
DB_PASSWORD = os.environ["POSTGRES_PASSWORD"]

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://inference-lb:11434")
CHAT_MODEL = os.getenv("CHAT_MODEL", "llama3.2:3b")
EMBED_MODEL = os.getenv("EMBED_MODEL", "nomic-embed-text")

QUERY_PREFIX = "search_query: " # added to everything the end-user asks (for the embed model)

TOP_K = int(os.getenv("TOP_K", "4")) # chunks sent to the llm
NUM_CTX = int(os.getenv("NUM_CTX", "4096")) # context window requested (sorta like temporary memory)
TEMPERATURE = float(os.getenv("TEMPERATURE", "0.2")) # randomization for the output
# ^^ 0 for consistent answers and 1 or above for varied answers (can make stuff up though)

HOSTNAME = socket.gethostname()
STATIC_DIR = Path(__file__).parent / "static" # where the site is hosted

APP_ERROR = {
	"limited": "Please try again after a few minutes",
	"offline": "AI and/or API seems to be offline",
    "empty": "The knowledge base is empty (check ingestion)",
}

# (used for debugging)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rag-app")

# ========================================================================
# BASIC APP SETUP (for the web requests)

@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.http = httpx.AsyncClient(
        timeout=httpx.Timeout(connect=5.0, read=300.0, write=30.0, pool=10.0)
    )
    yield
    await app.state.http.aclose()

app = FastAPI(title="RAG Assistant", lifespan=lifespan)

@app.middleware("http")
async def add_served_by_header(request: Request, call_next):
    response = await call_next(request)
    response.headers["X-Served-By"] = HOSTNAME
    return response

class Question(BaseModel):
    question: str = Field(min_length=1, max_length=1000)

# ========================================================================
# APP LLM HELP

def sse(event: str, data) -> str:
    """Format one Server-Sent Event."""
    return f"event: {event}\ndata: {json.dumps(data)}\n\n"

# connect to the sql database
def db_connect():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME,
        user=DB_USER, password=DB_PASSWORD, connect_timeout=5,
    )

# returns the chunks closest to the query vector
def search_chunks(query_vector: list[float], k: int) -> list[dict]:
    vec = "[" + ",".join(f"{x:.8f}" for x in query_vector) + "]"
    conn = db_connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT source, title, content,
                       1 - (embedding <=> %s::vector) AS score
                FROM chunks
                ORDER BY embedding <=> %s::vector
                LIMIT %s
                """,
                (vec, vec, k),
            )
            return [
                {"source": s, "title": t, "content": c, "score": round(float(sc), 4)}
                for s, t, c, sc in cur.fetchall()
            ]
    finally:
        conn.close()

# sends the question to the embed model and returns the vector
async def embed_question(client: httpx.AsyncClient, question: str) -> list[float]:
    resp = await client.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": QUERY_PREFIX + question},
        timeout=60.0,
    )
    resp.raise_for_status()
    return resp.json()["embeddings"][0]

# default prompt for the llm's interaction with the user
def build_messages(question: str, chunks: list[dict]) -> list[dict]:
    context = "\n\n".join(
        f"[{i}] ({c['title']}) {c['content']}" for i, c in enumerate(chunks, 1)
    )
    
    system = (
        "You are a helpful assistant. Answer the question using ONLY the numbered "
        "context passages provided. If the answer is not in the context, say you "
        "don't know. Be concise, and mention the passage number(s) you used, like [1]."
    )
    
    user = f"Context:\n{context}\n\nQuestion: {question}"
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]

# ========================================================================
# WEB ROUTING CONFIGURATION

# load the default home page
app.get("/")
async def index():
    return FileResponse(STATIC_DIR / "index.html")

# endpoint to check if anything's wrong with the database
@app.get("/health")
async def health():
    try:
        conn = await asyncio.to_thread(db_connect)
        conn.close()
        return {"status": "ok", "host": HOSTNAME}
    except Exception as exc:  # noqa: BLE001
        log.warning("health check failed: %s", exc)
        return JSONResponse({"status": "db_unavailable"}, status_code=503)

# endpoint for the api to ask the ai a question and return a response
@app.post("/api/ask")
async def ask(body: Question, request: Request):
    client: httpx.AsyncClient = request.app.state.http
    question = body.question.strip()
    t0 = time.monotonic()

	# embed the question and retrive the context
    try:
        vector = await embed_question(client, question)
    except (httpx.HTTPError, KeyError, IndexError, ValueError) as exc:
        log.warning("embedding failed: %s", exc)
        return JSONResponse({"error": APP_ERROR["offline"]}, status_code=503)

	# try to search the database for the answer
    try:
        chunks = await asyncio.to_thread(search_chunks, vector, TOP_K)
    except Exception as exc:
        log.error("database search failed: %s", exc)
        return JSONResponse(
            {"error": APP_ERROR["offline"]},
            status_code=503,
        )

    if not chunks:
        return JSONResponse(
            {"error": APP_ERROR["empty"]},
            status_code=503,
        )

    sources = [
        {"n": i, "title": c["title"], "source": c["source"], "score": c["score"]}
        for i, c in enumerate(chunks, 1)
    ]
    
    payload = {
        "model": CHAT_MODEL,
        "messages": build_messages(question, chunks),
        "stream": True,
        "options": {"num_ctx": NUM_CTX, "temperature": TEMPERATURE},
    }

    # (gemini helped with this function -ymani)
    # streams the llm answer and reports its stats
    async def event_stream():
        yield sse("sources", sources)
        first_token_s = None
        
        try:
            async with client.stream("POST", f"{OLLAMA_URL}/api/chat", json=payload) as r:
                if r.status_code != 200:
                    raise httpx.HTTPStatusError(
                        f"inference returned {r.status_code}", request=r.request, response=r
                    )
                
                async for line in r.aiter_lines():
                    if not line:
                        continue
                    
                    obj = json.loads(line)
                    token = obj.get("message", {}).get("content", "")
                    
                    if token:
                        if first_token_s is None:
                            first_token_s = time.monotonic() - t0
                            
                        yield sse("token", {"t": token})
                        
                    if obj.get("done"):
                        eval_count = obj.get("eval_count")
                        eval_ns = obj.get("eval_duration")
                        tps = round(eval_count / (eval_ns / 1e9), 2) if eval_count and eval_ns else None
                        total = time.monotonic() - t0
                        
                        log.info(
                            "ask ok ttft=%.2fs tokens_per_s=%s total=%.2fs",
                            first_token_s or -1, tps, total,
                        )
                        
                        yield sse("done", {
                            "ttft_s": round(first_token_s, 2) if first_token_s else None,
                            "tokens_per_s": tps,
                            "total_s": round(total, 2),
                        })
                        
                        return
        except (httpx.HTTPError, json.JSONDecodeError) as exc:
            log.warning("inference failed mid-request: %s", exc)
            yield sse("error", {"message": APP_ERROR["offline"]})

    return StreamingResponse(
        event_stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
