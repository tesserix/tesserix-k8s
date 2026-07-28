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
    created_at         DateTime,

    -- Everything below was added after the table shipped. New columns MUST be
    -- appended here in the same order as the ALTERs at the bottom of this file:
    -- the writer inserts positionally, so a fresh database and an altered one
    -- have to agree on physical column order.

    -- Identity of the BUG rather than of this occurrence: a hash of repository,
    -- source file and line. Two people tracing the same failing line produce
    -- the same fingerprint, which is what lets a recurrence update one incident
    -- instead of filing a second. Empty when the chain never reached a line.
    fingerprint        String,

    -- Triage as it stood when the incident was recorded. Stored rather than
    -- recomputed on read: priority is a function of volume and recency at a
    -- point in time, and an incident that was a P0 last Tuesday was a P0 last
    -- Tuesday even though the traffic has since stopped.
    --
    -- 'unknown' is first in each enum so it is also the value existing rows get
    -- when these columns are added -- an incident recorded before triage was
    -- persisted genuinely has no priority, and claiming P3 would be a lie.
    priority           Enum8('unknown' = 0, 'P0' = 1, 'P1' = 2, 'P2' = 3, 'P3' = 4),
    category           Enum8('unknown' = 0, 'config' = 1, 'dependency' = 2, 'data' = 3, 'code' = 4, 'infra' = 5, 'auth' = 6),
    domain             Enum8('unknown' = 0, 'general' = 1, 'payment' = 2, 'order' = 3, 'auth' = 4, 'delivery' = 5),
    -- The facts that drove the priority, joined with "; ". Kept so an operator
    -- can disagree with a P0 rather than either obeying or ignoring it.
    priority_reasons   String,

    -- How often the same source line was failing in the hour before this
    -- incident was recorded, and how many times the incident itself has been
    -- re-recorded since. The first is a property of the world, the second of
    -- this record -- they are not the same number and are kept apart.
    recurrence_count   UInt32,
    occurrence_count   UInt32 DEFAULT 1,
    last_seen_at       DateTime64(9) DEFAULT occurred_at,

    -- The image the failing process was running. Held alongside tag and digest
    -- so the chain can be resolved again from the incident alone, alive long
    -- after the originating log row has aged out of its 30-day window.
    image_name         String,

    -- The GitHub issue filed for this incident, if one was. Persisted so status
    -- changes here can be mirrored onto the issue -- without it the bug and the
    -- incident are permanently disconnected after the filing response is gone.
    issue_number       UInt32,
    issue_url          String
)
ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}', version)
ORDER BY incident_id;

-- Additive migrations for databases created before the columns above existed.
--
-- ADD COLUMN IF NOT EXISTS, not ALTER TABLE IF EXISTS: ClickHouse supports the
-- former and rejects the latter outright. Order here MUST match the tail of the
-- CREATE above, because a positional INSERT depends on it.
ALTER TABLE sre.incidents ON CLUSTER otel
    ADD COLUMN IF NOT EXISTS fingerprint      String,
    ADD COLUMN IF NOT EXISTS priority         Enum8('unknown' = 0, 'P0' = 1, 'P1' = 2, 'P2' = 3, 'P3' = 4),
    ADD COLUMN IF NOT EXISTS category         Enum8('unknown' = 0, 'config' = 1, 'dependency' = 2, 'data' = 3, 'code' = 4, 'infra' = 5, 'auth' = 6),
    ADD COLUMN IF NOT EXISTS domain           Enum8('unknown' = 0, 'general' = 1, 'payment' = 2, 'order' = 3, 'auth' = 4, 'delivery' = 5),
    ADD COLUMN IF NOT EXISTS priority_reasons String,
    ADD COLUMN IF NOT EXISTS recurrence_count UInt32,
    ADD COLUMN IF NOT EXISTS occurrence_count UInt32 DEFAULT 1,
    ADD COLUMN IF NOT EXISTS last_seen_at     DateTime64(9) DEFAULT occurred_at,
    ADD COLUMN IF NOT EXISTS image_name       String,
    ADD COLUMN IF NOT EXISTS issue_number     UInt32,
    ADD COLUMN IF NOT EXISTS issue_url        String;

-- The audit trail. Genuinely append-only, which is both what an audit trail
-- wants and what ClickHouse is best at -- so unlike the header above, this
-- table needs no deduplication and no FINAL on read.
CREATE TABLE IF NOT EXISTS sre.incident_events ON CLUSTER otel
(
    incident_id UUID,
    at          DateTime64(3),
    actor       LowCardinality(String),
    kind        Enum8('created' = 0, 'status_changed' = 1, 'note_added' = 2, 'reassigned' = 3, 'reresolved' = 4, 'recurred' = 5, 'issue_updated' = 6),
    detail      String
)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{uuid}/{shard}', '{replica}')
ORDER BY (incident_id, at);

-- Widen the enum for databases created before 'recurred' and 'issue_updated'
-- existed. Adding values to an Enum8 is metadata-only and re-applying the same
-- definition is a no-op, so this is safe on the 30-minute reconcile loop.
ALTER TABLE sre.incident_events ON CLUSTER otel
    MODIFY COLUMN kind Enum8('created' = 0, 'status_changed' = 1, 'note_added' = 2, 'reassigned' = 3, 'reresolved' = 4, 'recurred' = 5, 'issue_updated' = 6);

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
