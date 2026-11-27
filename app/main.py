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
	"offline": "AI seems to be offline"
}

# (used for debugging)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("rag-app")

# ========================================================================

#TODO: Finish the rest of this