-- Read-only user for obs-api.
--
-- Created here rather than in the chart's users.xml because a password cannot
-- be hashed at Helm template time from a Secret. The bootstrap job substitutes
-- __OBSERVER_PASSWORD__ from the clickhouse-secrets Secret (key
-- observer-password, backed by GCP SM prod-clickhouse-observer-password).
--
-- CREATE IF NOT EXISTS + ALTER, deliberately NOT `CREATE USER OR REPLACE`.
--
-- OR REPLACE drops the user and creates a new one, which mints a NEW UUID. This
-- job runs every 30 minutes, so the observer user was being re-issued twice an
-- hour while obs-api held pooled connections bound to the previous UUID. Those
-- connections then failed with:
--
--   code: 492, ID(<uuid>) not found in `user directories`
--
-- which surfaced in the UI as an intermittent "failed to query service health".
-- ALTER updates the password in place and leaves the UUID alone, so rotation
-- still reaches the database without invalidating live sessions.
--
-- ON CLUSTER so both replicas get the user; access storage is node-local, so
-- without it obs-api would authenticate against one replica and fail on the other.
-- Note the UUID still differs BETWEEN replicas — that is fine, authentication is
-- by name; what matters is that it is stable over time on each.

CREATE USER IF NOT EXISTS observer ON CLUSTER otel
  IDENTIFIED BY '__OBSERVER_PASSWORD__'
  HOST ANY
  SETTINGS PROFILE 'readonly';

-- Idempotent and UUID-preserving: applies a rotated password, no-op otherwise.
ALTER USER observer ON CLUSTER otel
  IDENTIFIED BY '__OBSERVER_PASSWORD__'
  HOST ANY
  SETTINGS PROFILE 'readonly';

-- SELECT only, scoped to the telemetry database. A compromised obs-api can read
-- telemetry but cannot drop, truncate or insert.
GRANT SELECT ON otel.* TO observer ON CLUSTER otel;

-- system table reads power the service-health views (parts, replication status,
-- table sizes) without granting anything on user data.
GRANT SELECT ON system.parts TO observer ON CLUSTER otel;
GRANT SELECT ON system.replicas TO observer ON CLUSTER otel;
GRANT SELECT ON system.tables TO observer ON CLUSTER otel;
