-- Agentic Registry schema — single source of truth (db-schema-bootstrap owns it
-- in production; the app's AUTO_MIGRATE is "false" there). Idempotent.
--
-- PROD placement: the registry reuses the shared devai-postgres CNPG cluster.
-- This file is named devai_db.sql so the bootstrap applies it to the EXISTING
-- `devai_db` database (no CREATE DATABASE needed — the `devai` owner role has
-- no CREATEDB on this enableSuperuserAccess:false cluster). The registry lives
-- in its own `registry` schema, isolated from devai's `public` tables; the app
-- fully schema-qualifies every statement (registry.artifacts, ...).
--
-- NOTE: pgvector is intentionally omitted here — devai-postgres runs
-- ghcr.io/cloudnative-pg/postgresql:16.4 which has no `vector` extension. The
-- app is deployed with VECTOR_SEARCH=false. If the cluster image gains
-- pgvector later, add back the `CREATE EXTENSION vector` + embedding column +
-- hnsw index block (see the OSS embedded schema in internal/store/postgres.go).

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

-- ---------------------------------------------------------------------------
-- Append-only audit timeline. One immutable row per content change (including
-- overwrites of the floating "latest" tag), so history survives mutation.
-- Revision numbers are monotonic per (kind, namespace, name, tag).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS registry.artifact_revisions (
    kind         text        NOT NULL,
    namespace    text        NOT NULL,
    name         text        NOT NULL,
    tag          text        NOT NULL,
    revision     bigint      NOT NULL,
    uid          uuid        NOT NULL,
    api_version  text        NOT NULL,
    visibility   text        NOT NULL,
    tenant_id    text        NOT NULL,
    org_id       text,
    team_id      text,
    content_hash char(64)    NOT NULL,
    labels       jsonb       NOT NULL DEFAULT '{}',
    annotations  jsonb       NOT NULL DEFAULT '{}',
    spec         jsonb       NOT NULL DEFAULT '{}',
    status       jsonb       NOT NULL DEFAULT '{}',
    created_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (kind, namespace, name, tag, revision)
);
CREATE INDEX IF NOT EXISTS idx_revisions_artifact
    ON registry.artifact_revisions (kind, namespace, name, created_at DESC);

-- Seed an initial revision for any pre-existing artifact (idempotent backfill).
INSERT INTO registry.artifact_revisions
    (kind, namespace, name, tag, revision, uid, api_version, visibility, tenant_id, org_id, team_id,
     content_hash, labels, annotations, spec, status, created_at)
SELECT a.kind, a.namespace, a.name, a.tag, 1, a.uid, a.api_version, a.visibility, a.tenant_id, a.org_id, a.team_id,
       a.content_hash, a.labels, a.annotations, a.spec, a.status, a.created_at
FROM registry.artifacts a
WHERE NOT EXISTS (
    SELECT 1 FROM registry.artifact_revisions r
    WHERE r.kind=a.kind AND r.namespace=a.namespace AND r.name=a.name AND r.tag=a.tag
);
