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

-- ---------------------------------------------------------------------------
-- delegation grants (ADR-0005)
-- ---------------------------------------------------------------------------
--
-- A management firm manages units it does not own. It reaches them through a
-- grant: an explicit, scoped, effective-dated, revocable row written by the
-- owner — never a second tenant_id, and never a shared row.
--
-- The grant lives in the GRANTOR's tenant, because it is the owner's decision
-- to make and the owner's to end. The grantee must nonetheless be able to read
-- it, which is why this is the first policy in the schema whose USING and
-- WITH CHECK genuinely differ: two organisations may see the row, one may
-- write it.

CREATE TABLE IF NOT EXISTS delegation_grants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- the grantor: the organisation whose data is being delegated
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    grantee_org_id  uuid NOT NULL REFERENCES organisations(id),
    permissions     text[] NOT NULL,
    valid_from      timestamptz NOT NULL DEFAULT now(),
    valid_to        timestamptz,
    revoked_at      timestamptz,
    revoked_by      uuid,
    revoked_reason  text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    CONSTRAINT delegation_grants_not_self CHECK (grantee_org_id <> tenant_id),
    CONSTRAINT delegation_grants_window   CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- A closed vocabulary, so a typo is a constraint violation rather than a
    -- permission nobody holds. identity.* is deliberately absent: a grant never
    -- confers control of the owner's account, and re-delegation is not a
    -- permission at all — see the WITH CHECK below.
    CONSTRAINT delegation_grants_perms    CHECK (
        cardinality(permissions) > 0 AND permissions <@ ARRAY[
            'property.read',    'property.write',
            'lease.read',       'lease.write',
            'money.read',       'money.collect', 'money.payout',
            'maintenance.read', 'maintenance.write',
            'document.read',    'document.write',
            'community.read',   'community.write'
        ]::text[])
);

COMMENT ON TABLE delegation_grants IS
    'ADR-0005. Rows are never deleted: a revoked grant is the evidence of what was permitted when.';

-- What the grant covers. Enumerated rows rather than a predicate, so "two of
-- the five units" is answerable by a join and visible in a UI.
--
-- scope_id is not a foreign key yet: properties and units arrive with ADR-0009,
-- which adds the reference. Stating that here is better than a column that
-- quietly points at nothing forever.
CREATE TABLE IF NOT EXISTS delegation_grant_scopes (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grant_id    uuid NOT NULL REFERENCES delegation_grants(id),
    tenant_id   uuid NOT NULL REFERENCES organisations(id),
    scope_kind  text NOT NULL CHECK (scope_kind IN ('portfolio', 'property', 'unit')),
    scope_id    uuid,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT delegation_grant_scopes_shape
        CHECK ((scope_kind = 'portfolio') = (scope_id IS NULL))
);

CREATE UNIQUE INDEX IF NOT EXISTS delegation_grant_scopes_unique
    ON delegation_grant_scopes (grant_id, scope_kind, scope_id);
-- 'portfolio' carries a NULL scope_id, and NULLs are distinct to a unique
-- index, so the constraint above would happily allow it twice.
CREATE UNIQUE INDEX IF NOT EXISTS delegation_grant_scopes_portfolio
    ON delegation_grant_scopes (grant_id) WHERE scope_kind = 'portfolio';
CREATE INDEX IF NOT EXISTS delegation_grants_grantee_idx
    ON delegation_grants (grantee_org_id, tenant_id);

-- Every consequential action, in one append-only place. Written by every
-- module; corrected by nobody.
--
-- actor_org_id and grant_id are how an access made under a delegation is
-- distinguishable from the owner's own. An audit row written under a grant
-- lands in the OWNER's tenant — it is the owner's record of who looked at
-- their data — stamped with the firm that looked and the grant they used.
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
    detail          jsonb NOT NULL DEFAULT '{}'::jsonb,
    actor_org_id    uuid REFERENCES organisations(id),
    grant_id        uuid REFERENCES delegation_grants(id)
);

-- For databases created before ADR-0005: CREATE TABLE IF NOT EXISTS does not
-- add columns to a table that already exists.
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS actor_org_id uuid REFERENCES organisations(id);
ALTER TABLE audit_events ADD COLUMN IF NOT EXISTS grant_id     uuid REFERENCES delegation_grants(id);

CREATE INDEX IF NOT EXISTS audit_events_grant_idx
    ON audit_events (grant_id, occurred_at DESC) WHERE grant_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS audit_events_tenant_time_idx
    ON audit_events (tenant_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_subject_idx
    ON audit_events (subject_kind, subject_id);

-- ENABLE alone is not enough. A table's owner bypasses its own policies, and
-- the bootstrap job creates these tables as dwellm8 — so without FORCE, every
-- policy below is decorative for exactly the role the API connects as.
-- Reproduced: owner sees 2 of 2 rows with ENABLE, 1 of 2 with FORCE.
ALTER TABLE organisations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisations           FORCE  ROW LEVEL SECURITY;
ALTER TABLE audit_events            ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_events            FORCE  ROW LEVEL SECURITY;
ALTER TABLE delegation_grants       ENABLE ROW LEVEL SECURITY;
ALTER TABLE delegation_grants       FORCE  ROW LEVEL SECURITY;
ALTER TABLE delegation_grant_scopes ENABLE ROW LEVEL SECURITY;
ALTER TABLE delegation_grant_scopes FORCE  ROW LEVEL SECURITY;

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

-- The active grant, if the request declared one. Same nullif() treatment and
-- for the same reason: a RESET connection reports '' rather than NULL.
CREATE OR REPLACE FUNCTION current_grant_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT nullif(current_setting('app.grant_id', true), '')::uuid $$;

COMMENT ON FUNCTION current_grant_id() IS
    'The delegation the request is acting under, or NULL. Declared, never trusted — is_delegated() validates it.';

-- The one place a row belonging to another organisation becomes reachable.
--
-- Nothing here is taken on trust. app.grant_id is a claim; every clause below
-- is the check. The grant must exist, name the current tenant as its grantee,
-- name the row's owner as its grantor, be live now, carry the permission the
-- policy asks for, and cover the property the row belongs to. Miss any one and
-- the answer is false, which is a row the session cannot see.
--
-- It is not SECURITY DEFINER, deliberately. The lookup runs under the caller's
-- own row-level security, so a session that quotes a grant id belonging to
-- somebody else finds nothing — the policy on delegation_grants hides it. That
-- is a second, independent refusal behind the first.
--
-- row_property NULL means "this row is not property-scoped" — an audit entry,
-- say. Passing NULL from a table that DOES have a property_id would widen the
-- grant to the grantor's whole portfolio, so the assertions at the foot of this
-- file fail any such table.
CREATE OR REPLACE FUNCTION is_delegated(row_tenant uuid, row_property uuid, required_permission text)
    RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT EXISTS (
        SELECT 1
          FROM delegation_grants g
         WHERE g.id             = current_grant_id()
           AND g.grantee_org_id = current_tenant_id()
           AND g.tenant_id      = row_tenant
           AND g.revoked_at IS NULL
           AND now() >= g.valid_from
           AND (g.valid_to IS NULL OR now() < g.valid_to)
           -- 'audit' is implied by every grant. Access that cannot be recorded
           -- would be access without a trace, so it is not a permission an
           -- owner can accidentally withhold.
           AND (required_permission = 'audit' OR required_permission = ANY (g.permissions))
           AND (row_property IS NULL OR EXISTS (
                   SELECT 1 FROM delegation_grant_scopes s
                    WHERE s.grant_id = g.id
                      AND (s.scope_kind = 'portfolio' OR s.scope_id = row_property)))
    )
$$;

COMMENT ON FUNCTION is_delegated(uuid, uuid, text) IS
    'ADR-0005. True when the declared grant genuinely covers this row for this permission, right now.';

-- USING filters what a statement can see; WITH CHECK filters what it can
-- write. PostgreSQL falls back to USING when WITH CHECK is absent, so writes
-- are constrained either way — stating it is about being readable, and about
-- the day the two need to differ, when the fallback would quietly be wrong.
DROP POLICY IF EXISTS organisations_tenant_isolation ON organisations;
CREATE POLICY organisations_tenant_isolation ON organisations
    USING (id = current_tenant_id() OR is_platform_session())
    WITH CHECK (id = current_tenant_id() OR is_platform_session());

-- The delegated branch. A firm sees the owner's audit rows written under its
-- own grant and no others — the grant is a window onto the access it made, not
-- onto the owner's history.
--
-- The write branch is the interesting one. A delegated session may write into
-- the owner's tenant, because that is where the record of the access belongs;
-- it may only do so stamped with itself and with the grant it is using. A firm
-- can therefore add to the owner's audit trail but cannot forge an entry in the
-- owner's name.
DROP POLICY IF EXISTS audit_events_tenant_isolation ON audit_events;
CREATE POLICY audit_events_tenant_isolation ON audit_events
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (grant_id = current_grant_id()
               AND is_delegated(tenant_id, NULL, 'audit')))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (grant_id = current_grant_id()
               AND actor_org_id = current_tenant_id()
               AND is_delegated(tenant_id, NULL, 'audit')));

-- The grant itself: read by two organisations, written by one.
--
-- USING names the grantee, so a firm can see the mandate it holds and the ones
-- it used to hold. WITH CHECK does not, so only the owner creates, amends or
-- revokes. This is the divergence ADR-0003 said the fallback would get wrong,
-- arriving on schedule.
--
-- current_grant_id() IS NULL in WITH CHECK is what makes grants non-transitive:
-- a session acting under a delegation cannot write a grant at all, so a firm
-- cannot pass the owner's units on to a sub-contractor. Onward delegation is not
-- a permission that was withheld; it is an operation that does not exist.
--
-- No call to is_delegated() here, which is deliberate: the policy that governs
-- the grants table must not consult the grants table.
DROP POLICY IF EXISTS delegation_grants_access ON delegation_grants;
CREATE POLICY delegation_grants_access ON delegation_grants
    USING (tenant_id = current_tenant_id()
           OR grantee_org_id = current_tenant_id()
           OR is_platform_session())
    WITH CHECK ((tenant_id = current_tenant_id() AND current_grant_id() IS NULL)
           OR is_platform_session());

-- Without this, a grantee deletes the grant it can see — and with it the record
-- of everything it was allowed to do. Reproduced: DELETE 1 as the grantee with
-- the privilege held and this policy absent; DELETE 0 with it present. The
-- REVOKE further down is the second lock on the same door, not a substitute.
--
-- RESTRICTIVE, so it ANDs with the policy above instead of ORing with it.
-- Revocation is an UPDATE that sets revoked_at; nothing here is ever removed.
DROP POLICY IF EXISTS delegation_grants_no_delete ON delegation_grants;
CREATE POLICY delegation_grants_no_delete ON delegation_grants
    AS RESTRICTIVE FOR DELETE USING (false);

DROP POLICY IF EXISTS delegation_grant_scopes_access ON delegation_grant_scopes;
CREATE POLICY delegation_grant_scopes_access ON delegation_grant_scopes
    USING (tenant_id = current_tenant_id()
           OR EXISTS (SELECT 1 FROM delegation_grants g
                       WHERE g.id = delegation_grant_scopes.grant_id
                         AND g.grantee_org_id = current_tenant_id())
           OR is_platform_session())
    WITH CHECK ((tenant_id = current_tenant_id() AND current_grant_id() IS NULL)
           OR is_platform_session());

DROP POLICY IF EXISTS delegation_grant_scopes_no_delete ON delegation_grant_scopes;
CREATE POLICY delegation_grant_scopes_no_delete ON delegation_grant_scopes
    AS RESTRICTIVE FOR DELETE USING (false);

GRANT SELECT, INSERT, UPDATE ON organisations TO dwellm8_identity;
GRANT SELECT ON organisations TO dwellm8_property, dwellm8_lease, dwellm8_money,
    dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT INSERT, SELECT ON audit_events TO dwellm8_identity, dwellm8_property,
    dwellm8_lease, dwellm8_money, dwellm8_maintenance, dwellm8_community,
    dwellm8_discovery, dwellm8_notify;
GRANT USAGE, SELECT ON SEQUENCE audit_events_id_seq TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- Identity owns the grant lifecycle; every other module reads grants because
-- its policies do. is_delegated() runs under the caller's privileges, so a role
-- without SELECT here would get "permission denied" from inside a policy — an
-- error, where the whole design says the answer should be "no rows". Granting
-- to dwellm8_app alone would leave exactly that trap for the first module
-- extracted per ADR-0001 §6, which connects as its own role.
GRANT SELECT, INSERT, UPDATE ON delegation_grants, delegation_grant_scopes
    TO dwellm8_identity;
GRANT SELECT ON delegation_grants, delegation_grant_scopes TO dwellm8_property,
    dwellm8_lease, dwellm8_money, dwellm8_maintenance, dwellm8_community,
    dwellm8_discovery, dwellm8_notify;
GRANT EXECUTE ON FUNCTION current_grant_id() TO dwellm8_identity, dwellm8_property,
    dwellm8_lease, dwellm8_money, dwellm8_maintenance, dwellm8_community,
    dwellm8_discovery, dwellm8_notify;
GRANT EXECUTE ON FUNCTION is_delegated(uuid, uuid, text) TO dwellm8_identity,
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
GRANT EXECUTE ON FUNCTION current_grant_id() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_delegated(uuid, uuid, text) TO dwellm8_app;

-- After the blanket grant above, not before it, or it would hand DELETE straight
-- back. A grant is history the moment it exists: the RESTRICTIVE policy refuses
-- the delete, and withholding the privilege means a session never reaches the
-- policy at all. Two locks, because the record of who was allowed to touch an
-- owner's property is exactly what a bad actor would want gone.
REVOKE DELETE ON delegation_grants, delegation_grant_scopes FROM dwellm8_app;

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

    -- 4. Neither delegation table may be deletable. Losing a revoked grant
    --    loses the record of what a firm was permitted to do, and when — which
    --    is the one thing an owner would later need. ADR-0005.
    SELECT string_agg(t, ', ') INTO offending
    FROM unnest(ARRAY['delegation_grants', 'delegation_grant_scopes']) AS t
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           -- pg_policies.permissive is text, not boolean: 'RESTRICTIVE'.
           AND p.cmd = 'DELETE' AND p.permissive = 'RESTRICTIVE' AND p.qual = 'false');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'no RESTRICTIVE deny-delete policy on: % — a grantee could erase the evidence', offending;
    END IF;

    -- 5. A table that is property-scoped must say so in its policy. Passing
    --    NULL for row_property, or omitting the delegated branch entirely,
    --    silently widens a two-unit grant to the grantor's whole portfolio.
    --    This bites the first time a module lands a property_id (ADR-0009).
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns col
      ON col.table_schema = 'public' AND col.table_name = c.relname
     AND col.column_name = 'property_id'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND NOT EXISTS (
          SELECT 1 FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
             AND p.qual LIKE '%is_delegated(%property_id%');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) with property_id whose policy does not pass it to is_delegated(): % '
                        '— a scoped grant would widen to the whole portfolio', offending;
    END IF;
END
$$;
