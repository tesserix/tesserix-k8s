-- Retention for tables the exporter has already created.
--
-- The exporter applies its `ttl` setting only to tables it creates fresh. Once
-- a table exists, changing the collector's ttl has no effect — this file is how
-- retention is actually changed in place.
--
-- Guarded by EXISTS checks via ON CLUSTER + IF EXISTS so a run before the
-- exporter has created anything is a harmless no-op.
--
-- 30 days on the high-volume signals; Kubernetes events are tiny and the most
-- useful thing to look back on, so they keep 90.

ALTER TABLE IF EXISTS otel.otel_logs ON CLUSTER otel
  MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;

ALTER TABLE IF EXISTS otel.otel_traces ON CLUSTER otel
  MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;

ALTER TABLE IF EXISTS otel.otel_metrics_gauge ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;

ALTER TABLE IF EXISTS otel.otel_metrics_sum ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;

ALTER TABLE IF EXISTS otel.otel_metrics_histogram ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;
