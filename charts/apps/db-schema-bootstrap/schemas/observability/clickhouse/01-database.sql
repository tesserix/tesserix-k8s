-- Observability: the telemetry database.
--
-- Table DDL is deliberately NOT here. The otel-ingest collector's
-- clickhouseexporter owns the table schema (create_schema: true) and evolves it
-- across collector upgrades; hand-written DDL would drift from whatever version
-- of the exporter is deployed. With cluster_name + table_engine set, the
-- exporter creates its tables as ReplicatedMergeTree ON CLUSTER by itself.
--
-- What lives here is everything the exporter does NOT manage: the database, the
-- read-only user, and retention changes to already-created tables.
--
-- Applied every 30 minutes by the db-schema-bootstrap CronJob. Every statement
-- must be idempotent.

CREATE DATABASE IF NOT EXISTS otel ON CLUSTER otel;
CREATE DATABASE IF NOT EXISTS langfuse ON CLUSTER otel;
