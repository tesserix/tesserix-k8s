-- ===========================================================================
-- 010 tenancy
-- ===========================================================================

-- The API sets app.tenant_id per request. No tenant, no rows.
--
-- nullif() is load-bearing. current_setting(..., true) returns NULL when the
-- setting was never set but an empty string after RESET, and casting '' to uuid
-- raises — a 500 instead of an empty result, and differing depending on whether
-- the pooled connection had been used before. Coercing '' to NULL makes the
-- comparison false either way: fail closed, quietly.
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

COMMENT ON FUNCTION current_tenant_id() IS
    'The rental shop this request belongs to. NULL when unset, so every RLS policy denies.';

-- The platform exemption, written where a reviewer will see it.
--
-- Onboarding a shop, platform-wide reporting and an audited support action
-- cannot be tenant-scoped, because they create or span tenants. Rather than
-- granting BYPASSRLS — which is invisible at the call site and total — the
-- platform role opts in per transaction by setting app.platform_scope, and
-- every policy below reads it.
CREATE OR REPLACE FUNCTION is_platform_scope() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT coalesce(current_setting('app.platform_scope', true), '') = 'on'
       AND pg_has_role(current_user, 'vehicle_rental_platform_role', 'MEMBER') $$;

COMMENT ON FUNCTION is_platform_scope() IS
    'True only when a platform-role connection has explicitly opted out of tenant scoping for this transaction.';

-- Append-only. REVOKE UPDATE, DELETE lands in 900; the trigger here is the
-- second lock, because a role granted UPDATE by accident still cannot rewrite
-- history through it.
CREATE TABLE IF NOT EXISTS audit.entry (
    id           uuid NOT NULL DEFAULT uuid_generate_v7(),
    tenant_id    uuid,
    actor_type   text NOT NULL CHECK (actor_type IN ('staff','customer','system','platform')),
    actor_id     uuid,
    action       text NOT NULL,
    object_type  text NOT NULL,
    object_id    uuid,
    before       jsonb,
    after        jsonb,
    reason       text,
    ip           inet,
    at           timestamptz NOT NULL DEFAULT now(),
    -- `at` is in the key because Postgres requires every partitioning column in
    -- a unique constraint on a partitioned table.
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);

-- Partitions are created a year ahead by the bootstrap rather than by a
-- CronJob: an INSERT into a range-partitioned table with no matching partition
-- fails outright, and that must never be the reason a booking cannot be audited.
DO $$
DECLARE
    m date := date_trunc('month', now())::date;
    i int;
BEGIN
    FOR i IN -1..12 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS audit.entry_%s PARTITION OF audit.entry
               FOR VALUES FROM (%L) TO (%L)',
            to_char(m + (i || ' month')::interval, 'YYYY_MM'),
            (m + (i || ' month')::interval)::date,
            (m + ((i + 1) || ' month')::interval)::date);
    END LOOP;
END
$$;

CREATE INDEX IF NOT EXISTS audit_entry_tenant_at_idx
    ON audit.entry (tenant_id, at DESC);
