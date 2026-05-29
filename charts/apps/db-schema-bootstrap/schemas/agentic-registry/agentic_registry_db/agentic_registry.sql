-- Agentic Registry schema — single source of truth (db-schema-bootstrap owns it
-- in production; the app's AUTO_MIGRATE is set to "false" there). Idempotent.
--
-- One envelope table: apiVersion/kind/metadata/spec/status. spec/status/labels
-- are JSONB; identity + scope are promoted to columns and GIN/btree indexed.

CREATE SCHEMA IF NOT EXISTS registry;

CREATE TABLE IF NOT EXISTS registry.artifacts (
    kind               text        NOT NULL,
    namespace          text        NOT NULL,
    name               text        NOT NULL,
    tag                text        NOT NULL,
    uid                uuid        NOT NULL,
    api_version        text        NOT NULL,
    visibility         text        NOT NULL DEFAULT 'private',
    tenant_id          text        NOT NULL,
    org_id             text,
    team_id            text,
    content_hash       char(64)    NOT NULL,
    labels             jsonb       NOT NULL DEFAULT '{}',
    annotations        jsonb       NOT NULL DEFAULT '{}',
    spec               jsonb       NOT NULL DEFAULT '{}',
    status             jsonb       NOT NULL DEFAULT '{}',
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    deletion_timestamp timestamptz,
    PRIMARY KEY (kind, namespace, name, tag)
);

-- GIN on labels (jsonb_path_ops) backs label-selector discovery.
CREATE INDEX IF NOT EXISTS idx_artifacts_labels  ON registry.artifacts USING gin (labels jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_artifacts_kind_ns ON registry.artifacts (kind, namespace);
CREATE INDEX IF NOT EXISTS idx_artifacts_updated ON registry.artifacts (updated_at);
CREATE INDEX IF NOT EXISTS idx_artifacts_tenant  ON registry.artifacts (tenant_id);
