-- Support-platform RAG knowledge base — one shared table, namespaced
-- per tenant via the `namespace` column. The slm-router queries this
-- table by namespace (mark8ly / fanzone / homechef / stockpilot /
-- gameverse / horoscope / scrapper) so chunks never leak across
-- products.
--
-- All embeddings are bge-small-en (384 dims, L2-normalised). Cosine
-- distance via the HNSW index gives sub-millisecond top-k.

CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS chunks (
    id          TEXT PRIMARY KEY,
    namespace   TEXT NOT NULL,
    content     TEXT NOT NULL,
    embedding   VECTOR(384),
    metadata    JSONB DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chunks_namespace ON chunks (namespace);

-- HNSW gives approximate-nearest-neighbour cosine queries at
-- sub-millisecond. Trade-off: we don't always get the exact top-k,
-- which is fine for support — losing a chunk now and then is
-- better than 50ms+ p99 retrieval latency.
CREATE INDEX IF NOT EXISTS idx_chunks_embedding ON chunks
    USING hnsw (embedding vector_cosine_ops);

-- A separate index over rows missing embeddings, so the seed job
-- can run `SELECT id, content FROM chunks WHERE embedding IS NULL`
-- and not table-scan as the KB grows.
CREATE INDEX IF NOT EXISTS idx_chunks_pending_embedding
    ON chunks (created_at) WHERE embedding IS NULL;

-- Audit table — when content is added/removed we keep a trail so a
-- "why did the bot say that" question can be answered against the
-- exact chunk version that was retrieved.
CREATE TABLE IF NOT EXISTS chunk_audit (
    id          BIGSERIAL PRIMARY KEY,
    chunk_id    TEXT NOT NULL,
    namespace   TEXT NOT NULL,
    action      TEXT NOT NULL,                       -- inserted | updated | deleted
    snapshot    JSONB NOT NULL,                      -- full row at time of action
    actor       TEXT,                                 -- service or human that made the change
    happened_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_chunk_audit_chunk_id ON chunk_audit (chunk_id);
CREATE INDEX IF NOT EXISTS idx_chunk_audit_namespace_time
    ON chunk_audit (namespace, happened_at DESC);
