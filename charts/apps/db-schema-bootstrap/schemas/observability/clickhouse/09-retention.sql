-- Retention for tables the exporter has already created.
--
-- The exporter applies its `ttl` setting only to tables it creates fresh. Once
-- a table exists, changing the collector's ttl has no effect — this file is how
-- retention is actually changed in place.
--
-- ClickHouse has NO `ALTER TABLE IF EXISTS`. This file previously used it and
-- every run failed with a syntax error at the first statement -- and because
-- the bootstrap loop runs under `set -e`, that aborted the whole run, so no
-- file ordered after this one was ever applied. Retention happened to be
-- correct anyway because the exporter's own `ttl` setting matches what this
-- file asks for, which is why the breakage went unnoticed.
--
-- Numbered last for that reason: these statements fail on a cluster where the
-- exporter has not yet created its tables, and nothing else should be held
-- hostage to that.
--
-- 30 days on the high-volume signals; Kubernetes events are tiny and the most
-- useful thing to look back on, so they keep 90.
-- bootstrap:allow-unknown-table

ALTER TABLE otel.otel_logs ON CLUSTER otel
  MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;

ALTER TABLE otel.otel_traces ON CLUSTER otel
  MODIFY TTL toDateTime(Timestamp) + INTERVAL 30 DAY;

ALTER TABLE otel.otel_metrics_gauge ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;

ALTER TABLE otel.otel_metrics_sum ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;

ALTER TABLE otel.otel_metrics_histogram ON CLUSTER otel
  MODIFY TTL toDateTime(TimeUnix) + INTERVAL 30 DAY;
