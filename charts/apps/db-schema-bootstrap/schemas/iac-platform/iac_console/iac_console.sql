-- ============================================================
-- IaC Platform Console Bootstrap (iac-platform backend)
-- Fully idempotent: safe to run on every bootstrap cycle.
--
-- Holds ONLY what the console itself owns:
--   * requests      — spoke PR lifecycle (create/delete), reviews, CI checks
--   * build_events  — durable audit trail of every provisioning/teardown event
--
-- Spokes/hubs are deliberately NOT stored here — Kubernetes claims are the
-- single source of truth and the console reads them live.
-- ============================================================

-- ============================================================
-- REQUESTS — one row per spoke PR (creation or deletion)
-- ============================================================

CREATE TABLE IF NOT EXISTS requests (
    id          TEXT PRIMARY KEY,
    kind        TEXT NOT NULL DEFAULT 'create',      -- create | delete
    spoke       TEXT NOT NULL,
    status      TEXT NOT NULL,                       -- open | merged | building | ready | failed | closed
    pr_number   INTEGER NOT NULL DEFAULT 0,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- Full store entry (request + parsed claim form + hub flag). The Go store
    -- hydrates whole entries; the columns above exist for indexing/reporting.
    entry       JSONB NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_requests_spoke      ON requests (spoke);
CREATE INDEX IF NOT EXISTS idx_requests_status     ON requests (status);
CREATE INDEX IF NOT EXISTS idx_requests_created_at ON requests (created_at DESC);

-- ============================================================
-- BUILD EVENTS — append-only audit of the live feed
-- ============================================================

CREATE TABLE IF NOT EXISTS build_events (
    id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ts        TIMESTAMPTZ NOT NULL,
    spoke     TEXT NOT NULL,
    phase     TEXT NOT NULL,                         -- pr | network | cluster | apps | done
    level     TEXT NOT NULL,                         -- info | success | warning | error
    source    TEXT NOT NULL DEFAULT '',              -- github | crossplane | k8s | aws | argo
    kind      TEXT NOT NULL DEFAULT '',
    name      TEXT NOT NULL DEFAULT '',
    reason    TEXT NOT NULL DEFAULT '',
    message   TEXT NOT NULL,
    progress  INTEGER NOT NULL DEFAULT 0
);

-- Idempotent column add for databases bootstrapped before `source` existed.
ALTER TABLE build_events ADD COLUMN IF NOT EXISTS source TEXT NOT NULL DEFAULT '';

CREATE INDEX IF NOT EXISTS idx_build_events_spoke_ts ON build_events (spoke, ts DESC);
CREATE INDEX IF NOT EXISTS idx_build_events_ts       ON build_events (ts DESC);
