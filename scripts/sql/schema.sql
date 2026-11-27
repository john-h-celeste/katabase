CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS chunks (
    id          TEXT PRIMARY KEY,
    source      TEXT NOT NULL,
    title       TEXT,
    chunk_index INT  NOT NULL,
    content     TEXT NOT NULL,
    embedding   vector(768)
);