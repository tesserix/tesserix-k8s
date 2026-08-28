-- Agentic Registry schema — single source of truth (db-schema-bootstrap owns it
-- in production; the app's AUTO_MIGRATE is "false" there). Idempotent.
--
-- PROD placement: applied to the registry's OWN in-namespace CNPG cluster
-- (agentregistry-postgres) by db-schema-bootstrap. The database
-- `agentic_registry_db` is created by CNPG bootstrap, so the file is named
-- agentic_registry_db.sql and the bootstrap just applies this idempotent DDL as
-- its owner (`agentregistry`) — no CREATE DATABASE needed. The app fully
-- schema-qualifies every statement (registry.artifacts, ...).
--
-- The CNPG operand image includes pgvector. This file is applied as the CNPG
-- superuser because `vector` is not a trusted extension; the application role
-- remains the owner of the authoritative artifact tables.

CREATE EXTENSION IF NOT EXISTS vector;

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

ALTER TABLE registry.artifacts
    ADD COLUMN IF NOT EXISTS embedding vector(256);

-- GIN on labels (jsonb_path_ops) backs label-selector discovery.
CREATE INDEX IF NOT EXISTS idx_artifacts_labels  ON registry.artifacts USING gin (labels jsonb_path_ops);
CREATE INDEX IF NOT EXISTS idx_artifacts_kind_ns ON registry.artifacts (kind, namespace);
CREATE INDEX IF NOT EXISTS idx_artifacts_updated ON registry.artifacts (updated_at);
CREATE INDEX IF NOT EXISTS idx_artifacts_tenant  ON registry.artifacts (tenant_id);
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_artifacts_embedding
    ON registry.artifacts USING hnsw (embedding vector_cosine_ops);

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

-- Atomic bundle publication records the original result for safe retries and
-- commits an integration event in the same transaction as artifact changes.
CREATE TABLE IF NOT EXISTS registry.publish_idempotency (
    actor_scope  text        NOT NULL,
    key          text        NOT NULL,
    request_hash char(64)    NOT NULL,
    result       jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    PRIMARY KEY (actor_scope, key)
);
CREATE INDEX IF NOT EXISTS idx_publish_idempotency_expiry
    ON registry.publish_idempotency (expires_at);

CREATE TABLE IF NOT EXISTS registry.publish_outbox (
    id           uuid        PRIMARY KEY,
    actor_scope  text        NOT NULL,
    event_type   text        NOT NULL,
    payload      jsonb       NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    published_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_publish_outbox_unpublished
    ON registry.publish_outbox (created_at, id) WHERE published_at IS NULL;

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
