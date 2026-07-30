-- ============================================================================
-- Dwellm8 — the whole schema for the dwellm8 database.
--
-- The bootstrap chart's contract is one .sql file per DATABASE, named after it
-- (db_name=$(basename "$sql_file" .sql)). Four files here meant four
-- databases, so the modules are sections of this one file instead.
--
-- Unlike the frozen pg_dump snapshots this chart was built for, every
-- statement below is idempotent by construction and safe to replay — which is
-- why dwellm8 sets applySchemaToExistingDatabases: true. Nothing here is
-- managed by an ORM at runtime, so there is no AutoMigrate to fight.
--
-- Sections:
--   1. Extensions and per-module roles
--   2. Tenancy — organisations, audit trail, RLS
--   3. Application and platform roles
--   4. Assertions that fail the bootstrap if the model is violated
-- ============================================================================


-- ===========================================================================
-- extensions and roles
-- ===========================================================================

-- Dwellm8 — extensions, and the roles that make ADR-0001's ownership rule real.
--
-- One writer per table is a review rule until the database enforces it. Each
-- module gets a role; the API connects as dwellm8_app, which is a member of
-- all of them, and a future extracted module connects as its own role only.
--
-- Idempotent: this file is replayed by the bootstrap CronJob every 30 minutes.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";      -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS "citext";        -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS "btree_gist";    -- exclusion constraints for effective dating

DO $$
DECLARE
    module_role text;
BEGIN
    FOREACH module_role IN ARRAY ARRAY[
        'dwellm8_identity', 'dwellm8_property', 'dwellm8_lease', 'dwellm8_money',
        'dwellm8_maintenance', 'dwellm8_community', 'dwellm8_discovery', 'dwellm8_notify'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = module_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', module_role);
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_app') THEN
        CREATE ROLE dwellm8_app NOLOGIN;
    END IF;
END
$$;

-- The monolith holds every module role. When a module is extracted per
-- ADR-0001 §6, it drops to its own role and this membership is revoked.
GRANT dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
      dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify
   TO dwellm8_app;

GRANT dwellm8_app TO dwellm8;

-- ===========================================================================
-- tenancy and audit
-- ===========================================================================

-- Organisations, and the two columns every tenant-scoped table carries.
--
-- tenant_id is the organisation. Row-level security is enforced against it on
-- every table that holds customer data, so a missing WHERE clause is a policy
-- violation rather than a data breach.

CREATE TABLE IF NOT EXISTS organisations (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            citext NOT NULL UNIQUE,
    name            text NOT NULL,
    kind            text NOT NULL CHECK (kind IN ('agency', 'owner', 'society', 'vendor', 'platform')),
    country         char(2) NOT NULL DEFAULT 'IN',
    -- A sandbox organisation holds demonstration data (M19). Nothing in it may
    -- ever cause a side effect: no money moves, no message is sent.
    is_sandbox      boolean NOT NULL DEFAULT false,
    state           text NOT NULL DEFAULT 'onboarding'
                    CHECK (state IN ('onboarding', 'active', 'suspended', 'closed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN organisations.is_sandbox IS
    'Demonstration data per requirements section 9.6 — no side effect may originate from it';

-- Every consequential action, in one append-only place. Written by every
-- module; corrected by nobody.
CREATE TABLE IF NOT EXISTS audit_events (
    id              bigserial PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    occurred_at     timestamptz NOT NULL DEFAULT now(),
    actor_id        uuid,
    actor_kind      text NOT NULL CHECK (actor_kind IN ('user', 'system', 'provider', 'support')),
    module          text NOT NULL CHECK (module IN (
                        'identity', 'property', 'lease', 'money',
                        'maintenance', 'community', 'discovery', 'notify')),
    action          text NOT NULL,
    subject_kind    text NOT NULL,
    subject_id      text NOT NULL,
    reason          text,
    detail          jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS audit_events_tenant_time_idx
    ON audit_events (tenant_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_subject_idx
    ON audit_events (subject_kind, subject_id);

-- ENABLE alone is not enough. A table's owner bypasses its own policies, and
-- the bootstrap job creates these tables as dwellm8 — so without FORCE, every
-- policy below is decorative for exactly the role the API connects as.
-- Reproduced: owner sees 2 of 2 rows with ENABLE, 1 of 2 with FORCE.
ALTER TABLE organisations ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisations FORCE  ROW LEVEL SECURITY;
ALTER TABLE audit_events  ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events  FORCE  ROW LEVEL SECURITY;

-- The API sets app.tenant_id per request. No tenant, no rows.
--
-- nullif() is load-bearing. current_setting(..., true) returns NULL when the
-- setting was never set but an empty string after RESET, and casting '' to uuid
-- raises — which would surface as a 500 rather than an empty result, and would
-- differ depending on whether the connection had been used before. Coercing ''
-- to NULL makes the comparison false either way: fail closed, quietly.
CREATE OR REPLACE FUNCTION current_tenant_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT nullif(current_setting('app.tenant_id', true), '')::uuid $$;

COMMENT ON FUNCTION current_tenant_id() IS
    'The organisation this request belongs to. NULL when unset, so every RLS policy denies.';

-- The platform exemption, written where a reviewer will see it.
--
-- A handful of operations cannot be tenant-scoped because they create or span
-- tenants: onboarding an organisation, platform reporting, an audited support
-- session. PostgreSQL's BYPASSRLS attribute would express this, but granting
-- it needs superuser, which CNPG deliberately withholds — and a role attribute
-- is invisible in a policy anyway. So the exemption lives in the policies, and
-- every one of them says out loud who is exempt.
CREATE OR REPLACE FUNCTION is_platform_session() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT pg_has_role(current_user, 'dwellm8_platform', 'member') $$;

COMMENT ON FUNCTION is_platform_session() IS
    'True for the few cross-tenant operations. Every use is written to audit_events.';

-- USING filters what a statement can see; WITH CHECK filters what it can
-- write. PostgreSQL falls back to USING when WITH CHECK is absent, so writes
-- are constrained either way — stating it is about being readable, and about
-- the day the two need to differ, when the fallback would quietly be wrong.
DROP POLICY IF EXISTS organisations_tenant_isolation ON organisations;
CREATE POLICY organisations_tenant_isolation ON organisations
    USING (id = current_tenant_id() OR is_platform_session())
    WITH CHECK (id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS audit_events_tenant_isolation ON audit_events;
CREATE POLICY audit_events_tenant_isolation ON audit_events
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

GRANT SELECT, INSERT, UPDATE ON organisations TO dwellm8_identity;
GRANT SELECT ON organisations TO dwellm8_property, dwellm8_lease, dwellm8_money,
    dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT INSERT, SELECT ON audit_events TO dwellm8_identity, dwellm8_property,
    dwellm8_lease, dwellm8_money, dwellm8_maintenance, dwellm8_community,
    dwellm8_discovery, dwellm8_notify;
GRANT USAGE, SELECT ON SEQUENCE audit_events_id_seq TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- ===========================================================================
-- app and platform roles
-- ===========================================================================

-- The two roles the application uses, and why there are two.
--
-- dwellm8_api  — everything a request does. Owns nothing, cannot bypass RLS,
--                and is the role a handler's connection runs as.
-- dwellm8_platform — the few operations that cannot be tenant-scoped, because
--                they create or span tenants: onboarding an organisation,
--                platform reporting, and an audited support session. Its
--                exemption is written into each policy via is_platform_session(),
--                not into a role attribute — BYPASSRLS needs superuser, which
--                CNPG withholds, and an attribute is invisible where it matters.
--
-- Creating an organisation is the clearest case. With FORCE row level security
-- on, an INSERT into organisations must satisfy the policy — and the policy
-- compares against the organisation being created, which does not exist yet.
-- No amount of policy cleverness fixes that; it is not a tenant-scoped act.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_api') THEN
        CREATE ROLE dwellm8_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_platform') THEN
        CREATE ROLE dwellm8_platform LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_api, dwellm8_platform;
GRANT USAGE ON SCHEMA public TO dwellm8_api, dwellm8_platform;
GRANT dwellm8_app TO dwellm8_api, dwellm8_platform;

ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dwellm8_app;
ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO dwellm8_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dwellm8_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dwellm8_app;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_platform_session() TO dwellm8_app;

-- No ALTER ROLE ... NOBYPASSRLS here: changing the attribute at all requires
-- superuser, which this job does not have and should not want. The roles are
-- created without it, and the guard that matters is the assertion in
-- 003_tenancy_assertions.sql, which fails the bootstrap if it ever appears.

-- ===========================================================================
-- tenancy assertions
-- ===========================================================================

-- Assertions about the tenancy model, run on every bootstrap.
--
-- Each of these has already been wrong once during development. A schema file
-- that shouts is worth more than a comment that hopes.

DO $$
DECLARE
    offending text;
BEGIN
    -- 1. Every tenant-scoped table must FORCE row level security, not merely
    --    enable it. A table's owner bypasses its own policies otherwise, and
    --    the bootstrap job is the owner.
    SELECT string_agg(c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relrowsecurity          -- RLS enabled
      AND NOT c.relforcerowsecurity -- but not forced
    ;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'RLS enabled but not FORCEd on: % — the owner would bypass every policy', offending;
    END IF;

    -- 2. Neither application role may hold BYPASSRLS. The platform exemption
    --    lives in the policies, where it is visible.
    SELECT string_agg(rolname, ', ') INTO offending
    FROM pg_roles
    WHERE rolname IN ('dwellm8_api', 'dwellm8_platform', 'dwellm8_app')
      AND rolbypassrls;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'role(s) hold BYPASSRLS: % — the exemption belongs in a policy', offending;
    END IF;

    -- 3. Every policy states WITH CHECK explicitly, so a reader does not have
    --    to know PostgreSQL's fallback rule to see that writes are constrained.
    SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO offending
    FROM pg_policies
    WHERE schemaname = 'public'
      AND cmd = 'ALL'
      AND with_check IS NULL;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'policy without an explicit WITH CHECK: %', offending;
    END IF;
END
$$;
