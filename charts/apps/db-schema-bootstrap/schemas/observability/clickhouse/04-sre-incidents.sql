-- SRE incidents: the audit trail behind trace-to-code.
--
-- Separate database from `otel` on purpose. The OTel exporter owns every table
-- in `otel` (create_schema: true) and evolves them across collector upgrades,
-- so anything hand-written there would eventually collide with whatever the
-- exporter decides its schema should be.
--
-- Applied every 30 minutes by the db-schema-bootstrap CronJob, so every
-- statement must be idempotent.

CREATE DATABASE IF NOT EXISTS sre ON CLUSTER otel;

-- An incident is a log line someone decided was worth keeping, together with
-- the resolved chain back to the code that produced it.
--
-- ReplacingMergeTree keyed on incident_id, deduplicated by `version`: an edit
-- (status change, reassignment) inserts a new row carrying a later version and
-- reads collapse to the newest. ClickHouse has no cheap UPDATE, and modelling
-- edits as inserts is the idiomatic answer rather than a workaround —
-- incidents are low-volume and edited rarely.
--
-- Reads MUST use FINAL or argMax. A plain SELECT returns every historical
-- version of an incident and would show a resolved incident as still open.
CREATE TABLE IF NOT EXISTS sre.incidents ON CLUSTER otel
(
    incident_id        UUID,
    -- Deduplication key. Wall-clock of the write, so the newest edit wins.
    version            DateTime64(3),

    -- Pointer back to the originating log row. This is the NATURAL key, not a
    -- hash: otel_logs has no primary key, and these three columns are what let
    -- the row be found again using the table's sort order instead of scanning
    -- the whole retention window.
    occurred_at        DateTime64(9),
    service_name       LowCardinality(String),
    service_namespace  LowCardinality(String),
    pod                String,
    trace_id           String,
    severity_number    UInt8,
    -- A copy of the message. The log itself ages out after 30 days while an
    -- incident is kept for as long as it is useful, so without this the record
    -- would eventually point at nothing.
    body_excerpt       String,

    -- Resolution. resolution_id is deterministic over (inputs, resolver
    -- version), which is what makes a stored incident replayable: re-running
    -- the chain and getting a different answer under the same resolver version
    -- means the world drifted -- a repo was renamed, a label stopped being
    -- emitted, a tag convention changed.
    resolution_id      String,
    resolver_version   UInt16,
    resolution_level   Enum8('none' = 0, 'build' = 1, 'file' = 2, 'line' = 3, 'blame' = 4),
    -- Why the chain stopped. Queryable, so "which services never reach blame?"
    -- is the rollout backlog rather than a guess.
    resolution_gap     String,

    repo               LowCardinality(String),
    build_commit       String,
    image_tag          String,
    image_digest       String,

    source_file        String,
    source_line        UInt32,
    source_function    String,

    blame_commit       String,
    blame_author       LowCardinality(String),
    blame_headline     String,
    blame_committed_at DateTime,
    -- 0 when the commit was pushed straight to the default branch, which is the
    -- norm in this estate. Zero here means "no PR exists", not "lookup failed".
    blame_pr           UInt32,

    title              String,
    status             Enum8('open' = 0, 'investigating' = 1, 'resolved' = 2, 'wont_fix' = 3),
    assignee           LowCardinality(String),
    created_by         LowCardinality(String),
    created_at         DateTime
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}', version)
ORDER BY incident_id;

-- The audit trail. Genuinely append-only, which is both what an audit trail
-- wants and what ClickHouse is best at -- so unlike the header above, this
-- table needs no deduplication and no FINAL on read.
CREATE TABLE IF NOT EXISTS sre.incident_events ON CLUSTER otel
(
    incident_id UUID,
    at          DateTime64(3),
    actor       LowCardinality(String),
    kind        Enum8('created' = 0, 'status_changed' = 1, 'note_added' = 2, 'reassigned' = 3, 'reresolved' = 4),
    detail      String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
ORDER BY (incident_id, at);

-- Writer account for obs-api's incident path.
--
-- A SECOND user, not a grant added to `observer`. observer carries SETTINGS
-- PROFILE 'readonly', which forbids INSERT outright no matter what is granted,
-- and that profile is the thing guaranteeing a compromised obs-api cannot
-- alter telemetry. Rather than weaken it, incident writes get their own
-- identity that has no access to `otel` at all.
--
-- CREATE IF NOT EXISTS + ALTER rather than CREATE OR REPLACE: OR REPLACE mints
-- a new UUID on every 30-minute run, and pooled connections bound to the old
-- one start failing with "ID(<uuid>) not found in user directories".
CREATE USER IF NOT EXISTS sre_writer ON CLUSTER otel
  IDENTIFIED BY '__SRE_WRITER_PASSWORD__'
  HOST ANY;

ALTER USER sre_writer ON CLUSTER otel
  IDENTIFIED BY '__SRE_WRITER_PASSWORD__'
  HOST ANY;

-- Scoped to `sre` and nothing else. No profile is applied, because a readonly
-- profile would defeat the entire purpose of this account.
GRANT SELECT, INSERT ON sre.* TO sre_writer ON CLUSTER otel;
