-- Read-only user for obs-api.
--
-- Created here rather than in the chart's users.xml because a password cannot
-- be hashed at Helm template time from a Secret. The bootstrap job substitutes
-- __OBSERVER_PASSWORD__ from the clickhouse-secrets Secret (key
-- observer-password, backed by GCP SM prod-clickhouse-observer-password).
--
-- OR REPLACE rather than IF NOT EXISTS so a password rotation in Secret Manager
-- actually reaches the database on the next run. Re-running with an unchanged
-- password is a no-op in effect.
--
-- ON CLUSTER so both replicas get the user; access storage is node-local, so
-- without it obs-api would authenticate against one replica and fail on the other.

CREATE USER OR REPLACE observer ON CLUSTER otel
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
