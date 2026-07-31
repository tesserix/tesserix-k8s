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
--   3. Property, block and unit — the tree everything else hangs from
--   4. Ledger — chart of accounts, immutable postings, derived balances
--   5. Application and platform roles
--   6. Data migrations — after the roles, or they silently touch nothing
--   7. Assertions that fail the bootstrap if the model is violated
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
-- scope_id stays polymorphic — a property id or a unit id, depending on
-- scope_kind — so it is not a foreign key even now that ADR-0009 has landed the
-- tables it points at. What validates it is delegation_scope_target() below,
-- which is strictly stronger than a reference: it also requires the target to
-- belong to the grantor. An owner cannot scope a grant to somebody else's
-- building, which is a thing a foreign key would happily allow.
--
-- scope_property_id is the property a scope row resolves to: itself for a
-- property scope, the containing property for a unit scope, NULL for a
-- portfolio. The trigger stamps it, so is_delegated() never has to read units
-- from inside a policy — see ADR-0009 §4 for what that read cost when it was
-- tried.
CREATE TABLE IF NOT EXISTS delegation_grant_scopes (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    grant_id          uuid NOT NULL REFERENCES delegation_grants(id),
    tenant_id         uuid NOT NULL REFERENCES organisations(id),
    scope_kind        text NOT NULL CHECK (scope_kind IN ('portfolio', 'property', 'unit')),
    scope_id          uuid,
    scope_property_id uuid,
    created_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT delegation_grant_scopes_shape
        CHECK ((scope_kind = 'portfolio') = (scope_id IS NULL))
);

-- For databases created before ADR-0009. Adding the column is DDL and works
-- here; backfilling it is DML and cannot — see the migrations section at the
-- foot of this file for why it lives there instead.
ALTER TABLE delegation_grant_scopes ADD COLUMN IF NOT EXISTS scope_property_id uuid;

CREATE UNIQUE INDEX IF NOT EXISTS delegation_grant_scopes_unique
    ON delegation_grant_scopes (grant_id, scope_kind, scope_id);
-- The lookup every delegated read performs: this grant, this property.
CREATE INDEX IF NOT EXISTS delegation_grant_scopes_property_idx
    ON delegation_grant_scopes (grant_id, scope_property_id);
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
--
-- 'USAGE', not 'MEMBER', and the difference is not cosmetic. It was 'MEMBER'
-- until ADR-0006 measured what that means on PostgreSQL 16:
--
--   owner   member=t usage=f is_platform_session=t rows_visible=161
--   api     member=f usage=f is_platform_session=f rows_visible=0
--
-- From PostgreSQL 16, a CREATEROLE role is automatically granted every role it
-- creates — WITH ADMIN TRUE, INHERIT FALSE, SET FALSE. The bootstrap job has
-- CREATEROLE and creates dwellm8_platform, so it acquires a bookkeeping
-- membership of it, and 'MEMBER' answers true for a membership whose privileges
-- are explicitly not inherited. Every session connecting as the table owner was
-- therefore platform-exempt: 161 postings across every organisation, from a
-- connection that should have seen none, with every policy in this file reading
-- correctly. ADR-0009 §6 argued against granting the owner this membership; the
-- server had already granted it.
--
-- 'USAGE' asks the question the exemption actually means — are this role's
-- privileges in force for this session — and answers false for the admin-only
-- grant while staying true for dwellm8_platform itself. Assertion 11 fails the
-- bootstrap if any table owner ever does inherit it.
CREATE OR REPLACE FUNCTION is_platform_session() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT pg_has_role(current_user, 'dwellm8_platform', 'USAGE') $$;

COMMENT ON FUNCTION is_platform_session() IS
    'True for the few cross-tenant operations. Every use is written to audit_events.';

-- The active grant, if the request declared one. Same nullif() treatment and
-- for the same reason: a RESET connection reports '' rather than NULL.
CREATE OR REPLACE FUNCTION current_grant_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT nullif(current_setting('app.grant_id', true), '')::uuid $$;

COMMENT ON FUNCTION current_grant_id() IS
    'The delegation the request is acting under, or NULL. Declared, never trusted — is_delegated() validates it.';

-- The grant half of the check: is the grant this session declared a real, live
-- grant from this row's owner to this tenant, carrying this permission?
--
-- Factored out because ADR-0009 added a second scope-level check, and six
-- conditions duplicated between two functions is how one of them quietly stops
-- checking who the grantee is. The CI step that plants exactly that defect is
-- proof the risk is not theoretical.
--
-- Returns the grant id rather than a boolean so the scope lookups below can
-- join on it. At most one row: g.id = current_grant_id() is the primary key.
--
-- It is not SECURITY DEFINER, deliberately. The lookup runs under the caller's
-- own row-level security, so a session that quotes a grant id belonging to
-- somebody else finds nothing — the policy on delegation_grants hides it. That
-- is a second, independent refusal behind the first.
CREATE OR REPLACE FUNCTION current_active_grant(row_tenant uuid, required_permission text)
    RETURNS uuid LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT g.id
      FROM delegation_grants g
     WHERE g.id             = current_grant_id()
       AND g.grantee_org_id = current_tenant_id()
       AND g.tenant_id      = row_tenant
       AND g.revoked_at IS NULL
       AND now() >= g.valid_from
       AND (g.valid_to IS NULL OR now() < g.valid_to)
       -- 'audit' is implied by every grant. Access that cannot be recorded
       -- would be access without a trace, so it is not a permission an owner
       -- can accidentally withhold.
       AND (required_permission = 'audit' OR required_permission = ANY (g.permissions))
$$;

COMMENT ON FUNCTION current_active_grant(uuid, text) IS
    'ADR-0005. The declared grant, if it is genuinely this tenant''s live grant from row_tenant for this permission. Scope is checked separately.';

-- The one place a row belonging to another organisation becomes reachable, at
-- property granularity.
--
-- row_property NULL means "this row is not property-scoped" — an audit entry,
-- say. Passing NULL from a table that DOES have a property_id would widen the
-- grant to the grantor's whole portfolio, so the assertions at the foot of this
-- file fail any such table.
--
-- A unit scope satisfies a property-scoped row, because scope_property_id
-- resolves a unit to its property. That is a deliberate widening and ADR-0009 §4
-- argues it: a firm managing flat 1204 must be able to read the building the
-- flat is in. It is also why unit-bearing tables must use is_delegated_unit()
-- instead — at property granularity, one unit reaches all of them.
CREATE OR REPLACE FUNCTION is_delegated(row_tenant uuid, row_property uuid, required_permission text)
    RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT CASE
        WHEN row_property IS NULL
            THEN current_active_grant(row_tenant, required_permission) IS NOT NULL
        ELSE EXISTS (
            SELECT 1 FROM delegation_grant_scopes s
             WHERE s.grant_id = current_active_grant(row_tenant, required_permission)
               AND (s.scope_kind = 'portfolio' OR s.scope_property_id = row_property))
        END
$$;

COMMENT ON FUNCTION is_delegated(uuid, uuid, text) IS
    'ADR-0005. True when the declared grant genuinely covers this property for this permission, right now.';

-- The same question at unit granularity, which is what a two-of-five-units
-- mandate actually means. ADR-0009 §4.
--
-- Every argument comes from the row being judged; nothing is read from units.
-- That is not tidiness — the units policy calls this function, so a lookup of
-- units from inside it is a policy that consults the table it governs. Measured,
-- with a variant that resolved the property itself: "stack depth limit exceeded
-- ... CONTEXT: SQL function is_delegated_unit_reading during inlining". Not the
-- "infinite recursion detected in policy" PostgreSQL raises when a policy names
-- its own table directly — inlining a STABLE function gets there first, and the
-- message points at the function rather than at the policy that is the cause.
--
-- row_parent_unit is the ancillary hop: a parking slot allotted to flat 1204 is
-- reachable by a grant scoped to flat 1204, because the slot comes with the
-- flat. A table that carries a unit id but no parent passes NULL and loses the
-- hop, which fails closed — the row is simply unreachable, never over-reachable.
-- ADR-0021. Whether a row may be purged because it belongs to a demo sandbox.
--
-- Every no-delete policy in this file calls it, and the answer is almost always false.
-- The two conditions are both necessary and they hold each other up:
--
--   is_purge_session()     the cleanup job, never a request and not even the platform
--                          role. A tenant cannot delete their own history by claiming it
--                          is a demo, and an audited support session cannot either.
--   is_sandbox             the organisation is a sandbox, and ADR-0021 §3's side-effect
--                          ban is what makes that safe: nothing real can be in one, so
--                          nothing real is lost by dropping it.
--
-- Reverse the reasoning and it is the same decision: a sandbox is deletable *because*
-- nothing real may live in it, and nothing real may live in it *because* it is deletable.
-- Weakening either half breaks the other.
--
-- NULL tenant is false. ADR-0011's parked webhook and ADR-0012's unmatched settlement
-- line belong to no organisation, so they belong to no sandbox either, and a purge must
-- not reach them.
CREATE OR REPLACE FUNCTION is_purge_session() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT pg_has_role(current_user, 'dwellm8_purge', 'USAGE') $$;

COMMENT ON FUNCTION is_purge_session() IS
    'ADR-0021 §4. The demo cleanup job, and nothing else. A separate role from dwellm8_platform so every other session keeps both locks.';

CREATE OR REPLACE FUNCTION sandbox_purge_permitted(row_tenant uuid) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT row_tenant IS NOT NULL
       AND is_purge_session()
       AND EXISTS (SELECT 1 FROM organisations o WHERE o.id = row_tenant AND o.is_sandbox)
$$;

COMMENT ON FUNCTION sandbox_purge_permitted(uuid) IS
    'ADR-0021 §4. The one exception to append-only: a demo sandbox, purged by the platform. Safe only because §3 bars any real effect from originating in one.';

-- ADR-0021 §3. Whether an organisation is a sandbox, without the platform exemption —
-- for the triggers that ban side effects, which must be true for a tenant session too.
CREATE OR REPLACE FUNCTION is_sandbox_tenant(row_tenant uuid) RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT EXISTS (SELECT 1 FROM organisations o WHERE o.id = row_tenant AND o.is_sandbox)
$$;

CREATE OR REPLACE FUNCTION is_delegated_unit(
        row_tenant uuid, row_property uuid, row_unit uuid, row_parent_unit uuid,
        required_permission text)
    RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT EXISTS (
        SELECT 1 FROM delegation_grant_scopes s
         WHERE s.grant_id = current_active_grant(row_tenant, required_permission)
           AND (s.scope_kind = 'portfolio'
             OR (s.scope_kind = 'property' AND s.scope_id = row_property)
             OR (s.scope_kind = 'unit'     AND s.scope_id = row_unit)
             OR (s.scope_kind = 'unit'     AND s.scope_id = row_parent_unit)))
$$;

COMMENT ON FUNCTION is_delegated_unit(uuid, uuid, uuid, uuid, text) IS
    'ADR-0009. True when the declared grant covers this exact unit — or its parent, or its property, or the portfolio.';

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
    AS RESTRICTIVE FOR DELETE USING (sandbox_purge_permitted(tenant_id));

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
    AS RESTRICTIVE FOR DELETE USING (sandbox_purge_permitted(tenant_id));

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
-- property, block and unit
-- ===========================================================================

-- ADR-0009. One hierarchy for a standalone house, a four-flat building, a
-- 240-flat society tower, a shop and a parking slot:
--
--   property  → block (optional) → unit → ancillary unit (parking, storage)
--
-- tenant_id is whoever holds the tree. For a landlord's own flats that is the
-- owner's organisation; for a society it is the society, and an individual flat
-- owner is a separate organisation that reaches their flat through a grant the
-- society issues. Ownership is therefore not tenancy — see ADR-0009's
-- consequences, which say plainly what that costs.

CREATE TABLE IF NOT EXISTS properties (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    -- The owner-facing short code. citext so 'GK-2' and 'gk-2' collide rather
    -- than becoming two buildings.
    code            citext NOT NULL,
    name            text NOT NULL,
    kind            text NOT NULL CHECK (kind IN (
                        'standalone', 'building', 'society', 'commercial', 'coliving', 'plot')),

    -- Indian addressing. Two-line street address, then the administrative
    -- hierarchy that every statutory form asks for in this order.
    address_line1   text NOT NULL,
    address_line2   text,
    locality        text NOT NULL,
    city            text NOT NULL,
    district        text,
    -- ISO 3166-2:IN subdivision code. Named state_code, not state, because
    -- `state` is this file's word for a lifecycle — organisations.state, and the
    -- column below. The collision is unfortunate; the naming is the mitigation.
    state_code      char(2) NOT NULL CHECK (state_code IN (
                        'AN','AP','AR','AS','BR','CH','CT','DH','DL','GA','GJ','HP',
                        'HR','JH','JK','KA','KL','LA','LD','MH','ML','MN','MP','MZ',
                        'NL','OR','PB','PY','RJ','SK','TG','TN','TR','UP','UT','WB')),
    -- Indian PIN codes never start with zero, which makes a leading-zero PIN a
    -- transcription error rather than a valid code.
    pin             char(6) NOT NULL CHECK (pin ~ '^[1-9][0-9]{5}$'),
    latitude        numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    longitude       numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    -- Geocoding is an assertion about the world and can be wrong or stale, so
    -- it records where it came from rather than pretending to be a fact.
    geocoded_at     timestamptz,
    geocode_source  text CHECK (geocode_source IN ('manual', 'provider', 'import')),

    -- External identifiers. Every one of these is issued by somebody else, so
    -- none is unique here: two flats can share an electricity meter, and a
    -- municipal id can be reassigned after a subdivision.
    municipal_tax_id        text,
    rera_id                 text,
    society_registration_no text,

    state           text NOT NULL DEFAULT 'active'
                    CHECK (state IN ('active', 'inactive', 'disposed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT properties_code_unique UNIQUE (tenant_id, code),
    -- Redundant against the primary key, and load-bearing anyway: it is the
    -- target of the composite foreign keys below, which is how a block or a
    -- unit is prevented from attaching to another organisation's property.
    CONSTRAINT properties_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON COLUMN properties.state_code IS
    'ISO 3166-2:IN subdivision code — MH, KA, DL. The GST numeric code is a lookup, not this column (ADR-0007).';

CREATE INDEX IF NOT EXISTS properties_tenant_idx ON properties (tenant_id, state);
CREATE INDEX IF NOT EXISTS properties_pin_idx    ON properties (pin);

-- A wing, a tower, a phase. Optional: a standalone house has none, and forcing
-- a synthetic "Block A" onto it is the special-casing this model exists to
-- avoid.
CREATE TABLE IF NOT EXISTS blocks (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    property_id     uuid NOT NULL,
    code            citext NOT NULL,
    name            text,
    floors          int CHECK (floors > 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT blocks_code_unique     UNIQUE (property_id, code),
    CONSTRAINT blocks_tenant_id_unique UNIQUE (id, tenant_id),
    -- Composite, not a plain reference to properties(id): this is what makes
    -- tenant_id agree with the parent's. A plain foreign key would let a
    -- delegated session hang a block off another organisation's property and
    -- keep its own tenant_id on the row, which every policy in this file would
    -- then read as its own.
    CONSTRAINT blocks_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS blocks_property_idx ON blocks (property_id);

-- The unit. Everything downstream — a lease, a due, a ticket, a meter — points
-- here.
--
-- Parking and storage are units with a parent, not a second table. A slot
-- allotted to flat 1204 carries parent_unit_id = that flat; an unallotted slot
-- has none. Reassignment is an UPDATE, and the history of who parked where is
-- not modelled — ADR-0009 says so out loud rather than implying otherwise.
CREATE TABLE IF NOT EXISTS units (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    property_id     uuid NOT NULL,
    block_id        uuid,
    parent_unit_id  uuid,
    unit_kind       text NOT NULL CHECK (unit_kind IN (
                        'flat', 'floor', 'room', 'shop', 'office', 'desk', 'parking', 'storage')),
    -- '1204', 'P-31', 'Desk 7'. Unique within the property, which is the
    -- validation scenario in issue #10.
    code            citext NOT NULL,
    -- Signed: basements are floor -1, and a CHECK for > 0 here would be a bug
    -- reported from every tower with parking underneath it.
    floor           int,
    carpet_area_sqft  numeric(10,2) CHECK (carpet_area_sqft > 0),
    builtup_area_sqft numeric(10,2) CHECK (builtup_area_sqft > 0),
    -- The society's share certificate for this flat. Free text: the format is
    -- whatever the society's registrar used in 1987.
    share_certificate_no text,
    occupancy       text NOT NULL DEFAULT 'vacant' CHECK (occupancy IN (
                        'vacant', 'occupied', 'owner_occupied', 'locked', 'under_renovation')),
    electricity_consumer_no text,
    water_connection_no     text,
    state           text NOT NULL DEFAULT 'active'
                    CHECK (state IN ('active', 'inactive')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    -- Always false, and generated so that it cannot be set. It exists to be the
    -- second column of the foreign key below: referencing units(id,
    -- is_ancillary) with a column that is constantly false means the parent's
    -- is_ancillary must be false, so a parking slot cannot be parked on another
    -- parking slot. A trigger would do the same job and could be dropped
    -- without the schema noticing.
    parent_is_ancillary boolean NOT NULL GENERATED ALWAYS AS (false) STORED,
    is_ancillary        boolean NOT NULL GENERATED ALWAYS AS
                        (unit_kind IN ('parking', 'storage')) STORED,

    CONSTRAINT units_code_unique        UNIQUE (property_id, code),
    CONSTRAINT units_tenant_id_unique   UNIQUE (id, tenant_id),
    CONSTRAINT units_property_id_unique UNIQUE (id, property_id),
    CONSTRAINT units_ancillary_unique   UNIQUE (id, is_ancillary),

    CONSTRAINT units_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT units_block_fkey FOREIGN KEY (block_id, tenant_id)
        REFERENCES blocks (id, tenant_id),
    -- The parent lives in the same property...
    CONSTRAINT units_parent_fkey FOREIGN KEY (parent_unit_id, property_id)
        REFERENCES units (id, property_id),
    -- ...and is not itself an ancillary.
    CONSTRAINT units_parent_primary_fkey FOREIGN KEY (parent_unit_id, parent_is_ancillary)
        REFERENCES units (id, is_ancillary),

    CONSTRAINT units_no_self_parent CHECK (parent_unit_id <> id),
    -- Only an ancillary attaches to something. A flat with a parent would be a
    -- second hierarchy nobody downstream knows to walk.
    CONSTRAINT units_parent_only_ancillary CHECK (
        parent_unit_id IS NULL OR unit_kind IN ('parking', 'storage')),
    -- Built-up includes carpet by definition, so this ordering is arithmetic
    -- rather than policy. Dues computed from the wrong one are off by the walls.
    CONSTRAINT units_area_order CHECK (
        carpet_area_sqft IS NULL OR builtup_area_sqft IS NULL
        OR builtup_area_sqft >= carpet_area_sqft),
    -- A flat needs an area for area-based dues; a parking slot does not have
    -- one in any meaningful sense.
    CONSTRAINT units_lettable_has_area CHECK (
        unit_kind IN ('parking', 'storage') OR carpet_area_sqft IS NOT NULL)
);

COMMENT ON TABLE units IS
    'ADR-0009. Ancillaries (parking, storage) are units with parent_unit_id set, not a separate table.';
COMMENT ON COLUMN units.parent_is_ancillary IS
    'Constantly false. The second column of units_parent_primary_fkey, which is how a parent is required not to be an ancillary.';

CREATE INDEX IF NOT EXISTS units_property_idx ON units (property_id, unit_kind);
CREATE INDEX IF NOT EXISTS units_parent_idx   ON units (parent_unit_id) WHERE parent_unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS units_block_idx    ON units (block_id) WHERE block_id IS NOT NULL;

ALTER TABLE properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE properties FORCE  ROW LEVEL SECURITY;
ALTER TABLE blocks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocks     FORCE  ROW LEVEL SECURITY;
ALTER TABLE units      ENABLE ROW LEVEL SECURITY;
ALTER TABLE units      FORCE  ROW LEVEL SECURITY;

-- The first genuinely property-scoped policy. ADR-0005 §4's template, with the
-- property being this row itself.
--
-- The write branch has a consequence worth stating: for a portfolio-scoped
-- grant with property.write, is_delegated() is true for a property id that does
-- not exist yet, so a firm can create buildings inside the owner's tenant. That
-- is what onboarding a portfolio on an owner's behalf requires. A
-- property-scoped grant cannot, because a new id matches no scope row.
DROP POLICY IF EXISTS properties_tenant_isolation ON properties;
CREATE POLICY properties_tenant_isolation ON properties
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, id, 'property.write'));

DROP POLICY IF EXISTS blocks_tenant_isolation ON blocks;
CREATE POLICY blocks_tenant_isolation ON blocks
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.write'));

-- Unit granularity, not property granularity. is_delegated(tenant_id,
-- property_id, …) would satisfy assertion 5 and hand a firm holding one flat
-- every flat in the tower, which is precisely what ADR-0005's contract says a
-- grant must not do.
DROP POLICY IF EXISTS units_tenant_isolation ON units;
CREATE POLICY units_tenant_isolation ON units
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, id, parent_unit_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, id, parent_unit_id, 'property.write'));

-- The tree is the spine every ledger entry, lease and ticket hangs from. A
-- deleted unit orphans money; a deleted property orphans a grant scope that has
-- no foreign key to protect it. Correction is state = 'inactive'.
--
-- Two locks, as with the grants: the privilege is revoked further down, and this
-- refuses the statement even if some future migration hands it back. The table
-- owner (a DBA at a psql prompt) remains the deliberate escape hatch.
DROP POLICY IF EXISTS properties_no_delete ON properties;
CREATE POLICY properties_no_delete ON properties AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS blocks_no_delete ON blocks;
CREATE POLICY blocks_no_delete ON blocks AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS units_no_delete ON units;
CREATE POLICY units_no_delete ON units AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The reference ADR-0005 promised, as a trigger rather than a foreign key.
--
-- scope_id is polymorphic, so no single foreign key can constrain it — and the
-- check that matters is one a foreign key cannot express anyway: the target must
-- belong to the grantor. Otherwise an owner scopes a grant to a building they do
-- not own, and the firm reads it if it ever becomes theirs.
--
-- SECURITY INVOKER, so the lookup runs under the writer's own row-level
-- security. The grantor sees their own property and the scope is accepted;
-- anybody else sees nothing and gets the same refusal as a nonexistent id,
-- which is the correct answer to both questions.
CREATE OR REPLACE FUNCTION delegation_scope_target() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.scope_kind = 'portfolio' THEN
        NEW.scope_property_id := NULL;
        RETURN NEW;
    END IF;

    IF NEW.scope_kind = 'property' THEN
        IF NOT EXISTS (SELECT 1 FROM properties p
                        WHERE p.id = NEW.scope_id AND p.tenant_id = NEW.tenant_id) THEN
            RAISE EXCEPTION 'grant scope names property % which is not the grantor''s', NEW.scope_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        NEW.scope_property_id := NEW.scope_id;
        RETURN NEW;
    END IF;

    -- 'unit'. The containing property is stamped here so that is_delegated()
    -- never reads units from inside a policy.
    SELECT u.property_id INTO NEW.scope_property_id
      FROM units u
     WHERE u.id = NEW.scope_id AND u.tenant_id = NEW.tenant_id;
    IF NEW.scope_property_id IS NULL THEN
        RAISE EXCEPTION 'grant scope names unit % which is not the grantor''s', NEW.scope_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION delegation_scope_target() IS
    'ADR-0009 §4. Validates a grant scope against the grantor''s own tree and stamps scope_property_id.';

DROP TRIGGER IF EXISTS delegation_grant_scopes_target ON delegation_grant_scopes;
CREATE TRIGGER delegation_grant_scopes_target
    BEFORE INSERT OR UPDATE OF scope_kind, scope_id ON delegation_grant_scopes
    FOR EACH ROW EXECUTE FUNCTION delegation_scope_target();

-- The property module writes the tree; every other module reads it, because
-- every other module's rows point into it. Same reasoning as the grants tables:
-- is_delegated_unit() runs under the caller's privileges, and a role without
-- SELECT would turn a policy into an error instead of an empty result.
GRANT SELECT, INSERT, UPDATE ON properties, blocks, units TO dwellm8_property;
GRANT SELECT ON properties, blocks, units TO dwellm8_identity, dwellm8_lease,
    dwellm8_money, dwellm8_maintenance, dwellm8_community, dwellm8_discovery,
    dwellm8_notify;
GRANT EXECUTE ON FUNCTION current_active_grant(uuid, text) TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT EXECUTE ON FUNCTION is_delegated_unit(uuid, uuid, uuid, uuid, text) TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- ===========================================================================
-- ledger — chart of accounts and postings
-- ===========================================================================

-- ADR-0006. Every rupee this product touches is a posting against a fixed
-- chart of accounts. No service stores a balance; a balance is a sum.
--
--   ledger_accounts        the chart. One list, platform-wide, not per tenant.
--   posting_templates      which accounts each money event touches, and on
--   posting_template_lines which side. Data, so the rule is inspectable.
--   journal_entries        one money event. Immutable once written.
--   ledger_postings        its lines. Immutable, and must sum to zero.
--
-- The engine that applies a template is out of scope here (issue #7 says so):
-- this file lands the accounts, the shape, the immutability and the balance
-- rule. internal/money/domain in the API repository computes the amounts, and
-- the deferred constraint below is what stops it being believed.

-- The chart of accounts. Deliberately not tenant-scoped: a landlord with a
-- private idea of what "deposit_liability" means is a landlord whose statements
-- cannot be compared, consolidated or audited. Tenants get their own postings,
-- never their own accounts.
--
-- normal_side is generated rather than entered. An asset with a credit normal
-- balance is not a preference, it is a typo, and every report that assumes the
-- sign would be silently backwards.
CREATE TABLE IF NOT EXISTS ledger_accounts (
    code            text PRIMARY KEY,
    name            text NOT NULL,
    account_type    text NOT NULL CHECK (account_type IN ('asset', 'liability', 'income', 'expense')),
    normal_side     text NOT NULL GENERATED ALWAYS AS
                    (CASE WHEN account_type IN ('asset', 'expense') THEN 'debit' ELSE 'credit' END) STORED,
    -- Whose balance this account is kept per. A receivable is meaningless
    -- without the tenant it is owed by; rent_income is not per anybody.
    party_kind      text NOT NULL DEFAULT 'none'
                    CHECK (party_kind IN ('none', 'tenant', 'owner', 'vendor', 'platform', 'statutory')),
    description     text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE ledger_accounts IS
    'ADR-0006. The chart of accounts, platform-wide. Not tenant-scoped, so statements are comparable.';

-- The list from issue #7, plus tenant_advance — see ADR-0006 §2 for why the
-- issue's thirteen became fourteen. ON CONFLICT DO UPDATE so a correction to a
-- name or a description reaches an existing database on the next replay; the
-- code is the identity and never changes.
INSERT INTO ledger_accounts (code, name, account_type, party_kind, description) VALUES
  ('tenant_receivable',       'Tenant receivable',        'asset',     'tenant',
   'What a tenant owes: rent, late fees and recoveries invoiced but not yet paid'),
  ('tenant_advance',          'Tenant advance',           'liability', 'tenant',
   'Money held from a tenant against a charge that does not exist yet — rent paid early, or an overpayment'),
  ('rent_income',             'Rent income',              'income',    'owner',
   'Rent earned for a period, recognised when the charge is raised rather than when it is paid'),
  ('late_fee_income',         'Late fee income',          'income',    'owner',
   'Late payment charges earned under the lease'),
  ('deposit_liability',       'Security deposit held',    'liability', 'tenant',
   'A deposit is the tenant''s money held by the owner. It is never income and never a receipt'),
  ('owner_payable',           'Owner payable',            'liability', 'owner',
   'Collected money owed onward to the owner, net of fees and outgoings, until it is disbursed'),
  ('platform_fee_income',     'Platform fee income',      'income',    'platform',
   'Dwellm8''s own fee on a collection or a payout'),
  ('gst_output',              'GST payable',              'liability', 'statutory',
   'GST charged on a taxable supply and owed to the government until remitted'),
  ('tds_receivable',          'TDS receivable',           'asset',     'statutory',
   'Tax the payer deducted at source and paid to the government on the payee''s behalf — creditable, not lost'),
  ('gateway_clearing',        'Gateway clearing',         'asset',     'platform',
   'Money the provider has taken from the payer and not yet settled to a bank account'),
  ('gateway_fee',             'Gateway fee',              'expense',   'platform',
   'What an aggregator kept out of a settlement. An expense of ours, never a smaller collection: the payer paid the gross'),
  ('gst_input',               'GST input credit',         'asset',     'statutory',
   'GST charged to us on a fee, creditable against our own output liability. A receivable from the government, not a cost'),
  ('bank',                    'Bank',                     'asset',     'platform',
   'Settled money in a real bank account'),
  ('society_dues_receivable', 'Society dues receivable',  'asset',     'tenant',
   'Maintenance and other dues a society has raised against a member and not yet collected'),
  ('sinking_fund',            'Sinking fund',             'liability', 'none',
   'A society''s corpus, held for future capital works. Not income, and not spendable as income'),
  ('write_off',               'Write-off',                'expense',   'none',
   'A receivable a decision has abandoned. An expense with a reason, never a deleted invoice')
ON CONFLICT (code) DO UPDATE
   SET name = EXCLUDED.name,
       account_type = EXCLUDED.account_type,
       party_kind = EXCLUDED.party_kind,
       description = EXCLUDED.description;

-- What each money event posts. Data rather than code, so the rule is
-- inspectable in the database a dispute is being argued against — and so the Go
-- catalogue can be checked against it instead of being trusted.
--
-- Versioned by event kind: a posting rule that changes must not rewrite the rule
-- last year's entries were made under. Nothing selects a version yet; entries
-- record which one they used.
CREATE TABLE IF NOT EXISTS posting_templates (
    event_kind      text NOT NULL,
    version         int  NOT NULL DEFAULT 1 CHECK (version > 0),
    description     text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_kind, version)
);

-- amount_role names which of the event's amounts a line takes: 'gross' is what
-- changes hands, 'net' the part that is income, 'tax' the GST on it, 'tds' the
-- statutory deduction, 'principal' the part of a payment that settles a debt and
-- 'advance' the part that does not. The arithmetic that turns an event into
-- amounts lives in Go (ADR-0006 §4); this says where each result lands.
CREATE TABLE IF NOT EXISTS posting_template_lines (
    event_kind      text NOT NULL,
    version         int  NOT NULL,
    seq             int  NOT NULL,
    account_code    text NOT NULL REFERENCES ledger_accounts(code),
    side            text NOT NULL CHECK (side IN ('debit', 'credit')),
    amount_role     text NOT NULL CHECK (amount_role IN
                        ('gross', 'net', 'tax', 'tds', 'advance', 'principal', 'fee')),
    -- A line that only applies when its amount is non-zero: no GST line on an
    -- exempt supply, no TDS line when the tenant is an individual below the
    -- threshold. Absence is not the same as zero, and an entry full of zero
    -- postings is noise in every statement.
    optional        boolean NOT NULL DEFAULT false,
    PRIMARY KEY (event_kind, version, seq),
    FOREIGN KEY (event_kind, version) REFERENCES posting_templates (event_kind, version) ON DELETE CASCADE
);

-- Replace rather than merge: a template is a whole rule, and a leftover line
-- from a previous shape is a posting nobody intended. DELETE then INSERT inside
-- one transaction — these tables carry no tenant data and no row-level security,
-- so unlike the migrations section this can simply run.
DO $$
BEGIN
    INSERT INTO posting_templates (event_kind, version, description) VALUES
      ('invoice',            1, 'A charge is raised: the tenant owes it, and it is income now, not when it is paid'),
      ('late_fee',           1, 'A late payment charge under the lease'),
      ('payment',            1, 'The payer''s money reaches the provider, settling a receivable and possibly leaving an advance'),
      ('payment_with_tds',   1, 'A payer who deducts tax at source pays the net and the deduction is receivable from the government'),
      ('settlement',         1, 'The provider settles collected money to a real bank account'),
      ('settlement_with_fee', 1, 'The provider settles and keeps its charge: clearing is credited the gross, the bank is debited the net'),
      ('clearing_write_off', 1, 'A clearing balance reconciliation could not account for, abandoned by a decision'),
      ('deposit_collection', 1, 'A security deposit is collected. It is a liability from the moment it arrives'),
      ('deposit_refund',     1, 'A deposit is returned, in whole or in part'),
      ('payout',             1, 'Money owed to the owner leaves the bank account'),
      ('platform_fee',       1, 'Dwellm8''s fee is charged against what the owner is owed'),
      ('gst_remittance',     1, 'GST collected is paid to the government'),
      ('refund',             1, 'Money is returned to the payer'),
      ('write_off',          1, 'A receivable is abandoned, with a reason'),
      ('reversal',           1, 'Every line of an earlier entry, on the opposite side. The only correction there is')
    ON CONFLICT (event_kind, version) DO UPDATE SET description = EXCLUDED.description;

    DELETE FROM posting_template_lines WHERE version = 1;

    INSERT INTO posting_template_lines (event_kind, version, seq, account_code, side, amount_role, optional) VALUES
      -- A charge: owed in full, income net of the tax collected on behalf of the
      -- government. The tax line is optional because rent to a residential
      -- tenant is exempt, and a zero GST posting on every invoice in the country
      -- would be the commonest row in the table.
      ('invoice',            1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('invoice',            1, 2, 'rent_income',             'credit', 'net',     false),
      ('invoice',            1, 3, 'gst_output',              'credit', 'tax',     true),

      ('late_fee',           1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('late_fee',           1, 2, 'late_fee_income',         'credit', 'net',     false),

      -- Money in. It lands in clearing, not in the bank: the provider has it,
      -- and pretending otherwise is how a reconciliation stops closing.
      -- Anything beyond what was owed becomes an advance rather than a negative
      -- receivable.
      ('payment',            1, 1, 'gateway_clearing',        'debit',  'gross',   false),
      ('payment',            1, 2, 'tenant_receivable',       'credit', 'principal', true),
      ('payment',            1, 3, 'tenant_advance',          'credit', 'advance', true),

      ('payment_with_tds',   1, 1, 'gateway_clearing',        'debit',  'net',     false),
      ('payment_with_tds',   1, 2, 'tds_receivable',          'debit',  'tds',     false),
      ('payment_with_tds',   1, 3, 'tenant_receivable',       'credit', 'gross',   false),

      ('settlement',         1, 1, 'bank',                    'debit',  'gross',   false),
      ('settlement',         1, 2, 'gateway_clearing',        'credit', 'gross',   false),

      -- The same event when the provider kept its charge. Clearing is credited
      -- the gross, because the gross is what clearing was debited when the
      -- payment was captured. Netting the fee against it balances just as well
      -- and leaves a permanent residue in the one account reconciliation is
      -- measured against — ADR-0012 §4.
      ('settlement_with_fee', 1, 1, 'bank',                   'debit',  'net',     false),
      ('settlement_with_fee', 1, 2, 'gateway_fee',            'debit',  'fee',     false),
      ('settlement_with_fee', 1, 3, 'gst_input',              'debit',  'tax',     true),
      ('settlement_with_fee', 1, 4, 'gateway_clearing',       'credit', 'gross',   false),

      ('clearing_write_off', 1, 1, 'write_off',               'debit',  'gross',   false),
      ('clearing_write_off', 1, 2, 'gateway_clearing',        'credit', 'gross',   false),

      ('deposit_collection', 1, 1, 'gateway_clearing',        'debit',  'gross',   false),
      ('deposit_collection', 1, 2, 'deposit_liability',       'credit', 'gross',   false),

      ('deposit_refund',     1, 1, 'deposit_liability',       'debit',  'gross',   false),
      ('deposit_refund',     1, 2, 'bank',                    'credit', 'gross',   false),

      ('payout',             1, 1, 'owner_payable',           'debit',  'gross',   false),
      ('payout',             1, 2, 'bank',                    'credit', 'gross',   false),

      ('platform_fee',       1, 1, 'owner_payable',           'debit',  'gross',   false),
      ('platform_fee',       1, 2, 'platform_fee_income',     'credit', 'net',     false),
      ('platform_fee',       1, 3, 'gst_output',              'credit', 'tax',     true),

      ('gst_remittance',     1, 1, 'gst_output',              'debit',  'gross',   false),
      ('gst_remittance',     1, 2, 'bank',                    'credit', 'gross',   false),

      ('refund',             1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('refund',             1, 2, 'bank',                    'credit', 'gross',   false),

      ('write_off',          1, 1, 'write_off',               'debit',  'gross',   false),
      ('write_off',          1, 2, 'tenant_receivable',       'credit', 'gross',   false);

    -- 'reversal' has no lines on purpose: it is not a rule about accounts, it is
    -- the original entry with every side flipped. Giving it lines would invite
    -- somebody to change them.
END
$$;

-- One money event. What happened, when, and what caused it.
--
-- occurred_on is the accounting date — the day the event belongs to, which is
-- the day a statement puts it on. posted_at is when the row was written. They
-- differ for anything backdated, and a period close (issue #190) needs both.
CREATE TABLE IF NOT EXISTS journal_entries (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    entry_kind      text NOT NULL,
    template_version int NOT NULL DEFAULT 1,
    occurred_on     date NOT NULL,
    posted_at       timestamptz NOT NULL DEFAULT now(),
    -- ADR-0007 §1: one currency, and it is recorded rather than assumed. A
    -- second currency needs an FX rate with a date and a source, a rule for
    -- which currency a balance is stated in, and a per-currency minor unit —
    -- none of which has a caller. Storing the column anyway is what makes that
    -- a schema change later rather than a rewrite of every stored number.
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- What caused this entry: an invoice, a provider payment, a payout batch.
    source_kind     text NOT NULL,
    source_id       text NOT NULL,
    -- The caller's natural key for this event. A webhook delivered twice, a
    -- retried workflow activity and a double-clicked button all arrive with the
    -- same key and produce one entry. ADR-0002's idempotent consumers, spelled
    -- as a unique index rather than as a hope.
    idempotency_key text NOT NULL,

    -- A reversal names what it reverses and why. The original is never touched:
    -- the link lives on the correcting row, so an immutable table stays
    -- immutable. ADR-0006 §3.
    reverses_entry_id uuid REFERENCES journal_entries(id),
    -- Kept in step with domain.ReversalReasons() by the store contract test. Like
    -- journal_entries_kind, this clause only reaches a fresh database, so a new
    -- reason also needs the migration at the foot of this file.
    reversal_reason   text CHECK (reversal_reason IS NULL OR reversal_reason IN (
                        'duplicate', 'wrong_amount', 'wrong_account', 'wrong_party',
                        'wrong_period', 'provider_chargeback', 'operator_error',
                        'settlement_mismatch', 'workflow_compensated')),

    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    -- Who acted, when it was a firm acting under a delegation. Same shape as
    -- audit_events: the entry lands in the owner's tenant, stamped with the firm.
    actor_org_id    uuid REFERENCES organisations(id),
    grant_id        uuid REFERENCES delegation_grants(id),

    -- Kept in step with domain.EventKind by the store contract test. Note that
    -- this clause only reaches a fresh database: CREATE TABLE IF NOT EXISTS does
    -- not revisit the constraint of a table that already exists, so a new kind
    -- also needs the migration at the foot of this file. That is how
    -- 'settlement_with_fee' would otherwise have been refused in production while
    -- passing every test against a clean one.
    CONSTRAINT journal_entries_kind CHECK (entry_kind IN (
        'invoice', 'late_fee', 'payment', 'payment_with_tds', 'settlement',
        'settlement_with_fee', 'clearing_write_off',
        'deposit_collection', 'deposit_refund', 'payout', 'platform_fee',
        'gst_remittance', 'refund', 'write_off', 'reversal')),
    -- A reversal reverses something and says why; nothing else does either.
    CONSTRAINT journal_entries_reversal_shape CHECK (
        (entry_kind = 'reversal') = (reverses_entry_id IS NOT NULL)
        AND (entry_kind = 'reversal') = (reversal_reason IS NOT NULL)),
    CONSTRAINT journal_entries_no_self_reversal CHECK (reverses_entry_id <> id),
    CONSTRAINT journal_entries_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE journal_entries IS
    'ADR-0006. Immutable. A mistake is corrected by a reversing entry with a reason code, never by an update.';
COMMENT ON COLUMN journal_entries.occurred_on IS
    'The accounting date. posted_at is when the row was written; they differ for anything backdated.';

CREATE UNIQUE INDEX IF NOT EXISTS journal_entries_idempotency
    ON journal_entries (tenant_id, idempotency_key);
-- An entry is reversed once. A second reversal doubles the correction and nets
-- to the wrong side of the original, which is a defect that looks like activity.
CREATE UNIQUE INDEX IF NOT EXISTS journal_entries_one_reversal
    ON journal_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_entries_tenant_date_idx
    ON journal_entries (tenant_id, occurred_on DESC);
CREATE INDEX IF NOT EXISTS journal_entries_source_idx
    ON journal_entries (tenant_id, source_kind, source_id);

-- The lines. This is the only table in the product that holds an amount.
--
-- amount_minor is a positive integer of paise and the side carries the
-- direction, so there is no such thing as a negative posting: a refund is a
-- debit, not a credit of minus. signed_minor is the generated arithmetic every
-- balance sums, which keeps the sign convention in one place rather than in
-- every query that ever asks what a tenant owes.
CREATE TABLE IF NOT EXISTS ledger_postings (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id        uuid NOT NULL,
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    -- Money attributes to a place. NULL means the posting is the organisation's
    -- own — a GST remittance, a platform fee invoice — and a delegated session
    -- never sees those: see the policy below, which fails closed rather than
    -- widening to the portfolio.
    property_id     uuid,
    unit_id         uuid,
    -- Denormalised from units, stamped on insert. It is the ancillary hop from
    -- ADR-0009 §4: a firm holding flat 1204 must see the charge raised against
    -- the parking slot allotted to it. is_delegated_unit() takes the parent as
    -- an argument precisely so a policy never reads units.
    unit_parent_id  uuid,

    account_code    text NOT NULL REFERENCES ledger_accounts(code),
    side            text NOT NULL CHECK (side IN ('debit', 'credit')),
    amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    signed_minor    bigint NOT NULL GENERATED ALWAYS AS
                    (CASE WHEN side = 'debit' THEN amount_minor ELSE -amount_minor END) STORED,

    -- Whose balance this line moves. A receivable without a tenant cannot be
    -- chased and a payable without an owner cannot be paid.
    party_kind      text NOT NULL DEFAULT 'none'
                    CHECK (party_kind IN ('none', 'tenant', 'owner', 'vendor', 'platform', 'statutory')),
    party_id        uuid,
    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now(),

    -- Composite throughout, for ADR-0009 §3's reason: a plain reference would let
    -- a row carry one organisation's tenant_id and another's property.
    CONSTRAINT ledger_postings_entry_fkey FOREIGN KEY (entry_id, tenant_id)
        REFERENCES journal_entries (id, tenant_id),
    CONSTRAINT ledger_postings_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT ledger_postings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    -- ...and the unit is in that property, not merely in that organisation.
    CONSTRAINT ledger_postings_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT ledger_postings_unit_needs_property CHECK (unit_id IS NULL OR property_id IS NOT NULL),
    CONSTRAINT ledger_postings_party CHECK ((party_kind = 'none') = (party_id IS NULL))
);

COMMENT ON TABLE ledger_postings IS
    'ADR-0006. Immutable, positive amounts, direction in `side`. Every balance in the product is a sum over this table.';
COMMENT ON COLUMN ledger_postings.signed_minor IS
    'The sign convention, once: debits positive. Balances sum this rather than re-deriving it per query.';
COMMENT ON COLUMN ledger_postings.amount_minor IS
    'ADR-0007. Paise as a positive integer, never a decimal and never a float. Bounded at 2^53-1 so the value survives a JSON round trip exactly.';

-- ADR-0007 §5. The ceiling is 2^53-1 paise, not the bigint range.
--
-- Money leaves this database as a JSON number, and JSON numbers are float64 to
-- every browser; beyond 2^53 an amount stored correctly here arrives at the
-- client as a different number with no error anywhere in between. Go refuses
-- such an amount before writing it, and this refuses it again for anything that
-- did not come through Go — psql, a fixture, a future import job.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ledger_postings_amount_representable') THEN
        -- ADD CONSTRAINT IF NOT EXISTS does not exist, and a bare ADD
        -- CONSTRAINT fails the replay on the second run.
        ALTER TABLE ledger_postings ADD CONSTRAINT ledger_postings_amount_representable
            CHECK (amount_minor <= 9007199254740991);
    END IF;
END
$$;

-- The three questions asked of this table, in the order they are asked.
CREATE INDEX IF NOT EXISTS ledger_postings_entry_idx
    ON ledger_postings (entry_id);
-- "What does this party owe, or what are they owed" — the statement query.
CREATE INDEX IF NOT EXISTS ledger_postings_party_idx
    ON ledger_postings (tenant_id, account_code, party_kind, party_id);
-- "What has happened on this unit" — the unit ledger behind a lease screen.
CREATE INDEX IF NOT EXISTS ledger_postings_unit_idx
    ON ledger_postings (tenant_id, unit_id, account_code) WHERE unit_id IS NOT NULL;

-- Double entry, enforced at commit rather than at insert.
--
-- It has to be deferred: the postings of an entry are written one statement at a
-- time, and an entry is unbalanced between the first line and the last. A NOT
-- DEFERRABLE trigger would reject every entry ever written.
--
-- The consequence is worth stating because it surprised this implementation:
-- the violation surfaces from COMMIT, not from the INSERT that caused it. Code
-- that checks the error of each Exec and ignores the error of Commit will
-- believe an unbalanced entry was written. Measured: the INSERT reports success
-- and `tx.Commit` returns 'journal entry ... does not balance: debits 2500000,
-- credits 2000000'.
CREATE OR REPLACE FUNCTION ledger_entry_balances() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    debits  bigint;
    credits bigint;
    lines   int;
BEGIN
    SELECT coalesce(sum(amount_minor) FILTER (WHERE side = 'debit'), 0),
           coalesce(sum(amount_minor) FILTER (WHERE side = 'credit'), 0),
           count(*)
      INTO debits, credits, lines
      FROM ledger_postings
     WHERE entry_id = NEW.entry_id;

    -- Zero lines means the entry's postings were rolled back around this
    -- trigger, which is not this trigger's business.
    IF lines = 0 THEN
        RETURN NULL;
    END IF;
    IF lines < 2 THEN
        RAISE EXCEPTION 'journal entry % has % posting(s): an entry with one line is a balance nobody can explain',
            NEW.entry_id, lines USING ERRCODE = 'check_violation';
    END IF;
    IF debits <> credits THEN
        RAISE EXCEPTION 'journal entry % does not balance: debits %, credits %',
            NEW.entry_id, debits, credits USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION ledger_entry_balances() IS
    'ADR-0006 §3. Debits equal credits, per entry, checked at commit because an entry is unbalanced while it is being written.';

DROP TRIGGER IF EXISTS ledger_postings_balance ON ledger_postings;
CREATE CONSTRAINT TRIGGER ledger_postings_balance
    AFTER INSERT ON ledger_postings
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_balances();

-- The other half of the same rule, from the other end. The trigger above cannot
-- fire for an entry that has no postings at all, and an entry with no lines is a
-- money event that moved no money — a header in every statement and a total in
-- none.
CREATE OR REPLACE FUNCTION ledger_entry_has_postings() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ledger_postings WHERE entry_id = NEW.id) THEN
        RAISE EXCEPTION 'journal entry % has no postings: an entry that moves nothing is a header nobody can total',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS journal_entries_have_postings ON journal_entries;
CREATE CONSTRAINT TRIGGER journal_entries_have_postings
    AFTER INSERT ON journal_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_has_postings();

-- Stamp the ancillary parent, so the policy never reads units.
--
-- SECURITY INVOKER, like delegation_scope_target(): the lookup runs under the
-- writer's own row-level security. A writer who cannot see the unit gets a NULL
-- parent and loses the ancillary hop, which fails closed — the row is harder to
-- reach, never easier. SECURITY DEFINER would be worse than useless here: the
-- function's owner is the table owner, which FORCE row level security applies to
-- and which sets no app.tenant_id, so it would see nothing at all.
CREATE OR REPLACE FUNCTION ledger_posting_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.unit_id IS NULL THEN
        NEW.unit_parent_id := NULL;
        RETURN NEW;
    END IF;
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS ledger_postings_unit_parent ON ledger_postings;
CREATE TRIGGER ledger_postings_unit_parent
    BEFORE INSERT ON ledger_postings
    FOR EACH ROW EXECUTE FUNCTION ledger_posting_unit_parent();

-- Balances, derived. There is no stored "amount due" anywhere in this schema and
-- this view is why one is never needed.
--
-- security_invoker is load-bearing and is the reason this schema requires
-- PostgreSQL 15 or later. Without it a view executes with its owner's
-- privileges, so current_user inside the view is dwellm8 — every policy would be
-- evaluated for the wrong role, is_platform_session() would be false even for a
-- platform session, and the delegated branch would be judged against a role that
-- holds no grant. The view would not leak, it would silently under-report, which
-- is the harder failure to notice. Prod and CI are 16.
CREATE OR REPLACE VIEW ledger_balances
    WITH (security_invoker = true) AS
    SELECT p.tenant_id,
           p.property_id,
           p.unit_id,
           p.account_code,
           a.account_type,
           p.party_kind,
           p.party_id,
           p.currency,
           sum(p.signed_minor)                                    AS balance_minor,
           sum(p.amount_minor) FILTER (WHERE p.side = 'debit')    AS debit_minor,
           sum(p.amount_minor) FILTER (WHERE p.side = 'credit')   AS credit_minor,
           count(*)                                               AS posting_count,
           max(p.created_at)                                      AS last_posted_at
      FROM ledger_postings p
      JOIN ledger_accounts a ON a.code = p.account_code
     GROUP BY p.tenant_id, p.property_id, p.unit_id, p.account_code,
              a.account_type, p.party_kind, p.party_id, p.currency;

COMMENT ON VIEW ledger_balances IS
    'ADR-0006 §5. Every balance in the product, derived. security_invoker is required: without it the view runs as its owner and RLS is evaluated for the wrong role.';

ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries FORCE  ROW LEVEL SECURITY;
ALTER TABLE ledger_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_postings FORCE  ROW LEVEL SECURITY;

-- The entry header carries no property, so its delegated branch is grant-level:
-- a firm with money.read sees the entries of the owner that granted it. The
-- lines are where the scoping bites, and a firm that can see a header whose
-- lines are all invisible learns that something happened and nothing else.
DROP POLICY IF EXISTS journal_entries_tenant_isolation ON journal_entries;
CREATE POLICY journal_entries_tenant_isolation ON journal_entries
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, NULL, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (grant_id = current_grant_id()
               AND actor_org_id = current_tenant_id()
               AND is_delegated(tenant_id, NULL, 'money.collect')));

-- Unit granularity, and closed for a posting with no property.
--
-- property_id is nullable here — a GST remittance belongs to the organisation,
-- not to a building — and a NULL passed to is_delegated_unit() matches only a
-- portfolio scope, which would hand a firm the owner's statutory position. So
-- the delegated branch requires a property outright. A firm sees the money of
-- the units it manages and nothing about the organisation that owns them.
DROP POLICY IF EXISTS ledger_postings_tenant_isolation ON ledger_postings;
CREATE POLICY ledger_postings_tenant_isolation ON ledger_postings
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (property_id IS NOT NULL
               AND is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read')))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (property_id IS NOT NULL
               AND is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect')));

-- Immutability, as policy. The privileges are revoked further down as well:
-- an UPDATE that the privilege allows and the policy refuses is a bug report;
-- an UPDATE that both allow is a ledger nobody can trust.
--
-- RESTRICTIVE, so these AND with the policy above instead of ORing with it.
DROP POLICY IF EXISTS journal_entries_no_update ON journal_entries;
CREATE POLICY journal_entries_no_update ON journal_entries AS RESTRICTIVE FOR UPDATE USING (false);
DROP POLICY IF EXISTS journal_entries_no_delete ON journal_entries;
CREATE POLICY journal_entries_no_delete ON journal_entries AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS ledger_postings_no_update ON ledger_postings;
CREATE POLICY ledger_postings_no_update ON ledger_postings AS RESTRICTIVE FOR UPDATE USING (false);
DROP POLICY IF EXISTS ledger_postings_no_delete ON ledger_postings;
CREATE POLICY ledger_postings_no_delete ON ledger_postings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The chart and the templates are reference data: every module reads them,
-- nothing writes them at runtime, and they carry no tenant data — which is why
-- they have no row-level security and are named in the isolation harness's
-- exempt list with that reason.
GRANT SELECT ON ledger_accounts, posting_templates, posting_template_lines
    TO dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
       dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- Money writes the ledger. Everything else reads it, because a lease screen
-- shows a balance and a maintenance job shows what a repair cost.
GRANT SELECT, INSERT ON journal_entries, ledger_postings TO dwellm8_money;
GRANT SELECT ON journal_entries, ledger_postings TO dwellm8_identity, dwellm8_property,
    dwellm8_lease, dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT SELECT ON ledger_balances TO dwellm8_identity, dwellm8_property, dwellm8_lease,
    dwellm8_money, dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- ===========================================================================
-- statutory rules — rates, slabs and thresholds (ADR-0023)
-- ===========================================================================

-- Every statutory parameter this product computes with is a row here, effective
-- dated per ADR-0008 and scoped to a jurisdiction. Not a constant in a service:
-- GST rates move with a Council notification, TDS thresholds with a Budget, and
-- deposit caps with a state amendment, and a hardcoded one is wrong silently.
--
-- Reference data, like the chart of accounts above and for the same reasons: no
-- tenant_id, no row-level security, and no runtime writer. A tenant does not get
-- a private idea of the TDS rate, and a request cannot invent one — INSERT,
-- UPDATE and DELETE are revoked from dwellm8_app below, so this file is the only
-- author and a rate change is a reviewed commit.
--
-- The governance columns are the ones docs/india-property-compliance.md §1.1
-- specifies, and two of them interact: an unverified row may never carry
-- enforcement = 'block', because a cap enforced from a blog post is worse than no
-- cap — it is wrong with authority. That is a CHECK here rather than a review
-- rule.

CREATE TABLE IF NOT EXISTS statutory_rules (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- What kind of number this is. A bounded list, because a rule type nobody
    -- has written a resolver for is a rule nothing reads.
    rule_type     text NOT NULL CHECK (rule_type IN (
                      'gst_rate', 'gst_exemption_amount', 'gst_registration_threshold',
                      'tds_rate', 'tds_threshold',
                      -- Surcharge and cess sit above the section rate and only on a
                      -- payment to a non-resident, so the effective rate is not the
                      -- rate any table of sections shows. ADR-0025 §3.
                      'tds_surcharge_rate', 'tds_cess_rate',
                      'deposit_cap_months', 'advance_cap_months',
                      'stamp_duty_rate', 'stamp_duty_cap_amount',
                      'registration_fee_rate', 'registration_term_trigger_months')),

    -- 'IN' is the central rule, held once. A state code is that state's override.
    -- A national rule is not replicated per state: resolution falls back from the
    -- state to 'IN' and says which it used, so twenty-eight copies of the same
    -- number cannot drift apart.
    jurisdiction  text NOT NULL CHECK (jurisdiction ~ '^(IN|[A-Z]{2})$'),

    -- The discriminator within a type: the section for TDS, the supply for GST,
    -- the instrument for stamp duty. Lower case and dotted, so it reads the same
    -- in a query, a log line and a Go constant.
    rule_key      text NOT NULL CHECK (rule_key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)*$'),

    -- Which column carries the value. Four shapes rather than one polymorphic
    -- column: a rate and an amount are not interchangeable, and a schema that
    -- stores both as numeric is one cast away from charging 18 paise of GST.
    value_kind    text NOT NULL CHECK (value_kind IN ('rate', 'amount', 'count', 'slabs')),
    -- Basis points, per ADR-0007's argument about share_bps: 18% is 1800, and a
    -- percentage in floating point is a percentage that does not add up.
    rate_bps      int CHECK (rate_bps IS NULL OR (rate_bps >= 0 AND rate_bps <= 1000000)),
    amount_minor  bigint CHECK (amount_minor IS NULL OR
                      (amount_minor >= 0 AND amount_minor <= 9007199254740991)),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    -- A dimensionless count: months of deposit, months of term. Not money and not
    -- a rate, and conflating it with either is how a two-month cap becomes ₹2.
    count_value   int CHECK (count_value IS NULL OR count_value >= 0),

    -- ADR-0008: half-open, dates not timestamps, and the successor's valid_from
    -- is the predecessor's valid_to exactly.
    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    retired_at    timestamptz,
    corrects      uuid REFERENCES statutory_rules(id),

    -- Governance. india-property-compliance.md §1.1: an Act, section, notification
    -- or circular — a URL is not a citation, so the URL is a separate, nullable
    -- convenience.
    statute_ref   text NOT NULL CHECK (btrim(statute_ref) <> ''),
    source_url    text,
    verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN (
                      'verified', 'needs_bare_act_check', 'unverified', 'conflicting')),
    verified_by   text,
    verified_on   date,
    -- The team accountable for the row, and the date it must be looked at again.
    -- Both NOT NULL: a rule with no owner is a rule nobody reviews, and the review
    -- job below is the only thing standing between a Budget and a wrong invoice.
    owner         text NOT NULL CHECK (btrim(owner) <> ''),
    review_due    date NOT NULL,
    -- What the product does with the row. ADR-0023 §4.
    enforcement   text NOT NULL DEFAULT 'record_only'
                  CHECK (enforcement IN ('block', 'warn', 'record_only')),
    note          text,

    created_at    timestamptz NOT NULL DEFAULT now(),

    -- statutory_rules_value_shape and statutory_rules_unverified_cannot_block are
    -- not here: they are load-bearing, so they live in the migrations block at the
    -- foot of this file, which reaches a database that already has the table.
    --
    -- "Verified" names a human and a date, or it is a word somebody typed.
    CONSTRAINT statutory_rules_verification_shape CHECK (
        verification_status <> 'verified'
        OR (btrim(coalesce(verified_by, '')) <> '' AND verified_on IS NOT NULL)),
    CONSTRAINT statutory_rules_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT statutory_rules_correction_shape CHECK (corrects IS NULL OR corrects <> id),
    -- A row that is due for review before it takes effect is a row somebody
    -- back-dated and forgot.
    CONSTRAINT statutory_rules_review_after_effect CHECK (review_due >= valid_from)
);

COMMENT ON TABLE statutory_rules IS
    'ADR-0023. Statutory rates, slabs and thresholds, effective-dated and jurisdiction-scoped. Reference data: no tenant, no runtime writer, and a rate change is a new row.';
COMMENT ON COLUMN statutory_rules.jurisdiction IS
    'IN for the central rule, held once; a state code overrides it. Resolution falls back state → IN and records which it used.';
COMMENT ON COLUMN statutory_rules.enforcement IS
    'block | warn | record_only. An unverified row may never block: a cap enforced from a blog post is wrong with authority.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statutory_rules_no_overlap') THEN
        -- One rule in force at a time, per type per jurisdiction per key. This is
        -- what makes an as-of resolution single-valued, and it is a constraint
        -- rather than a trigger for ADR-0008's reason: a trigger reads the table it
        -- protects, so two people landing a Budget change concurrently would both
        -- pass.
        ALTER TABLE statutory_rules ADD CONSTRAINT statutory_rules_no_overlap
            EXCLUDE USING gist (rule_type WITH =, jurisdiction WITH =, rule_key WITH =,
                                validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

-- The seed's conflict target, and the reason a replay cannot silently change a
-- number: the natural key includes valid_from, so an amended rate is a new row or
-- it is nothing.
CREATE UNIQUE INDEX IF NOT EXISTS statutory_rules_natural_key
    ON statutory_rules (rule_type, jurisdiction, rule_key, valid_from)
    WHERE retired_at IS NULL;

-- The as-of query: type, jurisdiction, key, containing a date.
CREATE INDEX IF NOT EXISTS statutory_rules_asof_idx
    ON statutory_rules USING gist (rule_type, jurisdiction, rule_key, validity)
    WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS statutory_rules_review_idx
    ON statutory_rules (review_due) WHERE retired_at IS NULL;

-- A progressive scale: stamp duty by consideration, a fee capped at a ceiling.
-- A child table rather than JSON, so every money bound is a bigint of minor units
-- that assertion 8 can see, and so a band is addressable by a query.
CREATE TABLE IF NOT EXISTS statutory_rule_slabs (
    rule_id       uuid NOT NULL REFERENCES statutory_rules(id) ON DELETE CASCADE,
    seq           int  NOT NULL CHECK (seq >= 0),
    -- Half-open in the same sense as validity: [lower, upper), upper NULL meaning
    -- the top band. The same convention as dates, for the same reason — nobody
    -- computes "one paisa below the next band".
    lower_minor   bigint NOT NULL CHECK (lower_minor >= 0),
    upper_minor   bigint,
    rate_bps      int CHECK (rate_bps IS NULL OR (rate_bps >= 0 AND rate_bps <= 1000000)),
    flat_minor    bigint CHECK (flat_minor IS NULL OR flat_minor >= 0),
    PRIMARY KEY (rule_id, seq),
    CONSTRAINT statutory_rule_slabs_band CHECK (upper_minor IS NULL OR upper_minor > lower_minor),
    -- A band with neither a rate nor a flat amount charges nothing and reads like
    -- an exemption somebody meant to write.
    CONSTRAINT statutory_rule_slabs_has_a_value CHECK (rate_bps IS NOT NULL OR flat_minor IS NOT NULL)
);

COMMENT ON TABLE statutory_rule_slabs IS
    'ADR-0023 §3. The bands of a slabs-kind rule, half-open on [lower, upper) with a NULL upper for the top band.';

-- The shape of a slabs rule, checked at commit because the bands are written
-- after the header. Two failures, and the second is the one that would not be
-- noticed: a scale with a hole in it resolves to no band for an amount that falls
-- in the hole, months after somebody added a band and mistyped a bound.
CREATE OR REPLACE FUNCTION statutory_rule_slab_shape() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    bands int;
    prev  bigint;
    band  record;
BEGIN
    SELECT count(*) INTO bands FROM statutory_rule_slabs WHERE rule_id = NEW.id;

    IF NEW.value_kind <> 'slabs' THEN
        IF bands > 0 THEN
            RAISE EXCEPTION 'statutory rule % is a % and carries % slab band(s): only a slabs rule has bands',
                NEW.id, NEW.value_kind, bands USING ERRCODE = 'check_violation';
        END IF;
        RETURN NULL;
    END IF;

    IF bands = 0 THEN
        RAISE EXCEPTION 'statutory rule % is a slabs rule with no bands: it resolves to nothing for every amount',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;

    prev := 0;
    FOR band IN SELECT lower_minor, upper_minor FROM statutory_rule_slabs
                 WHERE rule_id = NEW.id ORDER BY lower_minor
    LOOP
        IF band.lower_minor <> prev THEN
            RAISE EXCEPTION 'statutory rule % has a gap or an overlap at %: the bands must cover [0, ) without one',
                NEW.id, band.lower_minor USING ERRCODE = 'check_violation';
        END IF;
        IF band.upper_minor IS NULL THEN
            prev := NULL;
            EXIT;
        END IF;
        prev := band.upper_minor;
    END LOOP;

    IF prev IS NOT NULL THEN
        RAISE EXCEPTION 'statutory rule % has no top band: an amount above % resolves to nothing',
            NEW.id, prev USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION statutory_rule_slab_shape() IS
    'ADR-0023 §3. A slabs rule covers [0, ) with no gap and a top band, checked at commit because the bands follow the header.';

DROP TRIGGER IF EXISTS statutory_rules_slabs_shape ON statutory_rules;
CREATE CONSTRAINT TRIGGER statutory_rules_slabs_shape
    AFTER INSERT OR UPDATE ON statutory_rules
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION statutory_rule_slab_shape();

-- What is due for review, derived. ADR-0023 §5: a stored "overdue" flag needs a
-- job to maintain it, and a rule that should be flagged and is not is exactly the
-- silence this whole table exists to break. Same argument as lease_expiring.
--
-- security_invoker, as assertion 10 requires of every view here.
CREATE OR REPLACE VIEW statutory_rules_review_due
    WITH (security_invoker = true) AS
    SELECT r.id,
           r.rule_type,
           r.jurisdiction,
           r.rule_key,
           r.owner,
           r.review_due,
           r.verification_status,
           r.enforcement,
           (current_date - r.review_due)     AS days_overdue,
           r.valid_from,
           r.valid_to,
           r.statute_ref
      FROM statutory_rules r
     WHERE r.retired_at IS NULL
       -- Only rules that still apply. A superseded row's review date is history.
       AND (r.valid_to IS NULL OR r.valid_to > current_date)
       AND r.review_due <= current_date + 30;

COMMENT ON VIEW statutory_rules_review_due IS
    'ADR-0023 §5. Live rules at or within 30 days of their review date, with days_overdue negative while the review is still ahead.';

-- The seed. Every row cites a statute, names an owner and carries a review date,
-- and none of them is authoritative until a practising CA has signed it off —
-- which is what verification_status says out loud.
--
-- ON CONFLICT updates the governance columns only. A replay may correct a
-- citation, an owner or a review date; it may never change a number, because a
-- number that changed is a new row with a new valid_from and a computation from
-- last March must still reproduce. A seeded value that is simply wrong is fixed
-- the way ADR-0008 fixes a wrong row: a correction that retires it.
INSERT INTO statutory_rules (
    rule_type, jurisdiction, rule_key, value_kind, rate_bps, amount_minor, count_value,
    valid_from, valid_to, statute_ref, verification_status, owner, review_due,
    enforcement, note) VALUES

  -- GST. The residential exemption and the reverse charge that narrowed it.
  ('gst_rate', 'IN', 'gst.residential_let_to_unregistered', 'rate', 0, NULL, NULL,
   DATE '2022-07-18', NULL,
   'Notification 12/2017-Central Tax (Rate), entry 12, as amended by 04/2022-CT(R)',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Renting a residential dwelling for use as a residence, to an unregistered person'),
  ('gst_rate', 'IN', 'gst.residential_let_to_registered_rcm', 'rate', 1800, NULL, NULL,
   DATE '2022-07-18', NULL,
   'Notification 05/2022-Central Tax (Rate), w.e.f. 18 July 2022',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Reverse charge on the registered recipient. The tax is the recipient''s to pay, which is why the document differs'),
  ('gst_rate', 'IN', 'gst.property_management_service_fee', 'rate', 1800, NULL, NULL,
   DATE '2017-07-01', NULL,
   'Notification 11/2017-Central Tax (Rate), SAC 9972',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Dwellm8''s own fee, and a managing agent''s'),
  ('gst_exemption_amount', 'IN', 'gst.rwa_maintenance_per_member_month', 'amount', NULL, 750000, NULL,
   DATE '2018-01-25', NULL,
   'Notification 12/2017-Central Tax (Rate), entry 77(c), as amended by 02/2018-CT(R)',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Per member per month. A member owning two flats is the classic implementation error — see india-compliance.md §4'),
  ('gst_registration_threshold', 'IN', 'gst.aggregate_turnover_services', 'amount', NULL, 200000000, NULL,
   DATE '2017-07-01', NULL,
   'Section 22, CGST Act 2017',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Twenty lakh of aggregate turnover in services'),
  -- And the special-category states, which is the case the jurisdiction column
  -- exists for: one central row, four overrides, no copies of the other twenty-four.
  ('gst_registration_threshold', 'MN', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'MZ', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'NL', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'TR', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),

  -- TDS. Two of these are pairs, and the pairs are the point: the old row stays
  -- exactly as it was, so a recomputation of an old deduction still reproduces.
  --
  -- There is no section 195 rate here and that absence is deliberate (ADR-0024 §5):
  -- the rate on a payment to a non-resident is the Act's or a treaty's, read with
  -- that landlord's tax residency certificate, and there is no single number to
  -- hold. The matrix still selects section 195 and still says the tenant carries it;
  -- what it will not do is compute a deduction against a number nobody chose.
  ('tds_rate', 'IN', 'tds.194i_land_and_building', 'rate', 1000, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-I(b), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'History before 1 April 2020 is not modelled: nothing in this product computes a period earlier than that'),
  ('tds_threshold', 'IN', 'tds.194i_annual', 'amount', NULL, 24000000, NULL,
   DATE '2020-04-01', DATE '2025-04-01',
   'Section 194-I proviso, Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Two lakh forty thousand a year, until the Finance Act 2025 raised it'),
  ('tds_threshold', 'IN', 'tds.194i_annual', 'amount', NULL, 60000000, NULL,
   DATE '2025-04-01', NULL,
   'Section 194-I proviso, as amended by the Finance Act 2025',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Six lakh a year, w.e.f. 1 April 2025'),
  ('tds_rate', 'IN', 'tds.194ib_individual_huf', 'rate', 500, NULL, NULL,
   DATE '2020-04-01', DATE '2024-10-01',
   'Section 194-IB(1), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Five per cent, until the Finance (No. 2) Act 2024 cut it'),
  ('tds_rate', 'IN', 'tds.194ib_individual_huf', 'rate', 200, NULL, NULL,
   DATE '2024-10-01', NULL,
   'Section 194-IB(1), as amended by the Finance (No. 2) Act 2024, w.e.f. 1 October 2024',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('tds_threshold', 'IN', 'tds.194ib_monthly', 'amount', NULL, 5000000, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IB(1), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Fifty thousand a month. Individual and HUF deductors not liable to tax audit'),
  -- The two statutory floors that raise a rate for something true of the payee
  -- rather than of the payment. ADR-0025 §2.
  --
  -- §206AB is the effective-dating case that could not be invented: it was
  -- inserted in 2021 and *omitted* by the Finance (No. 2) Act 2024 with effect
  -- from 1 October 2024. The row is bounded rather than deleted, so a deduction
  -- recomputed for August 2024 still sees the floor that applied to it.
  ('tds_rate', 'IN', 'tds.206aa_no_pan_floor', 'rate', 2000, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 206AA(1)(iii), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Twenty per cent, or the rate in force if higher. Rule 37BC exempts a non-resident who furnishes TRC, TIN and contact details'),
  ('tds_rate', 'IN', 'tds.206ab_non_filer_floor', 'rate', 500, NULL, NULL,
   DATE '2021-07-01', DATE '2024-10-01',
   'Section 206AB(1)(iii), Income-tax Act 1961, omitted by the Finance (No. 2) Act 2024 w.e.f. 1 October 2024',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Five per cent, or twice the rate in force if higher. The section no longer exists; the row is bounded so August 2024 still resolves it'),

  -- Surcharge and cess. Only on a payment to a non-resident: for a resident,
  -- TDS other than on salary is deducted at the section rate flat.
  ('tds_cess_rate', 'IN', 'tds.cess.health_and_education', 'rate', 400, NULL, NULL,
   DATE '2018-04-01', NULL,
   'Finance Act 2018, health and education cess at 4%',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'On tax plus surcharge, and only for a non-resident payee'),

  ('tds_rate', 'IN', 'tds.194ia_immovable_transfer', 'rate', 100, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IA, Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'record_only',
   'Sale consideration, not rent. Here because india-property-compliance.md §7 puts conveyancing in scope'),
  ('tds_threshold', 'IN', 'tds.194ia_consideration', 'amount', NULL, 500000000, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IA(2), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'record_only',
   'Fifty lakh'),

  -- Registration, and the deposit caps, which are the state-scoped case in full.
  ('registration_term_trigger_months', 'IN', 'registration.lease_term_trigger', 'count', NULL, NULL, 12,
   DATE '2020-04-01', NULL,
   'Section 17(1)(d), Registration Act 1908',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'A term of twelve months or more attracts compulsory registration. States vary — see e-stamping-by-state.md'),
  -- Deliberately no 'IN' row for the deposit cap. The Model Tenancy Act is a model
  -- adopted state by state, not central law, so a national row would assert a cap
  -- that binds nobody — and resolution failing loudly for an unlisted state is the
  -- correct answer, not a fallback to two months.
  ('deposit_cap_months', 'MH', 'deposit.residential', 'count', NULL, NULL, 2,
   DATE '2020-04-01', NULL,
   'Maharashtra Rent Control Act 1999, s.56',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('deposit_cap_months', 'MH', 'deposit.non_residential', 'count', NULL, NULL, 6,
   DATE '2020-04-01', NULL,
   'Maharashtra Rent Control Act 1999, s.56',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('deposit_cap_months', 'KA', 'deposit.residential', 'count', NULL, NULL, 10,
   DATE '2020-04-01', DATE '2026-01-01',
   'Karnataka Rent Act 2001',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Bengaluru''s ten months, lawful and normal in practice — see india-compliance.md §2'),
  ('deposit_cap_months', 'KA', 'deposit.residential', 'count', NULL, NULL, 2,
   DATE '2026-01-01', NULL,
   'Karnataka Rent (Amendment) Act 2025',
   'unverified', 'compliance', DATE '2026-10-31', 'record_only',
   'Secondary sources only. Unverified, so it may not block — the CHECK enforces that, not a review'),
  ('deposit_cap_months', 'TN', 'deposit.residential', 'count', NULL, NULL, 3,
   DATE '2020-04-01', NULL,
   'Tamil Nadu Regulation of Rights and Responsibilities of Landlords and Tenants Act 2017',
   'conflicting', 'compliance', DATE '2026-10-31', 'record_only',
   'Sources disagree between one month and three. Resolve against the bare act before this gates anything')

ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
DO UPDATE SET statute_ref = EXCLUDED.statute_ref,
              source_url = EXCLUDED.source_url,
              verification_status = EXCLUDED.verification_status,
              verified_by = EXCLUDED.verified_by,
              verified_on = EXCLUDED.verified_on,
              owner = EXCLUDED.owner,
              review_due = EXCLUDED.review_due,
              enforcement = EXCLUDED.enforcement,
              note = EXCLUDED.note;

-- The surcharge scales, which are the first slabs rules in the registry.
--
-- Written separately because the bands are children: the header goes in with
-- value_kind = 'slabs' and the deferred shape trigger checks at commit that the
-- bands cover [0, ) with a top band. The bottom band is nil — a surcharge scale
-- begins with a threshold below which there is no surcharge, and that band is a
-- zero rate rather than a missing row, so a payment under fifty lakh resolves to
-- "nil" instead of to nothing.
--
-- Two scales because the payee's own form decides them: a non-resident individual
-- and a foreign company are on different ladders. ADR-0025 §3.
DO $$
DECLARE
    individual uuid;
    company    uuid;
BEGIN
    INSERT INTO statutory_rules (
        rule_type, jurisdiction, rule_key, value_kind,
        valid_from, valid_to, statute_ref, verification_status, owner, review_due,
        enforcement, note) VALUES
      ('tds_surcharge_rate', 'IN', 'tds.surcharge.non_resident_individual', 'slabs',
       DATE '2023-04-01', NULL,
       'Finance Act, First Schedule, Part II — rates for deduction at source from a non-resident',
       'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
       'Whether the 37% band survives section 115BAC for a non-resident is exactly the kind of question this row may not answer for itself')
    ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
    DO UPDATE SET note = EXCLUDED.note
    RETURNING id INTO individual;

    INSERT INTO statutory_rules (
        rule_type, jurisdiction, rule_key, value_kind,
        valid_from, valid_to, statute_ref, verification_status, owner, review_due,
        enforcement, note) VALUES
      ('tds_surcharge_rate', 'IN', 'tds.surcharge.foreign_company', 'slabs',
       DATE '2023-04-01', NULL,
       'Finance Act, First Schedule, Part II — rates for deduction at source from a foreign company',
       'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL)
    ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
    DO UPDATE SET note = EXCLUDED.note
    RETURNING id INTO company;

    -- Fifty lakh, one crore, two crore, five crore, in paise.
    INSERT INTO statutory_rule_slabs (rule_id, seq, lower_minor, upper_minor, rate_bps) VALUES
      (individual, 0,          0,   500000000,    0),
      (individual, 1,  500000000,  1000000000, 1000),
      (individual, 2, 1000000000,  2000000000, 1500),
      (individual, 3, 2000000000,  5000000000, 2500),
      (individual, 4, 5000000000,        NULL, 3700),
      (company,    0,          0,  1000000000,    0),
      (company,    1, 1000000000, 10000000000,  200),
      (company,    2, 10000000000,       NULL,  500)
    ON CONFLICT (rule_id, seq) DO UPDATE
        SET lower_minor = EXCLUDED.lower_minor,
            upper_minor = EXCLUDED.upper_minor,
            rate_bps    = EXCLUDED.rate_bps;
END
$$;

-- Reference data, so every module reads it: the lease builder needs the deposit
-- cap, money needs the GST rate and the TDS threshold, and notify needs neither
-- but reads the review view.
GRANT SELECT ON statutory_rules, statutory_rule_slabs, statutory_rules_review_due
    TO dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
       dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- ===========================================================================
-- payments — the provider-facing side of collection (ADR-0011)
-- ===========================================================================

-- A payment is the canonical record of an attempt to collect money. It is not
-- the ledger: the ledger records what is true about the money, and this records
-- what a provider has been asked to do and what it has said back.
--
-- The two are joined by entry_id, and only when the payment reaches a state that
-- justifies a posting. Everything before that — an order created, an attempt
-- made, an authorisation held — is real and is not money yet.
CREATE TABLE IF NOT EXISTS payments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    -- Where the money is (ADR-0009). property_id is NOT NULL here, unlike
    -- ledger_postings: every collection is against something a tenant occupies,
    -- and there is no organisation-level collection the way there is an
    -- organisation-level GST remittance. That lets the delegated branch of the
    -- policy be unconditional.
    property_id     uuid NOT NULL,
    unit_id         uuid,
    unit_parent_id  uuid,

    payer_kind      text NOT NULL DEFAULT 'tenant' CHECK (payer_kind IN ('tenant', 'owner')),
    payer_id        uuid NOT NULL,

    amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The canonical method vocabulary. Offline is a first-class method, not an
    -- absence of one: when the provider is down the tenant still pays, and the
    -- alternative to recording it is a caretaker's notebook.
    method          text NOT NULL CHECK (method IN (
                        'upi_collect', 'upi_intent', 'upi_autopay',
                        'card', 'netbanking',
                        'offline_cash', 'offline_cheque', 'offline_transfer')),

    -- 'razorpay', or 'offline' for something recorded by a human. The adapter
    -- name, never a provider-specific column.
    provider        text NOT NULL,
    provider_order_id   text,
    provider_payment_id text,

    status          text NOT NULL DEFAULT 'created' CHECK (status IN (
                        'created', 'attempted', 'authorised', 'captured',
                        'settled', 'failed', 'expired', 'cancelled')),
    failure_code    text,

    -- ADR-0011 §2. The caller's key, unique per organisation. This index is the
    -- whole of the idempotency guarantee: three retries of the same request
    -- produce one row because the second and third lose a race against a unique
    -- constraint, not because a handler remembered to check.
    idempotency_key text NOT NULL,

    -- The ledger entry this payment caused, once it caused one. NULL until then.
    entry_id        uuid,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    authorised_at   timestamptz,
    captured_at     timestamptz,
    settled_at      timestamptz,

    CONSTRAINT payments_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT payments_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT payments_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT payments_entry_fkey FOREIGN KEY (entry_id, tenant_id)
        REFERENCES journal_entries (id, tenant_id),
    CONSTRAINT payments_amount_representable CHECK (amount_minor <= 9007199254740991),
    -- payments_captured_has_entry — a captured payment that posted nothing is money
    -- the ledger does not know about — is added in the "load-bearing rules" block
    -- below rather than here. Not a style choice: a CHECK in this position never
    -- reaches a database that already has the table, and this is one of the rules
    -- assertion 13 refuses to boot without.
    CONSTRAINT payments_amount_positive CHECK (amount_minor > 0)
);

COMMENT ON TABLE payments IS
    'ADR-0011. What a provider was asked to do and what it said back. The ledger is what is true about the money; this is not the ledger.';

CREATE UNIQUE INDEX IF NOT EXISTS payments_idempotency_idx
    ON payments (tenant_id, idempotency_key);
-- The provider's own id, once it has issued one. Unique across the provider so
-- a webhook naming a payment can find exactly one row, or none.
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_payment_idx
    ON payments (provider, provider_payment_id) WHERE provider_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_order_idx
    ON payments (provider, provider_order_id) WHERE provider_order_id IS NOT NULL;
-- "What is outstanding on this unit", and "what has not reached a terminal
-- state", which is the reconciliation sweep's question.
CREATE INDEX IF NOT EXISTS payments_unit_idx
    ON payments (tenant_id, unit_id, status) WHERE unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_open_idx
    ON payments (tenant_id, created_at)
    WHERE status IN ('created', 'attempted', 'authorised');

-- The transition table, ADR-0011 §3. The same set exists in Go, and the contract
-- test evaluates this function over every ordered pair of statuses and fails if
-- the two disagree — a state machine that exists twice is a state machine that
-- will differ once.
--
-- from = to is allowed and is the point: a webhook delivered five times applies
-- once and is a no-op four times, with no branch anywhere that has to count
-- deliveries.
CREATE OR REPLACE FUNCTION payment_transition_allowed(from_status text, to_status text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_status = to_status
        OR (from_status, to_status) IN (
            ('created',    'attempted'),
            ('created',    'failed'),
            ('created',    'expired'),
            ('created',    'cancelled'),
            ('attempted',  'authorised'),
            ('attempted',  'captured'),
            ('attempted',  'failed'),
            ('attempted',  'expired'),
            -- An authorisation that is never captured is released, not failed by
            -- the passage of time; both endings exist because the provider
            -- reports them differently and an owner asking "why did this not
            -- collect" needs the difference.
            ('authorised', 'captured'),
            ('authorised', 'failed'),
            ('authorised', 'cancelled'),
            ('captured',   'settled'))
$$;

COMMENT ON FUNCTION payment_transition_allowed(text, text) IS
    'ADR-0011 §3. The payment state machine. Terminal states absorb, and from = to is a permitted no-op so a redelivered webhook needs no special case.';

-- Enforced in the database, not only in Go, because the failure it prevents is
-- one that arrives out of order from outside the system: a `captured` webhook
-- delivered after the `settled` one that followed it. Application code that
-- writes the state it was told would walk the payment backwards and re-open a
-- collection that had already closed.
CREATE OR REPLACE FUNCTION payments_transition_is_forward() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT payment_transition_allowed(OLD.status, NEW.status) THEN
        RAISE EXCEPTION 'payment % cannot go from % to %: a delivery that arrived late, out of order, '
                        'or skipping a state does not move a payment',
            OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_forward_only ON payments;
CREATE TRIGGER payments_forward_only
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_transition_is_forward();

-- Stamp the ancillary parent, exactly as ledger_postings does, so the policy
-- never reads units. SECURITY INVOKER for the same fail-closed reason.
CREATE OR REPLACE FUNCTION payment_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.unit_id IS NULL THEN
        NEW.unit_parent_id := NULL;
        RETURN NEW;
    END IF;
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_unit_parent ON payments;
CREATE TRIGGER payments_unit_parent
    BEFORE INSERT OR UPDATE OF unit_id ON payments
    FOR EACH ROW EXECUTE FUNCTION payment_unit_parent();

-- The webhook inbox. ADR-0011 §4.
--
-- Every delivery lands here first and is decided afterwards. The unique index on
-- (provider, provider_event_id) is the deduplication — the fifth delivery of an
-- event conflicts and is discarded without the handler needing to be careful.
--
-- tenant_id is NULLABLE, which is deliberate and is the "unknown payment is
-- parked, not dropped" rule made structural. A webhook for a payment this system
-- has never heard of has no organisation to attribute it to, and the choices are
-- to guess, to drop it, or to keep it where only a platform session can see it.
-- Guessing is a cross-tenant write; dropping loses money that a provider
-- believes it has collected.
CREATE TABLE IF NOT EXISTS payment_events (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid REFERENCES organisations(id),
    provider           text NOT NULL,
    provider_event_id  text NOT NULL,
    event_type         text NOT NULL,

    -- Recorded, never assumed. An unverified delivery is still stored — it is
    -- evidence of something, possibly of an attack — and is never acted on.
    signature_verified boolean NOT NULL DEFAULT false,
    payload            jsonb NOT NULL,

    payment_id         uuid REFERENCES payments(id),
    park_reason        text CHECK (park_reason IN (
                           'unknown_payment', 'signature_invalid',
                           'stale_transition', 'unsupported_event')),

    received_at        timestamptz NOT NULL DEFAULT now(),
    processed_at       timestamptz,

    -- A parked event is one that was not applied, and an applied event is one
    -- that was not parked. Both being set means the handler did two things.
    CONSTRAINT payment_events_parked_or_processed CHECK (
        park_reason IS NULL OR processed_at IS NULL),
    -- Nothing unverified may ever be attributed to a payment.
    CONSTRAINT payment_events_unverified_is_parked CHECK (
        signature_verified OR payment_id IS NULL)
);

COMMENT ON TABLE payment_events IS
    'ADR-0011 §4. Every webhook delivery, deduplicated on the provider event id. Advisory: nothing here moves money on its own.';
COMMENT ON COLUMN payment_events.tenant_id IS
    'NULL for a webhook naming a payment this system does not know. Parked where only a platform session can see it, rather than guessed at or dropped.';

CREATE UNIQUE INDEX IF NOT EXISTS payment_events_provider_event_idx
    ON payment_events (provider, provider_event_id);
-- The reconciliation sweep's question: what arrived and was never applied.
CREATE INDEX IF NOT EXISTS payment_events_parked_idx
    ON payment_events (provider, received_at) WHERE park_reason IS NOT NULL;
CREATE INDEX IF NOT EXISTS payment_events_payment_idx
    ON payment_events (payment_id) WHERE payment_id IS NOT NULL;

ALTER TABLE payments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments       FORCE  ROW LEVEL SECURITY;
ALTER TABLE payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_events FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and as assertion 6 enforces. A firm
-- collecting rent on two flats must not see the collections of the tower.
DROP POLICY IF EXISTS payments_tenant_isolation ON payments;
CREATE POLICY payments_tenant_isolation ON payments
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect'));

-- A payment is mutable — it has a lifecycle, unlike a posting — but it may not
-- be deleted. A collection that was attempted and abandoned is the record an
-- owner asks about when a tenant says they paid.
DROP POLICY IF EXISTS payments_no_delete ON payments;
CREATE POLICY payments_no_delete ON payments AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The inbox is a platform-owned table, and the NULL tenant_id above is why: a
-- parked event belongs to no organisation, so no organisation's session can
-- reach it. Reading a verified, attributed event is allowed to the organisation
-- it concerns; writing is the platform's alone, because the webhook handler runs
-- before it knows whose money this is.
DROP POLICY IF EXISTS payment_events_tenant_isolation ON payment_events;
CREATE POLICY payment_events_tenant_isolation ON payment_events
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS payment_events_no_delete ON payment_events;
CREATE POLICY payment_events_no_delete ON payment_events AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON payments TO dwellm8_money;
GRANT SELECT ON payments TO dwellm8_lease, dwellm8_identity, dwellm8_property;
GRANT SELECT, INSERT, UPDATE ON payment_events TO dwellm8_money;

-- ===========================================================================
-- settlement reconciliation (ADR-0012)
-- ===========================================================================

-- Three accounts of the same money, and therefore three comparisons.
--
--   settlement_batches    what the provider says it paid onward, and its totals
--   settlement_lines      the rows of that file, matched or not
--   settlement_drift      every disagreement, in whichever direction it was found
--   reconciliation_runs   one provider-day, and whether it can honestly be
--                         called reconciled
--
-- All four are platform-owned, and none of them is tenant-scoped in the ordinary
-- ADR-0003 sense. A settlement batch is not tenant data: it is one payout from
-- one aggregator account, spanning every organisation that collected that day. It
-- *resolves into* tenant data, one matched line at a time, and until a line is
-- matched it belongs to nobody at all.
--
-- ADR-0011 §5 introduced that exception for the webhook inbox as a one-off. Three
-- more tables of the same shape make it a pattern, and a pattern needs a guard:
-- assertion 12 at the foot of this file requires every table whose rows may
-- belong to no organisation to be writable only by a platform session.

CREATE TABLE IF NOT EXISTS settlement_batches (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider          text NOT NULL,
    provider_batch_id text NOT NULL,

    -- The bank reference the provider says it paid under. Not decorative: it is
    -- the only handle that connects this batch to a line on a bank statement, and
    -- a batch without one can be reconciled against our own records but never
    -- against the bank's.
    utr               text,
    settled_on        date NOT NULL,
    currency          char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The provider's own totals. Checked against each other below before any
    -- line of the file is believed.
    gross_minor       bigint NOT NULL CHECK (gross_minor  >= 0),
    refund_minor      bigint NOT NULL DEFAULT 0 CHECK (refund_minor >= 0),
    fee_minor         bigint NOT NULL DEFAULT 0 CHECK (fee_minor    >= 0),
    tax_minor         bigint NOT NULL DEFAULT 0 CHECK (tax_minor    >= 0),
    net_minor         bigint NOT NULL CHECK (net_minor    >= 0),

    ingested_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT settlement_batches_amount_representable CHECK (
        gross_minor <= 9007199254740991),
    -- The first thing checked and the thing that stops everything if it fails. A
    -- file we parsed wrong — a column misread, rupees where paise were expected —
    -- fails here at ingestion rather than as five hundred inexplicable drift rows
    -- tomorrow. Stated in the database as well as in Go, because the failure it
    -- prevents is one where our own numbers are the ones that are wrong, and a
    -- guard that only exists in the code that got it wrong is not a guard.
    CONSTRAINT settlement_batches_currency_known CHECK (currency = 'INR')
);
-- settlement_batches_adds_up is in the "load-bearing rules" block below.

COMMENT ON TABLE settlement_batches IS
    'ADR-0012. One payout from one aggregator account. Platform-owned: a batch spans every organisation that collected that day.';

-- The deduplication. Re-ingesting the same file must be a no-op, and it is the
-- normal case: a retried job, a manually re-run day, a provider re-publishing a
-- corrected file under the same id.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_batches_provider_idx
    ON settlement_batches (provider, provider_batch_id);
CREATE INDEX IF NOT EXISTS settlement_batches_day_idx
    ON settlement_batches (provider, settled_on);

CREATE TABLE IF NOT EXISTS settlement_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            uuid NOT NULL REFERENCES settlement_batches(id),

    -- NULL until this line is matched to a payment, and that is the point. A line
    -- naming a payment this system never issued has no organisation to attribute
    -- it to; guessing one is a cross-tenant write and dropping the line loses
    -- money a provider believes it moved. ADR-0011 §5, second occurrence.
    tenant_id           uuid REFERENCES organisations(id),

    provider            text NOT NULL,
    -- The provider's own id for the row. A provider that supplies none forces the
    -- adapter to synthesise a stable one: without it a re-ingested file doubles
    -- every amount in it.
    provider_line_id    text NOT NULL,
    provider_payment_id text,

    line_kind           text NOT NULL CHECK (line_kind IN (
                            'payment', 'refund', 'chargeback', 'fee', 'adjustment')),
    direction           text NOT NULL CHECK (direction IN ('inward', 'outward')),

    -- The line's gross — what the payer paid, not what reached the bank. Matching
    -- is against the gross because the gross is what clearing is carrying.
    amount_minor        bigint NOT NULL CHECK (amount_minor > 0),
    fee_minor           bigint NOT NULL DEFAULT 0 CHECK (fee_minor >= 0),
    tax_minor           bigint NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),

    payment_id          uuid REFERENCES payments(id),
    match_class         text CHECK (match_class IN (
                            'exact', 'fee_adjusted', 'partial',
                            'unknown_payment', 'duplicate', 'amount_drift')),
    -- Orthogonal to the class, and deliberately not a class of its own: a line
    -- can be both late and fee-adjusted, and a design where lateness is a class
    -- has to discard one of them. ADR-0012 §5.
    late                boolean NOT NULL DEFAULT false,

    -- The settlement entry this line caused, once it caused one.
    entry_id            uuid,

    settled_on          date NOT NULL,
    matched_at          timestamptz,

    CONSTRAINT settlement_lines_amount_representable CHECK (
        amount_minor <= 9007199254740991),
    -- A provider that kept the whole collection is a parsing error, not a
    -- settlement.
    CONSTRAINT settlement_lines_keeps_less_than_it_settles CHECK (
        fee_minor + tax_minor < amount_minor),
    -- A payment line says which payment. An adjustment against a payment is a fee
    -- or a refund under the wrong label, and treating it as an adjustment loses
    -- the payment it concerns.
    CONSTRAINT settlement_lines_names_its_payment CHECK (
        (line_kind = 'payment') <= (provider_payment_id IS NOT NULL)
        AND NOT (line_kind = 'adjustment' AND provider_payment_id IS NOT NULL)),
    -- A refund, a chargeback and a fee are always money leaving; only an
    -- adjustment may go either way. A refund that claims to be inward would
    -- inflate a settlement, and the file that says so is one we misread.
    CONSTRAINT settlement_lines_direction_matches_kind CHECK (
        line_kind = 'adjustment'
        OR (line_kind = 'payment') = (direction = 'inward')),
    -- Attribution and a match arrive together or not at all. A line with a
    -- payment and no organisation is invisible to the organisation whose money it
    -- is; one with an organisation and no payment is an attribution nothing
    -- supports.
    CONSTRAINT settlement_lines_attribution_shape CHECK (
        (payment_id IS NULL) = (tenant_id IS NULL)),
    -- settlement_lines_only_matched_lines_post is in the "load-bearing rules" block
    -- below: ADR-0012 §5's half of "two classes may post and four may not".
    CONSTRAINT settlement_lines_settled_on_known CHECK (settled_on IS NOT NULL)
);

COMMENT ON TABLE settlement_lines IS
    'ADR-0012. One row of a settlement file. tenant_id is NULL until the line is matched: an unmatched line belongs to no organisation.';
COMMENT ON COLUMN settlement_lines.tenant_id IS
    'NULL for a line naming a payment this system does not have. Kept where only a platform session can see it, rather than guessed at or dropped.';

-- Re-ingesting a file is a no-op because of this index, not because a handler
-- checked first. Same argument as ADR-0011 §2.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_lines_provider_line_idx
    ON settlement_lines (provider, provider_line_id);
-- "Has this payment been settled before" — the cross-run duplicate check, which
-- is the only way a genuine double settlement can be found: a re-sent file is
-- deduplicated by line id, and a provider settling the same payment twice sends
-- two different line ids.
CREATE INDEX IF NOT EXISTS settlement_lines_provider_payment_idx
    ON settlement_lines (provider, provider_payment_id)
    WHERE provider_payment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS settlement_lines_batch_idx
    ON settlement_lines (batch_id, line_kind);
-- The sweep's question: which lines have not been classified at all.
CREATE INDEX IF NOT EXISTS settlement_lines_unmatched_idx
    ON settlement_lines (provider, settled_on) WHERE match_class IS NULL;

-- Every disagreement, in whichever direction it was found.
--
-- kind names which pair of accounts disagreed, because the fix is different for
-- each and one 'unreconciled' bucket loses that. missing_settlement is the
-- direction with no row in it — a payment captured here that no file has ever
-- mentioned — and it is the reason this table is written by a job with a clock
-- rather than derived from the file.
CREATE TABLE IF NOT EXISTS settlement_drift (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- NULL for a line naming a payment this system does not have, and for the
    -- clearing-balance check, which is platform-wide by nature.
    tenant_id           uuid REFERENCES organisations(id),
    provider            text NOT NULL,
    as_of_date          date NOT NULL,

    drift_kind          text NOT NULL CHECK (drift_kind IN (
                            'missing_settlement', 'unknown_line', 'amount_mismatch',
                            'duplicate_settlement', 'late_settlement', 'clearing_balance')),

    payment_id          uuid REFERENCES payments(id),
    line_id             uuid REFERENCES settlement_lines(id),
    provider_payment_id text,

    amount_minor        bigint NOT NULL CHECK (amount_minor > 0),
    -- When the money became wrong. The age is now() - this, and the bucket is
    -- derived from the age by the view below — never stored. A stored bucket is
    -- wrong the day after it is written, and the whole value of an ageing report
    -- is that yesterday's three-day-old item is four days old today.
    since               timestamptz NOT NULL,

    state               text NOT NULL DEFAULT 'open'
                        CHECK (state IN ('open', 'resolved', 'written_off')),
    -- The manual resolution workflow's audit trail. A resolution with no note and
    -- no actor is a row somebody closed, which is not the same as a row somebody
    -- explained.
    resolution_note     text,
    resolved_by         uuid,
    resolved_at         timestamptz,
    -- A write-off is money abandoned, so it posts. Same shape and same reason as
    -- payments_captured_has_entry: a clearing balance written off with no entry is
    -- a loss the ledger does not know about.
    entry_id            uuid,

    detected_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT settlement_drift_amount_representable CHECK (
        amount_minor <= 9007199254740991),
    CONSTRAINT settlement_drift_resolution_shape CHECK (
        (state = 'open') = (resolved_at IS NULL)
        AND (state = 'open') = (resolved_by IS NULL)
        AND (state = 'open') = (resolution_note IS NULL)),
    CONSTRAINT settlement_drift_write_off_posts CHECK (
        state <> 'written_off' OR entry_id IS NOT NULL),
    -- Late is not resolvable and must not sit in somebody's queue: the money
    -- arrived, and the row exists so the ageing report can show it was slow.
    CONSTRAINT settlement_drift_late_is_not_a_task CHECK (
        drift_kind <> 'late_settlement' OR state = 'open')
);

COMMENT ON TABLE settlement_drift IS
    'ADR-0012. Every way the three accounts of the money disagreed. Platform-owned: resolution spans organisations, because the clearing account does.';

-- One row per thing that is wrong, per run, and not five. A payment missing for
-- nine consecutive nights is one drift row that ages, not nine.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_drift_open_payment_idx
    ON settlement_drift (provider, drift_kind, payment_id)
    WHERE state = 'open' AND payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS settlement_drift_open_line_idx
    ON settlement_drift (provider, drift_kind, line_id)
    WHERE state = 'open' AND line_id IS NOT NULL;
-- The ageing report, and the reconciled-is-earned trigger below.
CREATE INDEX IF NOT EXISTS settlement_drift_open_idx
    ON settlement_drift (provider, as_of_date, drift_kind) WHERE state = 'open';
CREATE INDEX IF NOT EXISTS settlement_drift_tenant_idx
    ON settlement_drift (tenant_id, state) WHERE tenant_id IS NOT NULL;

-- The ageing boundaries, as a function rather than as a CASE inside the view.
--
-- It is a function for the reason payment_transition_allowed() is: the rule exists
-- in Go as well, and a rule that exists twice needs a seam a test can evaluate.
-- Inline in the view, the only thing a contract test can compare is the view's
-- text — which catches a boundary that moved and cannot catch a boundary that was
-- rewritten to mean something different. Measured: with the boundaries inline, a
-- planted 3-day-to-2-day change was caught by a string search for '3 days' and not
-- by any comparison of what the two copies actually do.
--
-- Boundaries are compared as intervals, not as truncated days, and that asymmetry
-- is where Go and this disagreed first: an item three days and twenty-three hours
-- old is inside '3 days' by neither measure, but int(hours/24) said it was.
CREATE OR REPLACE FUNCTION settlement_age_bucket(age interval)
    RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT CASE
               WHEN age <  interval '1 day'   THEN 'same_day'
               WHEN age <= interval '3 days'  THEN '1_3_days'
               WHEN age <= interval '7 days'  THEN '4_7_days'
               WHEN age <= interval '30 days' THEN '8_30_days'
               ELSE 'over_30_days'
           END
$$;

COMMENT ON FUNCTION settlement_age_bucket(interval) IS
    'ADR-0012 §7. The ageing boundaries. Also in Go; the store contract test evaluates this function over a table of ages and fails on any disagreement.';

-- The ageing report. Derived, like every other balance in this schema.
--
-- security_invoker is as load-bearing here as it is on ledger_balances, and
-- assertion 10 no longer names either view: it now requires it of every view in
-- the schema, because a guard that covers the views its author had in mind decays
-- with the next one.
CREATE OR REPLACE VIEW settlement_drift_ageing
    WITH (security_invoker = true) AS
    SELECT d.provider,
           d.tenant_id,
           d.drift_kind,
           d.state,
           settlement_age_bucket(now() - d.since)  AS age_bucket,
           count(*)                                AS item_count,
           sum(d.amount_minor)                     AS amount_minor,
           min(d.since)                            AS oldest_since
      FROM settlement_drift d
     GROUP BY d.provider, d.tenant_id, d.drift_kind, d.state, 5;

COMMENT ON VIEW settlement_drift_ageing IS
    'ADR-0012 §7. Open drift by age. The bucket is derived from now(), never stored: a stored bucket is wrong the day after it is written.';

-- One provider-day, and whether it can honestly be called reconciled.
CREATE TABLE IF NOT EXISTS reconciliation_runs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider          text NOT NULL,
    as_of_date        date NOT NULL,

    -- 'reconciled' does not mean everything matched — a day with three missing
    -- payments still ran, and 'drift' is a finished state, not a failed one. What
    -- must never be reachable is 'reconciled' for a day whose file never arrived,
    -- because a comparison over no lines looks perfectly clean. ADR-0012 §8.
    state             text NOT NULL DEFAULT 'running' CHECK (state IN (
                          'running', 'reconciled', 'drift', 'incomplete', 'failed')),
    file_present      boolean NOT NULL DEFAULT false,

    lines_read        int NOT NULL DEFAULT 0 CHECK (lines_read >= 0),
    lines_matched     int NOT NULL DEFAULT 0 CHECK (lines_matched >= 0),
    settled_minor     bigint NOT NULL DEFAULT 0 CHECK (settled_minor >= 0),

    -- Recomputed by the trigger below from settlement_drift, never taken from the
    -- writer. A job that reports zero unresolved items while three drift rows are
    -- open is exactly the failure this table exists to prevent, and asking the job
    -- nicely is not a mechanism.
    unresolved_count  int NOT NULL DEFAULT 0 CHECK (unresolved_count >= 0),
    unresolved_minor  bigint NOT NULL DEFAULT 0 CHECK (unresolved_minor >= 0),

    started_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    completed_at      timestamptz,
    failure_reason    text,

    CONSTRAINT reconciliation_runs_completion_shape CHECK (
        (state IN ('running')) = (completed_at IS NULL)),
    -- reconciliation_runs_reconciled_saw_the_file is in the "load-bearing rules"
    -- block below: a day whose file never arrived is not reconciled, however clean
    -- the comparison over nothing looked.
    CONSTRAINT reconciliation_runs_dates_known CHECK (as_of_date IS NOT NULL)
);

COMMENT ON TABLE reconciliation_runs IS
    'ADR-0012 §8. One provider-day. `reconciled` is earned by a trigger, not claimed by the job.';

-- One run per provider-day. Re-running a day updates it, so a day cannot end up
-- with a reconciled row and an incomplete one and no way to tell which is current.
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_runs_day_idx
    ON reconciliation_runs (provider, as_of_date);
-- The watchdog's question: which days have not reached an ending. Including
-- 'running', because a run that died leaves one and it must be indistinguishable
-- from a day that never ran.
CREATE INDEX IF NOT EXISTS reconciliation_runs_open_idx
    ON reconciliation_runs (provider, as_of_date)
    WHERE state IN ('running', 'incomplete', 'failed');

-- The counters are computed here, not accepted from the caller, and 'reconciled'
-- is refused while anything is open.
--
-- This is the acceptance criterion made structural. The job that reconciles a day
-- is the same job that would report it clean, so its own report is not evidence.
-- What is evidence is the drift table, and the database is what reads it.
--
-- late_settlement is excluded: the money arrived, and a day whose only fault was
-- slowness is reconciled.
CREATE OR REPLACE FUNCTION reconciliation_run_counters() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    open_count int;
    open_minor bigint;
BEGIN
    SELECT count(*), coalesce(sum(amount_minor), 0)
      INTO open_count, open_minor
      FROM settlement_drift d
     WHERE d.provider = NEW.provider
       AND d.as_of_date <= NEW.as_of_date
       AND d.state = 'open'
       AND d.drift_kind <> 'late_settlement';

    NEW.unresolved_count := open_count;
    NEW.unresolved_minor := open_minor;
    NEW.updated_at := now();

    IF NEW.state = 'reconciled' AND open_count > 0 THEN
        RAISE EXCEPTION 'reconciliation of % for % cannot be called reconciled: % open drift item(s) '
                        'worth % remain — a day that quietly becomes reconciled because nobody looked '
                        'is how money goes missing',
            NEW.provider, NEW.as_of_date, open_count, open_minor
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION reconciliation_run_counters() IS
    'ADR-0012 §8. The run''s unresolved counters are computed from settlement_drift, and `reconciled` is refused while anything is open.';

DROP TRIGGER IF EXISTS reconciliation_runs_counters ON reconciliation_runs;
CREATE TRIGGER reconciliation_runs_counters
    BEFORE INSERT OR UPDATE ON reconciliation_runs
    FOR EACH ROW EXECUTE FUNCTION reconciliation_run_counters();

ALTER TABLE settlement_batches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_batches   FORCE  ROW LEVEL SECURITY;
ALTER TABLE settlement_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_lines     FORCE  ROW LEVEL SECURITY;
ALTER TABLE settlement_drift     ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_drift     FORCE  ROW LEVEL SECURITY;
ALTER TABLE reconciliation_runs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_runs  FORCE  ROW LEVEL SECURITY;

-- A batch is one payout from one aggregator account and its totals are every
-- organisation's collections added together. There is no version of it that
-- belongs to a tenant, so no tenant sees it — not even the one whose money is in
-- it. What an owner is shown is their own payments and their own drift.
DROP POLICY IF EXISTS settlement_batches_platform_only ON settlement_batches;
CREATE POLICY settlement_batches_platform_only ON settlement_batches
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Read what is yours once it has been attributed; write nothing. Ingestion runs
-- before it knows whose money a line is, so it cannot run in a tenant-scoped
-- session — the same consequence ADR-0011 §5 recorded for the webhook inbox, and
-- for the same reason.
DROP POLICY IF EXISTS settlement_lines_tenant_isolation ON settlement_lines;
CREATE POLICY settlement_lines_tenant_isolation ON settlement_lines
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

-- Drift is read by the organisation it concerns — an owner asking where their
-- rent is has a right to the answer — and resolved only by the platform. The
-- clearing account spans organisations, so a resolution decided inside one of
-- them would be a decision about somebody else's money.
DROP POLICY IF EXISTS settlement_drift_tenant_isolation ON settlement_drift;
CREATE POLICY settlement_drift_tenant_isolation ON settlement_drift
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS reconciliation_runs_platform_only ON reconciliation_runs;
CREATE POLICY reconciliation_runs_platform_only ON reconciliation_runs
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Nothing here may be deleted. A settlement file that was ingested and a
-- disagreement that was found are the evidence in the dispute that comes later,
-- and a drift row somebody deleted is indistinguishable from a drift row that was
-- never found. A run is kept for the same reason the watchdog exists.
DROP POLICY IF EXISTS settlement_batches_no_delete ON settlement_batches;
CREATE POLICY settlement_batches_no_delete ON settlement_batches AS RESTRICTIVE FOR DELETE USING (false);
DROP POLICY IF EXISTS settlement_lines_no_delete ON settlement_lines;
CREATE POLICY settlement_lines_no_delete ON settlement_lines AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS settlement_drift_no_delete ON settlement_drift;
CREATE POLICY settlement_drift_no_delete ON settlement_drift AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS reconciliation_runs_no_delete ON reconciliation_runs;
CREATE POLICY reconciliation_runs_no_delete ON reconciliation_runs AS RESTRICTIVE FOR DELETE USING (false);

-- A batch is immutable once ingested: its totals are the provider's statement,
-- and a statement that can be edited is not one. The lines are mutable, because
-- matching writes to them, and the runs are mutable because a day is re-run.
DROP POLICY IF EXISTS settlement_batches_no_update ON settlement_batches;
CREATE POLICY settlement_batches_no_update ON settlement_batches AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON settlement_batches TO dwellm8_money;
GRANT SELECT, INSERT, UPDATE ON settlement_lines, settlement_drift,
    reconciliation_runs TO dwellm8_money;
GRANT SELECT ON settlement_drift_ageing TO dwellm8_money;
GRANT EXECUTE ON FUNCTION settlement_age_bucket(interval) TO dwellm8_app;
-- An owner's statement shows what has not settled, so the lease and property
-- modules read drift. Neither writes it.
GRANT SELECT ON settlement_drift TO dwellm8_lease, dwellm8_property;

-- ===========================================================================
-- identity verification (ADR-0013)
-- ===========================================================================

-- KYC identifiers are the highest-liability data in the platform, and the default
-- implementation of every vendor integration stores far too much: the SDK returns the
-- full identifier and the obvious thing to do is put it in a column.
--
-- So there is no column for one. What a completed verification holds is the result, a
-- masked reference, the provider and its transaction id, a timestamp and the consent
-- artefact — and kyc_verifications_reference_is_a_mask makes that true by construction
-- rather than by review: the reference column will not accept anything that is not a
-- mask, so a twelve-digit Aadhaar number cannot be put there by application code, by a
-- migration, or at a psql prompt.
--
-- Three tiers, and the middle one carries a lesson the org has already paid for:
--
--   prohibited  never at rest in any form. The Aadhaar number.
--   encrypted   at rest only as ciphertext, and — the half that matters — with no
--               plaintext column beside it. HomeChef's envelope encryption is dormant
--               precisely because its migration dual-wrote ciphertext while reads still
--               came from the plaintext column. Encryption that leaves a plaintext
--               column in place is a plaintext column with extra steps, and it will be
--               read: by a report, a support query, or a backup.
--   open        an institution's code or a public register. IFSC, GSTIN.
--
-- Which is why there is no `pan` column here at all. Encrypted values live in
-- payout_credentials (a later story) as ciphertext only, and the *masked* reference is
-- what this table holds so a screen can show which document was checked.

CREATE TABLE IF NOT EXISTS kyc_verifications (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES organisations(id),

    -- Whose document was checked. A party rather than a user: a guarantor may have no
    -- account here, and ADR-0006 already keeps balances per party.
    subject_party_id  uuid NOT NULL,

    kind              text NOT NULL CHECK (kind IN (
                          'aadhaar', 'pan', 'bank_account', 'ifsc', 'upi_vpa',
                          'passport', 'driving_licence', 'voter_id', 'gstin')),

    -- The only representation of the identifier that is kept. Not a hash: the Aadhaar
    -- space is small enough to enumerate, so a hash column is a lookup table for anybody
    -- who takes a copy. ADR-0013 alternative D.
    masked_reference  text NOT NULL,

    result            text NOT NULL CHECK (result IN (
                          'verified', 'failed', 'expired', 'withdrawn', 'unverified')),

    -- The audit trail at the other end. If a result is disputed, this is what the
    -- provider is asked about — and it is why a verification with no transaction id is
    -- refused.
    provider          text NOT NULL,
    provider_txn_id   text NOT NULL,

    -- DPDP requires a consent artefact, and a verification with no consent behind it is
    -- one that should not have happened.
    consent_artefact_id uuid NOT NULL,

    verified_at       timestamptz NOT NULL DEFAULT now(),
    -- Some checks go stale: a bank account changes, an address proof ages out. NULL
    -- means it does not expire on its own.
    expires_at        timestamptz,

    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT kyc_verifications_expiry CHECK (expires_at IS NULL OR expires_at > verified_at),
    -- kyc_verifications_reference_is_a_mask — the constraint that makes a full identifier
    -- unstorable — is in the "load-bearing rules" block below, not here. Written inline it
    -- was unrecoverable: this ADR's own verification dropped it, the replay could not put
    -- it back, and assertion 13 correctly reported a schema missing a rule it is built on.
    -- That is the trap the block exists for, biting a constraint added in the same session
    -- as the guard for it.
    CONSTRAINT kyc_verifications_reference_present CHECK (length(masked_reference) > 0)
);

COMMENT ON TABLE kyc_verifications IS
    'ADR-0013. What a completed identity check leaves behind. There is no column for a full identifier, and the reference column will not accept one.';
COMMENT ON COLUMN kyc_verifications.masked_reference IS
    'The only kept representation. Not a hash: the Aadhaar space is enumerable, so a hash column is a lookup table.';

-- One live verification per subject per kind. A second would leave two answers to "is
-- this person verified" with nothing to say which — and re-verification supersedes
-- rather than accumulates.
CREATE UNIQUE INDEX IF NOT EXISTS kyc_verifications_subject_kind_idx
    ON kyc_verifications (tenant_id, subject_party_id, kind)
    WHERE result = 'verified';
CREATE INDEX IF NOT EXISTS kyc_verifications_subject_idx
    ON kyc_verifications (tenant_id, subject_party_id);
-- "What is about to go stale" — the re-verification sweep.
CREATE INDEX IF NOT EXISTS kyc_verifications_expiring_idx
    ON kyc_verifications (tenant_id, expires_at) WHERE expires_at IS NOT NULL;

-- Every read of a KYC record, and why.
--
-- The story's edge case: support staff access is audited and time-bound. Auditing a read
-- cannot be done by the reader — a SELECT leaves no trace — so this table is written by
-- the service that performs the read, and the thing that makes it not merely a
-- convention is the reason column: a read with no purpose recorded is refused, and a
-- purpose is not something a query can invent for itself.
--
-- Time-bound is the `expires_at` on the access grant, not on the log: a support session
-- is granted for a window and the window is checked at read time.
CREATE TABLE IF NOT EXISTS kyc_access_log (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES organisations(id),
    verification_id   uuid NOT NULL REFERENCES kyc_verifications(id),

    -- Who looked. actor_kind distinguishes the subject reading their own record from a
    -- support engineer reading somebody else's, which is the distinction an audit is for.
    actor_kind        text NOT NULL CHECK (actor_kind IN ('subject', 'owner', 'agency', 'support', 'system')),
    actor_id          uuid,
    -- Why. Free text is deliberate here and is the one place in this schema where it is:
    -- a closed vocabulary of reasons becomes 'other' within a month, and an auditor
    -- reading 'other' learns nothing. What is not optional is that it is present.
    reason            text NOT NULL CHECK (length(btrim(reason)) >= 8),
    -- The support grant this read was made under, when it was made under one.
    support_grant_id  uuid,

    read_at           timestamptz NOT NULL DEFAULT now(),

    -- kyc_access_log_support_needs_a_grant is in the "load-bearing rules" block below: a
    -- support read with no grant behind it is the thing an audit exists to catch.
    -- Anything but the system names who acted.
    CONSTRAINT kyc_access_log_names_its_actor CHECK (
        actor_kind = 'system' OR actor_id IS NOT NULL)
);

COMMENT ON TABLE kyc_access_log IS
    'ADR-0013. Every read of a KYC record, with a purpose. A support read requires a grant, which is what makes access time-bound.';

CREATE INDEX IF NOT EXISTS kyc_access_log_verification_idx
    ON kyc_access_log (verification_id, read_at);
-- "What has this support engineer looked at" — the question after an incident.
CREATE INDEX IF NOT EXISTS kyc_access_log_actor_idx
    ON kyc_access_log (actor_kind, actor_id, read_at) WHERE actor_id IS NOT NULL;

ALTER TABLE kyc_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_verifications FORCE  ROW LEVEL SECURITY;
ALTER TABLE kyc_access_log    ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_access_log    FORCE  ROW LEVEL SECURITY;

-- Strict tenancy, and no delegated branch — which is a deliberate omission rather than
-- an oversight.
--
-- A management firm holds a grant to collect rent and manage a property. Nothing about
-- that requires reading a tenant's identity documents, and ADR-0005's permission
-- vocabulary has no 'kyc.read' for exactly this reason. If a firm ever needs it, that is
-- a new permission argued for in an ADR, not a widened policy.
DROP POLICY IF EXISTS kyc_verifications_tenant_isolation ON kyc_verifications;
CREATE POLICY kyc_verifications_tenant_isolation ON kyc_verifications
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS kyc_access_log_tenant_isolation ON kyc_access_log;
CREATE POLICY kyc_access_log_tenant_isolation ON kyc_access_log
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Neither may be deleted, and the access log may not be updated either: a log somebody
-- can edit is not a log. A verification is mutable only in the sense that it can expire
-- or be withdrawn, which is a result change.
DROP POLICY IF EXISTS kyc_verifications_no_delete ON kyc_verifications;
CREATE POLICY kyc_verifications_no_delete ON kyc_verifications AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS kyc_access_log_no_delete ON kyc_access_log;
CREATE POLICY kyc_access_log_no_delete ON kyc_access_log AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS kyc_access_log_no_update ON kyc_access_log;
CREATE POLICY kyc_access_log_no_update ON kyc_access_log AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT, UPDATE ON kyc_verifications TO dwellm8_identity;
GRANT SELECT, INSERT ON kyc_access_log TO dwellm8_identity;
-- Money reads whether a payee is verified before releasing a payout. It reads the
-- result and the mask, which is all there is.
GRANT SELECT ON kyc_verifications TO dwellm8_money, dwellm8_lease;

-- ===========================================================================
-- effective dating (ADR-0008)
-- ===========================================================================

-- "What was the rent in March?" and "who owned this flat when the deposit was
-- taken?" are answered from the primary tables. Not from an audit log — a log
-- records that a row changed, and the question is what the row *said*, which is not
-- reliably reconstructible from a diff.
--
-- The pattern, and every effective-dated table in this schema follows it:
--
--   valid_from  date NOT NULL          inclusive lower bound
--   valid_to    date                   EXCLUSIVE upper bound, NULL = open-ended
--   validity    daterange GENERATED    the canonical interval, never written
--   retired_at  timestamptz            set when a correction replaces this row
--   corrects    uuid                   the row a correction replaces
--
-- Three things about it are load-bearing.
--
-- **Half-open, [from, to).** The successor's valid_from equals the predecessor's
-- valid_to exactly: no gap to leave a date uncovered, no overlap to make two rows
-- true at once, and no "the day before" arithmetic anywhere. Closed intervals force
-- the writer to compute 31 March from 1 April, and every such computation is a place
-- to be wrong across a month boundary or a leap day.
--
-- **Dates, not timestamps.** A rent revision is effective from a date. A timestamp
-- forces a question with no good answer — is 1 April effective at 00:00 IST or
-- 00:00 UTC? — and the two differ by five and a half hours during which the rent is
-- legally one number and technically another. Indian agreements are dated by day.
--
-- delegation_grants (ADR-0005) is timestamptz and is correctly not part of this: an
-- authorisation window is not an effective date. A firm's access begins at a moment
-- and no legal document is dated by it. Assertion 14 splits the two by column type
-- and names the timestamptz tables, so a new one has to argue for itself.
--
-- **validity is generated, so there is exactly one expression.** The exclusion
-- constraint and every as-of query use the same column, which is what makes "an
-- open-ended interval is handled consistently everywhere" a property of the schema
-- rather than a rule people follow. The hand-written predicate —
-- `valid_from <= $1 AND (valid_to IS NULL OR valid_to > $1)` — has two places to get
-- the NULL wrong and one to get the boundary wrong. `validity @> $1::date` has none,
-- and `daterange(from, NULL)` is unbounded above without anybody saying so.
--
-- No SQL helper functions here on purpose. The range operators *are* the helpers:
-- `@>` for as-of, `&&` for overlap, `-|-` for adjacency. A function wrapping them
-- would be a second name for an operator every reader already knows.

-- Who owns a unit, and when they did.
--
-- The first table on the standard, and it is ownership rather than rent because rent
-- belongs to the lease (ADR-0010) and ownership belongs to the property. It answers
-- the second question in the story: who owned this flat when the deposit was taken.
CREATE TABLE IF NOT EXISTS property_ownership (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    -- NULL means the whole property. A tower owned by one party with two flats sold
    -- off is three rows: the property, and two units that override it.
    unit_id       uuid,
    unit_parent_id uuid,

    -- The owning party. Not an organisation: a flat's owner is a person or a company
    -- who may not have an account here at all, and ADR-0006 already keeps balances
    -- per party rather than per organisation.
    owner_party_id uuid NOT NULL,
    -- Undivided share, in basis points, for a jointly owned flat. 10000 = the whole
    -- of it. An integer of minor units, per ADR-0007: a share expressed as a
    -- percentage in floating point is a share that does not add to 100.
    share_bps     int NOT NULL DEFAULT 10000 CHECK (share_bps > 0 AND share_bps <= 10000),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    -- A correction retires the row it replaces rather than editing it. ADR-0008 §5:
    -- a change says the world changed, a correction says our record was wrong, and
    -- the difference cannot be recovered later if it is not recorded now.
    retired_at    timestamptz,
    corrects      uuid REFERENCES property_ownership(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT property_ownership_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT property_ownership_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT property_ownership_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    -- The upper bound is exclusive, so an interval must cover at least one day. An
    -- equal pair is empty, and an empty validity satisfies no as-of query while
    -- occupying a row that looks like it should.
    CONSTRAINT property_ownership_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- A correction retires and replaces together. A row that names what it corrects
    -- and is not itself live is a correction of a correction with no way to say which
    -- is current; a retired row that nothing corrects is history nobody can explain.
    CONSTRAINT property_ownership_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE property_ownership IS
    'ADR-0008. Who owned what, and when. Half-open date intervals; corrections retire the row they replace rather than editing it.';
COMMENT ON COLUMN property_ownership.validity IS
    'Generated from valid_from and valid_to. The one expression the exclusion constraint and every as-of query share, so open-ended is handled the same way everywhere.';

-- The no-overlap guarantee, and the story's failure scenario made structural.
--
-- An EXCLUDE constraint rather than a trigger or application logic: a trigger has to
-- read the table it is protecting and is therefore racy under concurrency, which is
-- exactly when two writers revise the same flat. The GiST index makes it a lock on
-- the range, so the second writer waits and then fails.
--
-- WHERE (retired_at IS NULL) is what makes corrections possible at all: a retired
-- row still occupies its interval and must not block its own replacement.
--
-- unit_id is compared with = rather than IS NOT DISTINCT FROM because two rows with
-- a NULL unit_id are both about the whole property and *should* conflict — and =
-- against NULL is unknown, so they would not. The partial-index pair below closes
-- that: one constraint for unit rows, one for property-level rows.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'property_ownership_no_overlap_unit') THEN
        ALTER TABLE property_ownership ADD CONSTRAINT property_ownership_no_overlap_unit
            EXCLUDE USING gist (
                tenant_id WITH =, unit_id WITH =, owner_party_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL AND unit_id IS NOT NULL);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'property_ownership_no_overlap_property') THEN
        ALTER TABLE property_ownership ADD CONSTRAINT property_ownership_no_overlap_property
            EXCLUDE USING gist (
                tenant_id WITH =, property_id WITH =, owner_party_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL AND unit_id IS NULL);
    END IF;
END
$$;

-- "Who owns this now", and "who owned it on this date" — the same index serves both,
-- because the second is the first with a different date.
CREATE INDEX IF NOT EXISTS property_ownership_asof_idx
    ON property_ownership USING gist (tenant_id, validity) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS property_ownership_party_idx
    ON property_ownership (owner_party_id, tenant_id) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS property_ownership_unit_idx
    ON property_ownership (tenant_id, unit_id) WHERE unit_id IS NOT NULL AND retired_at IS NULL;

-- Stamp the ancillary parent, as ledger_postings and payments do, so the policy never
-- reads units. SECURITY INVOKER for the same fail-closed reason.
CREATE OR REPLACE FUNCTION property_ownership_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.unit_id IS NULL THEN
        NEW.unit_parent_id := NULL;
        RETURN NEW;
    END IF;
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS property_ownership_parent ON property_ownership;
CREATE TRIGGER property_ownership_parent
    BEFORE INSERT OR UPDATE OF unit_id ON property_ownership
    FOR EACH ROW EXECUTE FUNCTION property_ownership_unit_parent();

-- History is not editable. valid_to may be closed and retired_at may be set — those
-- are the two writes effective dating needs — and nothing else may change, because a
-- row whose amount can be edited in place is a row that never had a history.
CREATE OR REPLACE FUNCTION property_ownership_append_only() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.valid_from <> OLD.valid_from
       OR NEW.owner_party_id <> OLD.owner_party_id
       OR NEW.share_bps <> OLD.share_bps
       OR NEW.property_id <> OLD.property_id
       OR NEW.unit_id IS DISTINCT FROM OLD.unit_id THEN
        RAISE EXCEPTION 'ownership row % may not be edited in place: close it and write the '
                        'successor for a change, or retire it and write the replacement for a '
                        'correction (ADR-0008 §5)', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    -- Closing an already-closed interval moves a boundary something downstream has
    -- already reported on.
    IF OLD.valid_to IS NOT NULL AND NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
        RAISE EXCEPTION 'ownership row % is already closed at %', OLD.id, OLD.valid_to
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at THEN
        RAISE EXCEPTION 'ownership row % is already retired', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS property_ownership_no_edit ON property_ownership;
CREATE TRIGGER property_ownership_no_edit
    BEFORE UPDATE ON property_ownership
    FOR EACH ROW EXECUTE FUNCTION property_ownership_append_only();

ALTER TABLE property_ownership ENABLE ROW LEVEL SECURITY;
ALTER TABLE property_ownership FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and assertion 6 enforces.
DROP POLICY IF EXISTS property_ownership_tenant_isolation ON property_ownership;
CREATE POLICY property_ownership_tenant_isolation ON property_ownership
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.write'));

DROP POLICY IF EXISTS property_ownership_no_delete ON property_ownership;
CREATE POLICY property_ownership_no_delete ON property_ownership AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON property_ownership TO dwellm8_property;
GRANT SELECT ON property_ownership TO dwellm8_lease, dwellm8_money, dwellm8_identity;

-- ===========================================================================
-- lease lifecycle (ADR-0010)
-- ===========================================================================

-- The lease is the object every other module hangs off, so its states are fixed here
-- before invoicing, documents or move-out are built.
--
--   leases         the tenancy, its agreed term and its state
--   lease_parties  who is on it, effective-dated (a tenant joins or leaves mid-term)
--   rent_schedule  what is owed, effective-dated (ADR-0008's own example)
--
-- All three are on ADR-0008's pattern, and assertion 14 policed rent_schedule before
-- this section existed — it is column-driven, so it found the table by its valid_from
-- rather than by anybody adding it to a list.
--
-- The agreed term and the actual end are different facts. `valid_from`/`valid_to` are
-- what the parties signed and never change; `ended_on` is the date occupancy actually
-- ceased. `validity` is the intersection, and it is what money and the no-double-let
-- constraint are computed over — so terminating early stops the billing by shortening
-- an interval rather than by setting a flag something has to remember to check.

CREATE TABLE IF NOT EXISTS leases (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    unit_parent_id uuid,

    state         text NOT NULL DEFAULT 'draft' CHECK (state IN (
                      'draft', 'pending_signature', 'active', 'in_notice',
                      'renewed', 'terminated', 'settled', 'lapsed')),

    -- The agreed term. NULL valid_to is a periodic tenancy with no agreed end.
    valid_from    date NOT NULL,
    valid_to      date,
    -- The date occupancy actually ceased, exclusive. NULL while running or if it ran
    -- to term. LEAST ignores NULLs, so the generated range below is: unbounded when
    -- both are NULL, whichever exists when one is, and the earlier when both are.
    ended_on      date,
    validity      daterange GENERATED ALWAYS AS
                  (daterange(valid_from, LEAST(valid_to, ended_on), '[)')) STORED,

    notice_days   int NOT NULL DEFAULT 30 CHECK (notice_days >= 0),
    lock_in_until date,

    -- Renewal is a new lease that names its predecessor, never a mutated row: the
    -- ledger history a tenancy accumulates hangs off the lease id, so mutating the row
    -- would silently re-attribute two years of postings to a different set of terms.
    renews_lease_id uuid REFERENCES leases(id),

    -- Termination, and the decision the story's failure scenario requires.
    terminated_by     text CHECK (terminated_by IN ('owner', 'tenant', 'system', 'platform')),
    terminated_reason text,
    settlement_decision text CHECK (settlement_decision IN ('none', 'adjust', 'refund', 'forfeit')),
    -- The only transition in the machine that goes backwards, so the only one that has
    -- to say why. ADR-0010 §3.
    notice_withdrawn_reason text,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT leases_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT leases_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT leases_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT leases_term CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- A tenancy cannot cease before it began, and ceasing after the agreement ran out
    -- is the agreement running out rather than a termination.
    CONSTRAINT leases_ended_within_term CHECK (
        ended_on IS NULL
        OR (ended_on > valid_from AND (valid_to IS NULL OR ended_on <= valid_to))),
    -- A lock-in that outlasts the tenancy locks the tenant in past the end of their
    -- own lease, which is not a term anybody agreed to.
    CONSTRAINT leases_lock_in_shape CHECK (
        lock_in_until IS NULL
        OR (lock_in_until > valid_from AND (valid_to IS NULL OR lock_in_until <= valid_to))),
    -- A terminated tenancy says who ended it, why, and what happened to the money.
    -- "Requires an explicit decision rather than silently deleting charges" starts
    -- here: the row cannot reach the state without one.
    CONSTRAINT leases_termination_shape CHECK (
        state NOT IN ('terminated', 'settled')
        OR (ended_on IS NOT NULL AND terminated_by IS NOT NULL
            AND terminated_reason IS NOT NULL AND settlement_decision IS NOT NULL)),
    -- A renewed tenancy has an end date, because its successor starts there.
    CONSTRAINT leases_renewed_has_an_end CHECK (state <> 'renewed' OR valid_to IS NOT NULL),
    CONSTRAINT leases_no_self_renewal CHECK (renews_lease_id <> id),
    -- So a journal entry can carry a composite foreign key to the lease it bills,
    -- which is what makes ADR-0010 §7's rule enforceable rather than conventional.
    CONSTRAINT leases_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE leases IS
    'ADR-0010. The tenancy. valid_from/valid_to are what the parties agreed and never change; ended_on is when occupancy actually ceased.';
COMMENT ON COLUMN leases.validity IS
    'The agreed term cut short by ended_on. What charge generation and the no-double-let constraint are computed over.';

-- The composite unique again, for the clusters where leases predates it: CREATE
-- TABLE IF NOT EXISTS adds no constraint to a table that already exists, so on
-- prod the declaration above was a no-op and every later composite foreign key
-- referencing (id, tenant_id) failed to create.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'leases_tenant_id_unique') THEN
        ALTER TABLE leases ADD CONSTRAINT leases_tenant_id_unique UNIQUE (id, tenant_id);
    END IF;
END $$;

-- One flat, one tenancy at a time — the constraint that matters most in a rental
-- product, and it is scoped to the states that are actually tenancies.
--
-- Draft and pending_signature are excluded on purpose: two competing offers on one
-- flat are legitimate, and refusing them would mean an owner cannot prepare a renewal
-- while the current tenancy runs. The moment one is signed, nothing else may overlap
-- it. lapsed is excluded because it never was a tenancy.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'leases_no_double_let') THEN
        ALTER TABLE leases ADD CONSTRAINT leases_no_double_let
            EXCLUDE USING gist (tenant_id WITH =, unit_id WITH =, validity WITH &&)
            WHERE (state IN ('active', 'in_notice', 'renewed', 'terminated', 'settled'));
    END IF;
END
$$;

-- A lease is renewed at most once. Two successors would each claim the tenancy
-- continued, and the ledger would have two candidates for where to carry the deposit.
CREATE UNIQUE INDEX IF NOT EXISTS leases_one_renewal
    ON leases (renews_lease_id) WHERE renews_lease_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leases_unit_idx ON leases (tenant_id, unit_id, state);
-- "What is live", and "what is running out" — the renewal reminder reads the second.
CREATE INDEX IF NOT EXISTS leases_live_idx
    ON leases (tenant_id, valid_to) WHERE state IN ('active', 'in_notice');
CREATE INDEX IF NOT EXISTS leases_asof_idx
    ON leases USING gist (tenant_id, validity) WHERE state IN ('active', 'in_notice');

-- The transition table, ADR-0010 §3. The same set exists in Go and the store contract
-- test evaluates this function over all 64 ordered pairs.
--
-- from = to is permitted: a redelivered event asks for the state the lease is already
-- in. in_notice -> active is the only backward edge, and the trigger below requires a
-- reason for it.
CREATE OR REPLACE FUNCTION lease_transition_allowed(from_state text, to_state text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_state = to_state
        OR (from_state, to_state) IN (
            ('draft',            'pending_signature'),
            ('draft',            'lapsed'),
            ('pending_signature','active'),
            -- The story's edge case: a lease whose tenant never signs. It bills
            -- nothing, because it was never a tenancy.
            ('pending_signature','lapsed'),
            ('active',           'in_notice'),
            ('active',           'renewed'),
            ('active',           'terminated'),
            ('in_notice',        'terminated'),
            -- Notice withdrawn. The workaround for refusing this is a new lease, which
            -- loses the ledger history the tenancy already has.
            ('in_notice',        'active'),
            ('terminated',       'settled'))
$$;

COMMENT ON FUNCTION lease_transition_allowed(text, text) IS
    'ADR-0010 §3. Terminal states absorb, from = to is a no-op, and in_notice -> active is the one backward edge.';

CREATE OR REPLACE FUNCTION leases_transition_is_legal() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT lease_transition_allowed(OLD.state, NEW.state) THEN
        RAISE EXCEPTION 'lease % cannot go from % to %', OLD.id, OLD.state, NEW.state
            USING ERRCODE = 'check_violation';
    END IF;
    -- The agreement is what the parties signed. Only ended_on may shorten the tenancy,
    -- and only once — for the reason ADR-0008 §6 gives about moving a boundary that
    -- something downstream has already reported on.
    IF NEW.valid_from <> OLD.valid_from OR NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
        RAISE EXCEPTION 'lease % may not have its agreed term edited: an early exit is recorded '
                        'in ended_on, because the parties did not agree to a shorter tenancy', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.ended_on IS NOT NULL AND NEW.ended_on IS DISTINCT FROM OLD.ended_on THEN
        RAISE EXCEPTION 'lease % already ceased on %', OLD.id, OLD.ended_on
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.unit_id <> OLD.unit_id THEN
        RAISE EXCEPTION 'lease % may not be moved to another unit: its ledger history is against '
                        'the unit it was let for', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    -- The one backward edge says why. It is the transition that makes the history
    -- non-monotonic, so it is the one somebody will later ask about.
    IF OLD.state = 'in_notice' AND NEW.state = 'active'
       AND NEW.notice_withdrawn_reason IS NULL THEN
        RAISE EXCEPTION 'lease % withdrew notice with no reason recorded', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_legal_transitions ON leases;
CREATE TRIGGER leases_legal_transitions
    BEFORE UPDATE ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_transition_is_legal();

-- The story's failure scenario, in the database.
--
-- A termination effective before the last invoiced period leaves charges raised for
-- time the tenant will not occupy. Deleting them is already impossible — ADR-0006 §3
-- revokes DELETE on the ledger and refuses it again in a policy — so what remains is
-- that somebody must decide, and 'none' is not a decision when money is at stake.
--
-- It asks the ledger, through journal_entries.lease_id.
--
-- The first version of this trigger matched on source_kind = 'lease_charge' AND
-- source_id = the lease id — a string convention the invoicing story had not yet been
-- written to follow, so the trigger was correct and inert: it found nothing and
-- permitted everything. A guard that depends on a convention nobody has agreed to is
-- not a guard, so the convention is now a foreign key (see journal_entries.lease_id
-- below) and journal_entries_lease_charge_shape makes the pairing structural. An
-- invoice cannot claim to be a lease charge without naming the lease.
--
-- source_kind is filtered because lease_id now names the tenancy an entry concerns,
-- payments included; unfiltered, the last receipt would move "billed through".
-- ADR-0006 §5 amendment.
--
-- SECURITY INVOKER: the lookup runs under the writer's own row-level security, so a
-- session that cannot see the ledger gets no rows and the check fails open rather than
-- reading another organisation's charges.
CREATE OR REPLACE FUNCTION leases_retrospective_end_needs_a_decision() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    billed_through date;
BEGIN
    IF NEW.ended_on IS NULL OR NEW.settlement_decision IS DISTINCT FROM 'none' THEN
        RETURN NEW;
    END IF;

    SELECT max(occurred_on) INTO billed_through
      FROM journal_entries e
     WHERE e.tenant_id = NEW.tenant_id
       AND e.lease_id = NEW.id
       AND e.source_kind = 'lease_charge';

    IF billed_through IS NOT NULL AND NEW.ended_on < billed_through THEN
        RAISE EXCEPTION 'lease % is ending % and charges are raised through %: an over-billed '
                        'period exists, so adjust it, refund it, or forfeit it — but say which',
            NEW.id, NEW.ended_on, billed_through
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_retrospective_end ON leases;
CREATE TRIGGER leases_retrospective_end
    BEFORE INSERT OR UPDATE OF ended_on, settlement_decision ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_retrospective_end_needs_a_decision();

-- A renewal starts exactly where its predecessor's agreed term ends. ADR-0008's
-- half-open interval doing the work: no gap for a day of unbilled occupancy, no
-- overlap for leases_no_double_let to refuse.
CREATE OR REPLACE FUNCTION leases_renewal_is_contiguous() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    prev_end date;
    prev_unit uuid;
BEGIN
    IF NEW.renews_lease_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT valid_to, unit_id INTO prev_end, prev_unit
      FROM leases WHERE id = NEW.renews_lease_id;
    IF prev_end IS NULL THEN
        RAISE EXCEPTION 'lease % renews %, which has no agreed end — a renewal starts where the '
                        'term ends, and that one does not end', NEW.id, NEW.renews_lease_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.valid_from <> prev_end THEN
        RAISE EXCEPTION 'lease % starts % and renews a tenancy ending %: a gap leaves a day '
                        'unbilled and an overlap is two tenancies of one flat',
            NEW.id, NEW.valid_from, prev_end USING ERRCODE = 'check_violation';
    END IF;
    IF prev_unit IS DISTINCT FROM NEW.unit_id THEN
        RAISE EXCEPTION 'lease % renews a tenancy of a different unit', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_renewal_contiguous ON leases;
CREATE TRIGGER leases_renewal_contiguous
    BEFORE INSERT OR UPDATE OF renews_lease_id, valid_from ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_renewal_is_contiguous();

CREATE OR REPLACE FUNCTION leases_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT u.parent_unit_id INTO NEW.unit_parent_id FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_parent ON leases;
CREATE TRIGGER leases_parent
    BEFORE INSERT OR UPDATE OF unit_id ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_unit_parent();

-- Who is on the lease, and when. Effective-dated because a co-tenant joins or leaves
-- mid-term and the deposit apportionment has to know who was there when.
CREATE TABLE IF NOT EXISTS lease_parties (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),

    party_id      uuid NOT NULL,
    role          text NOT NULL CHECK (role IN ('tenant', 'guarantor', 'occupant')),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES lease_parties(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lease_parties_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT lease_parties_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE lease_parties IS
    'ADR-0010. Who is on a lease and when. Effective-dated: a co-tenant joins or leaves mid-term.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lease_parties_no_overlap') THEN
        -- One person cannot hold the same role on the same lease twice at once. Two
        -- different people in the same role is the normal case for co-tenants, so the
        -- party is part of the key.
        ALTER TABLE lease_parties ADD CONSTRAINT lease_parties_no_overlap
            EXCLUDE USING gist (lease_id WITH =, party_id WITH =, role WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS lease_parties_lease_idx
    ON lease_parties (lease_id, role) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS lease_parties_party_idx
    ON lease_parties (tenant_id, party_id) WHERE retired_at IS NULL;

-- What is owed, and from when. ADR-0008's own worked example: a rent revision from
-- 25,000 to 27,000 effective 1 April is two rows, and an as-of query for 15 March
-- still says 25,000.
CREATE TABLE IF NOT EXISTS rent_schedule (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),

    -- ADR-0007: an integer of minor units, and the assertion about money columns
    -- checks the name and the type.
    amount_minor  bigint NOT NULL CHECK (amount_minor > 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    -- The day of the month rent falls due. 31 means the last day, whatever that is.
    due_day       int NOT NULL DEFAULT 5 CHECK (due_day BETWEEN 1 AND 31),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES rent_schedule(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT rent_schedule_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT rent_schedule_amount_representable CHECK (amount_minor <= 9007199254740991),
    CONSTRAINT rent_schedule_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE rent_schedule IS
    'ADR-0010 and ADR-0008. What is owed and from when. Charge generation is this intersected with the lease''s validity.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rent_schedule_no_overlap') THEN
        -- One rent at a time. This is the constraint the story's failure scenario is
        -- about, on the table the story's primary scenario is about.
        ALTER TABLE rent_schedule ADD CONSTRAINT rent_schedule_no_overlap
            EXCLUDE USING gist (lease_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS rent_schedule_asof_idx
    ON rent_schedule USING gist (lease_id, validity) WHERE retired_at IS NULL;

-- Expiring, derived. ADR-0010 §6: a stored `expiring` state needs a job to maintain it,
-- and a lease that should be expiring and is not would be a silent bug. Same argument
-- ADR-0012 §7 makes about ageing buckets.
--
-- security_invoker, as assertion 10 requires of every view in this schema.
CREATE OR REPLACE VIEW lease_expiring
    WITH (security_invoker = true) AS
    SELECT l.id AS lease_id,
           l.tenant_id,
           l.property_id,
           l.unit_id,
           l.state,
           l.valid_to                        AS ends_on,
           (l.valid_to - current_date)       AS days_remaining,
           l.notice_days,
           -- Whether notice can still be given in time, which is the thing an owner
           -- actually needs to know and is one subtraction away from being got wrong
           -- in a dashboard.
           (l.valid_to - current_date) <= l.notice_days AS inside_notice_window
      FROM leases l
     WHERE l.state IN ('active', 'in_notice')
       AND l.valid_to IS NOT NULL
       AND l.valid_to > current_date;

COMMENT ON VIEW lease_expiring IS
    'ADR-0010 §6. Tenancies running out, derived from the clock. Never a stored state: one that should be expiring and is not would be a silent bug.';

ALTER TABLE leases        ENABLE ROW LEVEL SECURITY;
ALTER TABLE leases        FORCE  ROW LEVEL SECURITY;
ALTER TABLE lease_parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE lease_parties FORCE  ROW LEVEL SECURITY;
ALTER TABLE rent_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE rent_schedule FORCE  ROW LEVEL SECURITY;

-- Unit granularity on leases, as ADR-0009 §4 requires and assertion 6 enforces: a firm
-- managing two flats must not read the tower's rent roll.
DROP POLICY IF EXISTS leases_tenant_isolation ON leases;
CREATE POLICY leases_tenant_isolation ON leases
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'lease.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'lease.write'));

-- The two child tables carry no unit of their own, so their delegated branch is the
-- parent lease's. Written as an EXISTS against leases rather than by denormalising the
-- unit, because the lease's own policy then governs both — one definition of who may
-- see a tenancy, rather than three that can drift.
DROP POLICY IF EXISTS lease_parties_tenant_isolation ON lease_parties;
CREATE POLICY lease_parties_tenant_isolation ON lease_parties
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.id = lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS rent_schedule_tenant_isolation ON rent_schedule;
CREATE POLICY rent_schedule_tenant_isolation ON rent_schedule
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.id = lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A lease that lapsed and a rent that was revised are
-- what a dispute turns on, and a deleted lease orphans every posting made against it.
DROP POLICY IF EXISTS leases_no_delete ON leases;
CREATE POLICY leases_no_delete ON leases AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS lease_parties_no_delete ON lease_parties;
CREATE POLICY lease_parties_no_delete ON lease_parties AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS rent_schedule_no_delete ON rent_schedule;
CREATE POLICY rent_schedule_no_delete ON rent_schedule AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON leases, lease_parties, rent_schedule TO dwellm8_lease;
GRANT SELECT ON lease_expiring TO dwellm8_lease, dwellm8_notify, dwellm8_property;
-- Money bills against the lease and reads the schedule; it writes neither.
GRANT SELECT ON leases, lease_parties, rent_schedule
    TO dwellm8_money, dwellm8_property, dwellm8_identity, dwellm8_notify, dwellm8_maintenance;

-- ===========================================================================
-- lease tax facts — the two facts that decide the TDS section (ADR-0024)
-- ===========================================================================

-- What kind of payer the tenant is, and whether the landlord is a resident. Those
-- two answers select section 194-I, 194-IB or 195, and with them the rate, the
-- threshold, the periodicity, the forms and who is liable when it is missed.
--
-- A table rather than two columns on leases, because residency changes. A landlord
-- who moves abroad in October was a resident in April, and both are true of the same
-- tenancy in the same financial year: April's rent was deducted at ten per cent
-- under 194-I and deposited and certified that way, and overwriting a column would
-- restate a deduction that was correct. ADR-0008's shape, for ADR-0008's reason.
--
-- No acknowledgement is required to *record* a fact: a draft lease may know the
-- landlord is an NRI before the tenant has been shown what that costs them. It is
-- required to *start the tenancy*, which is the trigger below.
CREATE TABLE IF NOT EXISTS lease_tax_facts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL,

    -- Narrower than "individual or company": the line the Act draws is whether the
    -- payer is an individual or HUF *not* liable to audit under section 44AB, because
    -- that class alone deducts under 194-IB. The same four values exist in Go and the
    -- store contract test fails the build if they diverge.
    deductor_class     text NOT NULL CHECK (deductor_class IN (
                           'individual_no_audit', 'individual_audited', 'business', 'government')),
    landlord_residency text NOT NULL CHECK (landlord_residency IN ('resident', 'non_resident')),

    -- Residency is asserted rather than proved, so the assertion has an author. When
    -- the assessing officer asks, "the tenant declared it on this date" is an answer
    -- and "the system had it" is not.
    source        text NOT NULL CHECK (btrim(source) <> ''),

    -- The section 195 acknowledgement: the deductor was shown that tax runs from the
    -- first rupee and that the liability for missing it is theirs, and accepted it.
    acknowledged_on date,
    acknowledged_by text,

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES lease_tax_facts(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT lease_tax_facts_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT lease_tax_facts_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- An acknowledgement dated by nobody is not an acknowledgement, and a name with no
    -- date cannot be shown to have preceded the tenancy.
    CONSTRAINT lease_tax_facts_acknowledgement_shape CHECK (
        (acknowledged_on IS NULL) = (acknowledged_by IS NULL)),
    CONSTRAINT lease_tax_facts_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE lease_tax_facts IS
    'ADR-0024. Deductor class and landlord residency over the life of a tenancy — the two facts that select the TDS section. Effective dated: a residency that changes leaves the earlier months as they were deducted.';

-- One set of facts true at a time, per lease. An EXCLUDE rather than a trigger for
-- the reason property_ownership gives: a trigger reads the table it is protecting
-- and is racy exactly when two writers revise the same tenancy.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lease_tax_facts_no_overlap') THEN
        ALTER TABLE lease_tax_facts ADD CONSTRAINT lease_tax_facts_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, lease_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS lease_tax_facts_asof_idx
    ON lease_tax_facts (tenant_id, lease_id, valid_from DESC)
    WHERE retired_at IS NULL;

-- The story's failure scenario, in the database: a tenancy does not start until its
-- tax path is known, and a section 195 tenancy does not start until the deductor has
-- accepted the obligation.
--
-- On the transition into a tenancy rather than on every write, because a draft is a
-- document being written and may legitimately be incomplete. The moment rent can be
-- paid under it, a payment made under facts nobody recorded is a deduction nobody
-- made — and by the time the payout run finds it, nine months of interest and
-- penalty have accrued to a tenant who was never asked.
--
-- Deferred to commit, because the facts and the lease are written together and the
-- facts carry a foreign key to the lease: an immediate check would force the two
-- into an order the caller should not have to know about. What it asserts is that no
-- transaction *ends* with a tenancy whose tax path is unknown.
CREATE OR REPLACE FUNCTION leases_tax_path_is_known() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    f record;
BEGIN
    IF NEW.state <> 'active' OR (TG_OP = 'UPDATE' AND OLD.state = 'active') THEN
        RETURN NULL;
    END IF;

    SELECT * INTO f
      FROM lease_tax_facts
     WHERE lease_id = NEW.id
       AND retired_at IS NULL
       AND validity @> NEW.valid_from;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'lease % cannot start on %: nothing says what the deductor and the '
                        'landlord are, so no TDS section governs its first payment',
                        NEW.id, NEW.valid_from
            USING ERRCODE = 'check_violation';
    END IF;

    IF f.landlord_residency = 'non_resident' AND f.acknowledged_on IS NULL THEN
        RAISE EXCEPTION 'lease % is a section 195 tenancy: tax is deducted from the first rupee '
                        'and the deductor carries the liability, and the tenancy cannot start '
                        'until that is acknowledged', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION leases_tax_path_is_known() IS
    'ADR-0024. A tenancy does not start with an unknown TDS path, and a section 195 tenancy does not start unacknowledged. Deferred to commit: the facts and the lease are written together.';

DROP TRIGGER IF EXISTS leases_tax_path_known ON leases;
CREATE CONSTRAINT TRIGGER leases_tax_path_known
    AFTER INSERT OR UPDATE ON leases
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION leases_tax_path_is_known();

ALTER TABLE lease_tax_facts ENABLE ROW LEVEL SECURITY;
ALTER TABLE lease_tax_facts FORCE  ROW LEVEL SECURITY;

-- The parent lease's policy governs, as with lease_parties: one definition of who may
-- see a tenancy rather than three that drift apart.
DROP POLICY IF EXISTS lease_tax_facts_tenant_isolation ON lease_tax_facts;
CREATE POLICY lease_tax_facts_tenant_isolation ON lease_tax_facts
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.id = lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. What the tenant declared, and when, is the whole
-- defence when a deduction is questioned years later.
DROP POLICY IF EXISTS lease_tax_facts_no_delete ON lease_tax_facts;
CREATE POLICY lease_tax_facts_no_delete ON lease_tax_facts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON lease_tax_facts TO dwellm8_lease;
-- Money reads the path to deduct against it, and writes none of it: the section is
-- the lease's fact, not the payout's.
GRANT SELECT ON lease_tax_facts TO dwellm8_money, dwellm8_notify;

-- ---------------------------------------------------------------------------
-- identity — who signed in, and what they may act as (ADR-0027)
-- ---------------------------------------------------------------------------
--
-- A Google Identity Platform user, and the person they are here.
--
-- One GIP tenant per app surface, so the same phone number in Own and in Live is
-- two separate user records with no way to reach each other — that isolation is
-- Google's rather than ours. A uid is therefore unique only *within* a pool, and
-- the key here is the pair: (surface, gip_uid). A unique index on gip_uid alone
-- would collide two different people the first time Google reused an id across
-- tenants.
--
-- Dwellm8 staff authenticate at the project level with no tenant at all, and
-- carry surface = 'staff'. That is the product-owner exception, and it is the
-- absence of a tenant claim rather than a boolean anybody can set.
CREATE TABLE IF NOT EXISTS identity_principals (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Which pool they signed into. 'staff' is the project level.
    surface       text NOT NULL CHECK (surface IN (
                      'own', 'ops', 'live', 'find', 'pro', 'admin', 'staff')),
    gip_uid       text NOT NULL CHECK (btrim(gip_uid) <> ''),

    -- The person. Not an organisation: one person may be a tenant of one
    -- organisation and an owner in another, and the membership table below is
    -- what says which.
    party_id      uuid NOT NULL DEFAULT gen_random_uuid(),

    -- The verified identifier, kept because it is how support finds somebody and
    -- how a tenancy is matched to a sign-in. Phone is the one Indian rental runs
    -- on. Never a password, and never an Aadhaar number — ADR-0013 §2.
    phone         text CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$'),
    email         citext,
    sign_in_provider text CHECK (sign_in_provider IN ('phone', 'google.com', 'apple.com')),

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    -- Disabling is a timestamp rather than a delete: the sign-ins, the audit rows
    -- and the tenancies all point here.
    disabled_at   timestamptz,

    CONSTRAINT identity_principals_pool_uid UNIQUE (surface, gip_uid)
);

COMMENT ON TABLE identity_principals IS
    'ADR-0027. A GIP user in one surface pool, and the person they are. Unique on (surface, gip_uid): a uid is unique within a pool, not across pools.';

-- No tenant_id, and that is the point: a principal exists before they belong to
-- any organisation — somebody signing into Find is nobody's tenant yet. So it is
-- not tenant-scoped data, and it is not readable by the request role at all.
-- Only the identity module may see it, which is a grant rather than a policy.
REVOKE ALL ON identity_principals FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON identity_principals TO dwellm8_identity;

-- What a person may act as.
--
-- This is the row that turns a verified sign-in into an organisation, and it is
-- the only thing that does. A token says who somebody is; this says what they
-- may be. Conflating the two would put the tenancy boundary in a claim whose
-- contents the client controls.
CREATE TABLE IF NOT EXISTS organisation_members (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    party_id      uuid NOT NULL,

    -- What they are in this organisation. Coarse on purpose: fine-grained
    -- permission is ADR-0005's delegation grants and OpenFGA, and a role column
    -- that tried to express both would express neither.
    role          text NOT NULL CHECK (role IN ('owner', 'manager', 'staff', 'tenant', 'vendor')),

    -- Effective dated, like every other membership here: somebody leaves a firm,
    -- and the question a year later is what they could see while they were there.
    valid_from    date NOT NULL DEFAULT current_date,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT organisation_members_window CHECK (valid_to IS NULL OR valid_to > valid_from)
);

COMMENT ON TABLE organisation_members IS
    'ADR-0027. What a person may act as in an organisation. Effective dated: the question after somebody leaves is what they could see while they were there.';

-- One live membership per person per organisation per role.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organisation_members_no_overlap') THEN
        ALTER TABLE organisation_members ADD CONSTRAINT organisation_members_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, party_id WITH =, role WITH =, validity WITH &&);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS organisation_members_party_idx
    ON organisation_members (party_id, valid_from DESC);

ALTER TABLE organisation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisation_members FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS organisation_members_tenant_isolation ON organisation_members;
CREATE POLICY organisation_members_tenant_isolation ON organisation_members
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A revoked membership is closed, never deleted: losing it loses the record of
-- what somebody could reach and when.
DROP POLICY IF EXISTS organisation_members_no_delete ON organisation_members;
CREATE POLICY organisation_members_no_delete ON organisation_members AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON organisation_members TO dwellm8_identity;
GRANT SELECT ON organisation_members
    TO dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
       dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- ===========================================================================
-- consent artefacts — what was agreed to, and under which notice (ADR-0026)
-- ===========================================================================

-- The thing ADR-0013 was already pointing at. kyc_verifications has carried a
-- NOT NULL consent_artefact_id since it was written, referencing a table that
-- did not exist — so the column was a promise rather than a link.
--
-- An object rather than a boolean, because "the user agreed" is not evidence of
-- anything a year later when the notice has been reworded twice. DPDP §5
-- requires the notice to state the purpose and to be available in English or a
-- language in the Eighth Schedule; recording which version and which language
-- were actually shown is what makes either claim checkable.
CREATE TABLE IF NOT EXISTS consent_artefacts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    party_id      uuid NOT NULL,

    -- The purposes the product actually processes for. A free-text purpose is a
    -- purpose nobody can audit, and withdrawal has to be answerable per purpose.
    purpose       text NOT NULL CHECK (purpose IN (
                      'tenancy', 'kyc', 'payments', 'statutory', 'marketing', 'support')),

    -- Which wording was shown. Not a foreign key to a notices table yet: the
    -- notice content is versioned in the repository, and a version string is
    -- what ties this row to a commit.
    notice_version text NOT NULL CHECK (btrim(notice_version) <> ''),
    -- An ISO 639-1 code. English or an Eighth Schedule language, and which one
    -- was shown is the data principal's right rather than a preference.
    language      text NOT NULL CHECK (language ~ '^[a-z]{2}$'),

    given_at      timestamptz NOT NULL DEFAULT now(),
    withdrawn_at  timestamptz,

    -- How it was collected, so a disputed consent can be traced to a screen.
    channel       text CHECK (channel IN ('app', 'web', 'in_person', 'agent')),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT consent_artefacts_withdrawal CHECK (
        withdrawn_at IS NULL OR withdrawn_at >= given_at),
    -- So kyc_verifications can carry a composite key and a verification cannot
    -- cite another organisation's consent.
    CONSTRAINT consent_artefacts_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE consent_artefacts IS
    'ADR-0026. What was consented to, for which purpose, under which notice version and in which language. Withdrawal is a timestamp, never a delete.';

-- One live consent per person per purpose. A second would mean two answers to
-- "may we process this", and whichever sorted first would win.
CREATE UNIQUE INDEX IF NOT EXISTS consent_artefacts_one_live_idx
    ON consent_artefacts (tenant_id, party_id, purpose)
    WHERE withdrawn_at IS NULL;

-- The link ADR-0013 promised. NOT VALID, and deliberately: existing rows carry
-- ids that point nowhere, and validating against them would fail the bootstrap
-- on a database that is otherwise correct. New rows are checked from here on,
-- and the backfill is its own reviewed change.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'kyc_verifications_consent_fkey') THEN
        ALTER TABLE kyc_verifications ADD CONSTRAINT kyc_verifications_consent_fkey
            FOREIGN KEY (consent_artefact_id, tenant_id)
            REFERENCES consent_artefacts (id, tenant_id) NOT VALID;
    END IF;
END
$$;

ALTER TABLE consent_artefacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_artefacts FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS consent_artefacts_tenant_isolation ON consent_artefacts;
CREATE POLICY consent_artefacts_tenant_isolation ON consent_artefacts
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A withdrawn consent is not a deleted one. The record that consent was given,
-- and then taken back, is the evidence in both directions.
DROP POLICY IF EXISTS consent_artefacts_no_delete ON consent_artefacts;
CREATE POLICY consent_artefacts_no_delete ON consent_artefacts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON consent_artefacts
    TO dwellm8_identity, dwellm8_lease, dwellm8_discovery;
GRANT SELECT ON consent_artefacts TO dwellm8_money, dwellm8_notify, dwellm8_community;

-- ===========================================================================
-- section 197 certificates — a rate the Assessing Officer set for one landlord
-- ===========================================================================

-- A lower or nil deduction certificate under section 197: the Assessing Officer
-- has determined that this landlord's tax on this income is less than the section
-- rate would deduct, and issued a certificate saying so.
--
-- **Beside the registry, not in it.** statutory_rules holds what the law says for
-- everyone and has no runtime writer on purpose (ADR-0023 §2); this is a fact
-- about one landlord, produced by an officer, entered by a user, and scoped to an
-- organisation. Putting it in the registry would mean handing back the INSERT that
-- ADR-0023 revoked, which is the exact defect assertion 18 exists to catch.
--
-- It is also the only thing that makes a section 195 deduction computable, since
-- the registry deliberately holds no section 195 rate (ADR-0024 §5). ADR-0025 §1.
CREATE TABLE IF NOT EXISTS tds_certificates (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    -- The landlord the certificate is for. A bare uuid like every other party
    -- reference here: a payee is a person or a company who may hold no account.
    party_id      uuid NOT NULL,

    -- A certificate is issued for a section. One that names 194-I does not lower
    -- a 195 deduction, and applying it to both is how a nil certificate for rent
    -- ends up applied to a capital payment.
    section       text NOT NULL CHECK (section IN ('194i', '194ib', '195')),

    certificate_number text NOT NULL CHECK (btrim(certificate_number) <> ''),
    -- Zero is a nil-deduction certificate, which is a real and common outcome —
    -- and the reason this is a rate rather than a nullable "lower rate".
    rate_bps      int NOT NULL CHECK (rate_bps >= 0 AND rate_bps <= 1000000),

    -- A certificate always expires: it is issued for a period, usually to the end
    -- of the financial year. valid_to is NOT NULL for that reason, unlike every
    -- other effective-dated table here — an open-ended certificate would keep
    -- lowering a deduction for years after the officer's determination lapsed.
    valid_from    date NOT NULL,
    valid_to      date NOT NULL,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    issued_on     date NOT NULL,
    -- Which officer or circle issued it. Free text because the format is not ours.
    issued_by     text,

    retired_at    timestamptz,
    corrects      uuid REFERENCES tds_certificates(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT tds_certificates_window CHECK (valid_to > valid_from),
    -- A certificate cannot apply before it was issued. The other direction is
    -- legitimate: an officer issues in June for a period beginning in April.
    CONSTRAINT tds_certificates_issued_before_expiry CHECK (issued_on < valid_to),
    CONSTRAINT tds_certificates_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE tds_certificates IS
    'ADR-0025. Section 197 lower/nil deduction certificates: a rate an Assessing Officer set for one landlord, for one section, for a bounded period. Tenant data, deliberately not in statutory_rules.';

-- One live certificate per landlord per section per day. Two would mean two rates
-- for the same deduction and whichever sorted first would win.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tds_certificates_no_overlap') THEN
        ALTER TABLE tds_certificates ADD CONSTRAINT tds_certificates_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, party_id WITH =, section WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS tds_certificates_asof_idx
    ON tds_certificates (tenant_id, party_id, section, valid_from DESC)
    WHERE retired_at IS NULL;

ALTER TABLE tds_certificates ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_certificates FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tds_certificates_tenant_isolation ON tds_certificates;
CREATE POLICY tds_certificates_tenant_isolation ON tds_certificates
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A certificate is the authority for having deducted
-- less than the section says, and it is the first document produced when that is
-- questioned.
DROP POLICY IF EXISTS tds_certificates_no_delete ON tds_certificates;
CREATE POLICY tds_certificates_no_delete ON tds_certificates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON tds_certificates TO dwellm8_lease;
GRANT SELECT ON tds_certificates TO dwellm8_money, dwellm8_notify;

-- ===========================================================================
-- TDS obligations — what a deduction obliges, and whether it was done
-- ===========================================================================

-- One row per deduction per lease per period, and one child row per step: the
-- deduction itself, the deposit, the return and the certificate.
--
-- A tracker rather than a calculation. The amount is computed elsewhere and the
-- dates are statutory; what this table holds is whether each step happened and
-- what proves it — a challan identification number, an acknowledgement number, a
-- certificate number. "Deposited, trust me" is exactly the state it exists to
-- refuse, because the CIN is the only thing that links the payment to the
-- deduction when a notice arrives two years later.
--
-- Steps are rows rather than columns for the reason ADR-0008 gives generally:
-- §194-IB has no deposit step at all (Form 26QC is a challan-cum-statement), so
-- a `deposited_on` column would be permanently NULL on that path and permanently
-- ambiguous — never happened, or never applied.
CREATE TABLE IF NOT EXISTS tds_obligations (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL,

    section       text NOT NULL CHECK (section IN ('194i', '194ib', '195')),

    -- What the deduction is on, and when the rent it came from was paid or
    -- credited — every deadline below runs from that date.
    period_from   date NOT NULL,
    period_to     date NOT NULL,
    paid_on       date NOT NULL,

    -- ADR-0007: an integer of minor units.
    amount_minor  bigint NOT NULL CHECK (amount_minor > 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The rows the deduction was computed from, so what was deducted can be
    -- explained years later without recomputing it against today's registry.
    rate_bps      int NOT NULL CHECK (rate_bps >= 0),
    rate_rule_id  uuid REFERENCES statutory_rules(id),
    certificate_id uuid REFERENCES tds_certificates(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tds_obligations_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT tds_obligations_period CHECK (period_to > period_from),
    -- One deduction per lease per period per section. A second is either a
    -- duplicate or a correction, and a correction is a reversal plus a new row.
    CONSTRAINT tds_obligations_once UNIQUE (tenant_id, lease_id, section, period_from),
    -- So the steps can carry a composite key back to their obligation, which is
    -- what makes "the step and its obligation belong to the same organisation"
    -- structural rather than conventional.
    CONSTRAINT tds_obligations_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE tds_obligations IS
    'ADR-0024 and ADR-0025. One deduction, its statutory deadlines and the evidence that each step was done.';

CREATE TABLE IF NOT EXISTS tds_obligation_steps (
    obligation_id uuid NOT NULL REFERENCES tds_obligations(id) ON DELETE CASCADE,
    -- Denormalised from the parent, and assertion 12 is why: a table whose rows
    -- may belong to no organisation cannot be constrained by
    -- tenant_id = current_tenant_id(), so any organisation could write a row
    -- belonging to none. The composite foreign key below keeps the two in step.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    step          text NOT NULL CHECK (step IN ('deduct', 'deposit', 'report', 'certify')),

    due_by        date NOT NULL,
    artefact      text NOT NULL,

    -- Outstanding until both are present. A reference with no date, or a date
    -- with no reference, is a step somebody started recording and did not
    -- finish — and treating it as done is how an unfiled return looks filed.
    reference     text,
    done_on       date,

    PRIMARY KEY (obligation_id, step),
    CONSTRAINT tds_obligation_steps_obligation_fkey FOREIGN KEY (obligation_id, tenant_id)
        REFERENCES tds_obligations (id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT tds_obligation_steps_evidence CHECK (
        (reference IS NULL) = (done_on IS NULL))
);

COMMENT ON TABLE tds_obligation_steps IS
    'The steps one deduction obliges. A step is done when it has both a reference and a date; a challan number with no date is not a deposit.';

CREATE INDEX IF NOT EXISTS tds_obligation_steps_outstanding_idx
    ON tds_obligation_steps (due_by)
    WHERE reference IS NULL;

ALTER TABLE tds_obligations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_obligations      FORCE  ROW LEVEL SECURITY;
ALTER TABLE tds_obligation_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_obligation_steps FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tds_obligations_tenant_isolation ON tds_obligations;
CREATE POLICY tds_obligations_tenant_isolation ON tds_obligations
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- The child carries no tenant of its own, so the parent's policy governs it —
-- one definition of who may see a deduction rather than two that drift.
DROP POLICY IF EXISTS tds_obligation_steps_tenant_isolation ON tds_obligation_steps;
CREATE POLICY tds_obligation_steps_tenant_isolation ON tds_obligation_steps
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS tds_obligation_steps_no_delete ON tds_obligation_steps;
CREATE POLICY tds_obligation_steps_no_delete ON tds_obligation_steps AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Nothing here may be deleted. What was deducted, when it was deposited and
-- which challan carried it is the answer to a notice, and a deleted row is a
-- deduction that cannot be proved.
DROP POLICY IF EXISTS tds_obligations_no_delete ON tds_obligations;
CREATE POLICY tds_obligations_no_delete ON tds_obligations AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON tds_obligations, tds_obligation_steps TO dwellm8_money;
GRANT SELECT ON tds_obligations, tds_obligation_steps TO dwellm8_lease, dwellm8_notify;

-- ===========================================================================
-- mandates — the standing authority behind a recurring debit (ADR-0022)
-- ===========================================================================

-- A mandate is not a payment, and the two disagree about time. A payment is one
-- attempt that resolves in minutes; a mandate is an authority that lives for the
-- length of a tenancy, is paused and resumed on purpose, and produces many
-- payments. ADR-0011 modelled `upi_autopay` as an ordinary method because the
-- authority behind it did not exist yet.
--
-- The rail vocabulary is closed and names no aggregator: Razorpay calls the
-- authority a token, Cashfree calls it a subscription, and both are a
-- provider_mandate_id here.
CREATE TABLE IF NOT EXISTS mandates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    -- unit_id is NOT NULL, unlike payments. An authority over a whole property
    -- is not one any tenant gave, and the unit is what the policy scopes on.
    property_id     uuid NOT NULL,
    unit_id         uuid NOT NULL,
    unit_parent_id  uuid,

    -- The tenancy this authority was taken for. A mandate that outlives its
    -- lease is a live authority to debit somebody who has moved out.
    lease_id        uuid,

    payer_kind      text NOT NULL DEFAULT 'tenant' CHECK (payer_kind = 'tenant'),
    payer_id        uuid NOT NULL,

    rail            text NOT NULL CHECK (rail IN ('upi_autopay', 'enach', 'nach_physical')),

    -- The ceiling the payer authorised, fixed at registration on every rail we
    -- use. A rent escalation past it needs a new authority.
    max_amount_minor bigint NOT NULL CHECK (max_amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    provider            text NOT NULL,
    provider_mandate_id text,

    status          text NOT NULL DEFAULT 'created' CHECK (status IN (
                        'created', 'pending', 'active', 'paused',
                        'rejected', 'revoked', 'expired')),
    failure_code    text,

    -- Which rule-table row routed this tenancy to this rail, so a decision can
    -- be explained a year later when the caps have moved.
    rail_rule_source text,

    -- ADR-0011 §2's guarantee, applied to authorities. A duplicate mandate is
    -- worse than a duplicate order: it debits a tenant twice a month, forever,
    -- and looks legitimate from both ends.
    idempotency_key text NOT NULL,

    first_debit_on  date,
    ends_on         date,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    activated_at    timestamptz,
    ended_at        timestamptz,

    CONSTRAINT mandates_id_tenant_key UNIQUE (id, tenant_id),
    CONSTRAINT mandates_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT mandates_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT mandates_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT mandates_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT mandates_amount_representable CHECK (max_amount_minor <= 9007199254740991),
    CONSTRAINT mandates_ends_after_it_starts CHECK (
        ends_on IS NULL OR first_debit_on IS NULL OR ends_on >= first_debit_on)
    -- mandates_active_has_provider_id is in the load-bearing block below, for the
    -- reason every CHECK that matters is: one written here never reaches a
    -- database that already has the table.
);

COMMENT ON TABLE mandates IS
    'ADR-0022. The standing authority a tenant gave. Not a payment: it is paused and resumed on purpose, and the debits it produces are ordinary payments.';

CREATE UNIQUE INDEX IF NOT EXISTS mandates_idempotency_idx
    ON mandates (tenant_id, idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS mandates_provider_idx
    ON mandates (provider, provider_mandate_id) WHERE provider_mandate_id IS NOT NULL;

-- One live authority per unit. Two active mandates on one flat is a tenant
-- debited twice on the first of the month, and it is the kind of duplicate that
-- looks correct from every screen: both mandates are real, both were authorised,
-- and nothing but this index says the second should not exist.
CREATE UNIQUE INDEX IF NOT EXISTS mandates_one_active_per_unit_idx
    ON mandates (tenant_id, unit_id) WHERE status = 'active';

-- What the debit scheduler asks for: every authority that may be debited.
CREATE INDEX IF NOT EXISTS mandates_debitable_idx
    ON mandates (tenant_id, first_debit_on) WHERE status = 'active';
-- What the sweep asks for: authorities that were never answered. Physical NACH
-- sits in `pending` for a working week, so "stuck" is a matter of days.
CREATE INDEX IF NOT EXISTS mandates_awaiting_idx
    ON mandates (provider, created_at) WHERE status IN ('created', 'pending');

-- The transition table. The same set exists in Go and the contract test
-- evaluates this function over every ordered pair.
--
-- It is deliberately not forward-only, which is where it differs from
-- payment_transition_allowed and the difference is load-bearing. A payment moves
-- once because money does; an authority is paused and resumed as a product
-- feature, and a tenant coming off a payment holiday must not have to
-- re-authorise a mandate nobody revoked.
CREATE OR REPLACE FUNCTION mandate_transition_allowed(from_status text, to_status text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_status = to_status
        OR (from_status, to_status) IN (
            ('created', 'pending'),
            ('created', 'rejected'),
            ('created', 'expired'),
            ('created', 'revoked'),
            ('pending', 'active'),
            -- Rejected and expired are both endings and they are not the same
            -- ending: an owner asking why autopay never started needs the
            -- difference between "the bank said no" and "your tenant never
            -- answered".
            ('pending', 'rejected'),
            ('pending', 'expired'),
            ('pending', 'revoked'),
            ('active',  'paused'),
            ('active',  'revoked'),
            ('active',  'expired'),
            ('paused',  'active'),
            ('paused',  'revoked'),
            ('paused',  'expired'))
$$;

COMMENT ON FUNCTION mandate_transition_allowed(text, text) IS
    'ADR-0022. The mandate lifecycle. Terminal states absorb; from = to is a permitted no-op; active <-> paused is a cycle on purpose.';

CREATE OR REPLACE FUNCTION mandates_transition_is_legal() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT mandate_transition_allowed(OLD.status, NEW.status) THEN
        RAISE EXCEPTION 'mandate % cannot go from % to %: a delivery that arrived late or '
                        'out of order does not move an authority',
            OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS mandates_legal_transitions ON mandates;
CREATE TRIGGER mandates_legal_transitions
    BEFORE UPDATE ON mandates
    FOR EACH ROW EXECUTE FUNCTION mandates_transition_is_legal();

-- Stamp the ancillary parent, as payments and ledger_postings do, so the policy
-- never reads units.
CREATE OR REPLACE FUNCTION mandate_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS mandates_unit_parent ON mandates;
CREATE TRIGGER mandates_unit_parent
    BEFORE INSERT OR UPDATE OF unit_id ON mandates
    FOR EACH ROW EXECUTE FUNCTION mandate_unit_parent();

-- A debit is an ordinary payment that names the authority it ran under, and the
-- webhook inbox stays one table rather than two. Both columns are added here
-- rather than in their CREATE TABLE because both tables already exist.
DO $$
BEGIN
    ALTER TABLE payments       ADD COLUMN IF NOT EXISTS mandate_id uuid;
    ALTER TABLE payment_events ADD COLUMN IF NOT EXISTS mandate_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payments_mandate_fkey') THEN
        ALTER TABLE payments ADD CONSTRAINT payments_mandate_fkey
            FOREIGN KEY (mandate_id, tenant_id) REFERENCES mandates (id, tenant_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_events_mandate_fkey') THEN
        ALTER TABLE payment_events ADD CONSTRAINT payment_events_mandate_fkey
            FOREIGN KEY (mandate_id) REFERENCES mandates (id);
    END IF;

    -- A delivery is about a payment or about an authority, never both. A handler
    -- that set both attributed one event to two things.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_events_names_one_subject') THEN
        ALTER TABLE payment_events ADD CONSTRAINT payment_events_names_one_subject
            CHECK (payment_id IS NULL OR mandate_id IS NULL);
    END IF;

    -- The method vocabulary gains nach_debit: a debit under a NACH authority is
    -- neither a UPI method nor an offline one, and before this it had nowhere to
    -- go. Dropped and re-added rather than written inline, because an inline
    -- CHECK never reaches a database that already has the table.
    ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_method_check;
    ALTER TABLE payments ADD CONSTRAINT payments_method_check
        CHECK (method IN (
            'upi_collect', 'upi_intent', 'upi_autopay', 'nach_debit',
            'card', 'netbanking',
            'offline_cash', 'offline_cheque', 'offline_transfer'));
END
$$;

CREATE INDEX IF NOT EXISTS payments_mandate_idx
    ON payments (tenant_id, mandate_id) WHERE mandate_id IS NOT NULL;

ALTER TABLE mandates ENABLE ROW LEVEL SECURITY;
ALTER TABLE mandates FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and assertion 6 enforces — and this
-- table is the one that assertion was written for: a one-unit authority read at
-- property granularity would show a firm every mandate in the tower.
DROP POLICY IF EXISTS mandates_tenant_isolation ON mandates;
CREATE POLICY mandates_tenant_isolation ON mandates
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect'));

-- Revoked, not deleted. "There was never a mandate" is exactly what a disputed
-- debit needs the record to disprove.
DROP POLICY IF EXISTS mandates_no_delete ON mandates;
CREATE POLICY mandates_no_delete ON mandates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON mandates TO dwellm8_money;
GRANT SELECT ON mandates TO dwellm8_lease;

-- ===========================================================================
-- durable operations (ADR-0015)
-- ===========================================================================

-- Temporal is the executor. These tables are the record, and the distinction is
-- the whole of ADR-0015 §7.
--
-- A Temporal namespace keeps history for days — HomeChef's is 168 hours — and a
-- support call about a payout from last month has to have something to look at.
-- More than that: a workflow's history is a log of activity results, not an
-- account of what happened to somebody's money. So every durable operation records
-- its own progress here, in tables that outlive the namespace's retention and can
-- be read by the organisation whose money it is.
--
--   workflow_runs   one durable operation, and where it got to
--   workflow_steps  its steps and compensations, with the idempotency key each used
--
-- Both are ordinary tenant-scoped tables under ADR-0003, not platform-owned like
-- ADR-0012's. A platform-wide operation — the nightly reconciliation — carries the
-- platform organisation, exactly as ADR-0002 §1 requires of a platform-level event.
-- That keeps tenant_id NOT NULL and keeps these two off assertion 12's list, where
-- they would have needed the nullable-tenant argument for no benefit.

-- The platform organisation that a platform-wide run belongs to is seeded in the
-- data-migrations section, not here: it is a row, and a row written by this file
-- needs the row-level security window that section exists for.

CREATE TABLE IF NOT EXISTS workflow_runs (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),

    -- The operation, from the list ADR-0015 §2 derives from its rule. Not a CHECK
    -- against a fixed set: the list lives in Go, where each entry carries the
    -- clause of the rule that put it there, and the store contract test compares
    -- the two. A CHECK here would be a third copy.
    operation      text NOT NULL,
    task_queue     text NOT NULL,

    -- The deterministic Temporal id, `dwellm8:<operation>:<subject>`. UNIQUE, and
    -- that is the same guarantee ADR-0011 §2 gets from an index: starting the same
    -- operation for the same subject twice collides rather than producing a second
    -- workflow. A support agent constructs this from a payout id rather than
    -- searching for it, which is why it is derived and not generated.
    workflow_id    text NOT NULL,
    -- Temporal's own run id, for the operator who does have namespace access. It
    -- changes on a continue-as-new, so it is recorded and never relied on.
    temporal_run_id text,

    subject_kind   text NOT NULL,
    subject_id     text NOT NULL,
    -- ADR-0002's chain, so a support call can walk from a tenant's tap to the
    -- owner's payout.
    correlation_id text,

    state          text NOT NULL DEFAULT 'running' CHECK (state IN (
                       'running', 'completed', 'compensating', 'compensated', 'escalated')),

    -- ADR-0015 §4, made structural. Once the irreversible step has begun this is
    -- true forever, and the constraint below is what the flag is for.
    past_no_return boolean NOT NULL DEFAULT false,

    -- Where it got to, for the support call. The step name, not a percentage.
    last_step      text,
    failed_step    text,
    failure_reason text,

    -- Escalation is not failure: it is a run waiting for a person. It carries a
    -- reason for the same purpose ADR-0012's drift resolution does — a row somebody
    -- closed is not a row somebody explained.
    escalated_at     timestamptz,
    escalation_reason text,

    started_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    completed_at   timestamptz,

    -- workflow_runs_compensated_means_reversible — a run that passed the point of no
    -- return cannot have been compensated — is in the "load-bearing rules" block
    -- below, where it reaches a database that already has this table.
    CONSTRAINT workflow_runs_escalation_shape CHECK (
        (state = 'escalated') = (escalated_at IS NOT NULL)
        AND (state = 'escalated') = (escalation_reason IS NOT NULL)),
    CONSTRAINT workflow_runs_completion_shape CHECK (
        (state IN ('running', 'compensating')) = (completed_at IS NULL))
);

COMMENT ON TABLE workflow_runs IS
    'ADR-0015 §7. One durable operation. Temporal is the executor; this is the record, because a namespace keeps history for days and a dispute lasts longer.';
COMMENT ON COLUMN workflow_runs.past_no_return IS
    'True once the irreversible step has begun. A run with this set may not be recorded as compensated — nothing after that point can be undone.';

-- The idempotency of starting. A producer-side retry — a double-tapped button, a
-- redelivered event, a replayed queue — finds this row rather than making a second.
CREATE UNIQUE INDEX IF NOT EXISTS workflow_runs_workflow_idx
    ON workflow_runs (workflow_id);
-- "What is this payout doing" — the support call, from the subject rather than the
-- workflow id.
CREATE INDEX IF NOT EXISTS workflow_runs_subject_idx
    ON workflow_runs (tenant_id, subject_kind, subject_id);
-- "What needs a person" — the escalation queue, and the only screen in this
-- subsystem somebody is meant to be looking at.
CREATE INDEX IF NOT EXISTS workflow_runs_escalated_idx
    ON workflow_runs (operation, escalated_at) WHERE state = 'escalated';
-- "What is still in flight, and since when" — the stuck-workflow sweep. A run that
-- has been running longer than its operation's budget is the edge case ADR-0015's
-- story names, and this is the index that finds it.
CREATE INDEX IF NOT EXISTS workflow_runs_inflight_idx
    ON workflow_runs (operation, started_at) WHERE state IN ('running', 'compensating');
CREATE INDEX IF NOT EXISTS workflow_runs_correlation_idx
    ON workflow_runs (correlation_id) WHERE correlation_id IS NOT NULL;

-- The state machine, in the schema as well as in Go, for the reason ADR-0011 §3
-- gives: an out-of-order update must be refused even on a path that never went
-- through Go, and the contract test evaluates this function over every ordered
-- pair.
--
-- from = to is permitted and is the point: a step recorded twice asks for the state
-- the run is already in.
CREATE OR REPLACE FUNCTION workflow_transition_allowed(from_state text, to_state text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_state = to_state
        OR (from_state, to_state) IN (
            ('running',      'completed'),
            ('running',      'compensating'),
            -- Straight to escalated: a step that failed after the point of no
            -- return never compensates, so it never passes through compensating.
            ('running',      'escalated'),
            ('compensating', 'compensated'),
            -- A compensation that could not be applied. The worst state in the
            -- system, and the only one that pages somebody.
            ('compensating', 'escalated'))
$$;

COMMENT ON FUNCTION workflow_transition_allowed(text, text) IS
    'ADR-0015 §5. Forward-only. Terminal states absorb, and from = to is a permitted no-op so a step recorded twice needs no special case.';

CREATE OR REPLACE FUNCTION workflow_runs_forward_only() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT workflow_transition_allowed(OLD.state, NEW.state) THEN
        RAISE EXCEPTION 'workflow run % cannot go from % to %',
            OLD.workflow_id, OLD.state, NEW.state USING ERRCODE = 'check_violation';
    END IF;
    -- Monotonic. A run that has passed the point of no return has passed it
    -- forever, and clearing the flag would let the constraint above be satisfied
    -- by editing the evidence rather than by the world being reversible.
    IF OLD.past_no_return AND NOT NEW.past_no_return THEN
        RAISE EXCEPTION 'workflow run % cannot un-pass the point of no return: the irreversible step '
                        'either began or it did not', OLD.workflow_id
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS workflow_runs_forward ON workflow_runs;
CREATE TRIGGER workflow_runs_forward
    BEFORE UPDATE ON workflow_runs
    FOR EACH ROW EXECUTE FUNCTION workflow_runs_forward_only();

-- One row per step per direction, carrying the idempotency key it presented.
--
-- This is the trail that answers "was the tenant charged twice" after the Temporal
-- history has expired. The key is stored rather than recomputed because the answer
-- has to be what was actually sent, not what today's code would send.
CREATE TABLE IF NOT EXISTS workflow_steps (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid NOT NULL REFERENCES workflow_runs(id),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    seq             int  NOT NULL CHECK (seq >= 0),
    step            text NOT NULL,
    -- 'do' or 'undo'. A step and its compensation are two rows, so the trail reads
    -- as what happened rather than as a final state.
    direction       text NOT NULL CHECK (direction IN ('do', 'undo')),

    idempotency_key text NOT NULL,
    outcome         text NOT NULL DEFAULT 'running'
                    CHECK (outcome IN ('running', 'succeeded', 'failed')),
    -- Attempts, because "it eventually worked" and "it worked first time" are
    -- different facts about a provider, and only one of them is worth an alert.
    attempts        int  NOT NULL DEFAULT 1 CHECK (attempts >= 1),
    error           text,

    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,

    CONSTRAINT workflow_steps_outcome_shape CHECK (
        (outcome = 'running') = (finished_at IS NULL)),
    CONSTRAINT workflow_steps_error_shape CHECK (
        outcome = 'failed' OR error IS NULL)
);

COMMENT ON TABLE workflow_steps IS
    'ADR-0015 §7. Each step and compensation, with the idempotency key it presented. Outlives Temporal''s retention, which is what a dispute needs.';

-- A retry updates its row rather than adding one. Without this, an activity retried
-- forty times over a day reads as forty steps and the trail becomes unreadable
-- exactly when somebody needs it.
CREATE UNIQUE INDEX IF NOT EXISTS workflow_steps_unique
    ON workflow_steps (run_id, step, direction);
CREATE INDEX IF NOT EXISTS workflow_steps_run_idx
    ON workflow_steps (run_id, seq);
-- "Which step presented this key" — the question a provider's support desk asks.
CREATE INDEX IF NOT EXISTS workflow_steps_key_idx
    ON workflow_steps (idempotency_key);

ALTER TABLE workflow_runs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_runs  FORCE  ROW LEVEL SECURITY;
ALTER TABLE workflow_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_steps FORCE  ROW LEVEL SECURITY;

-- Ordinary ADR-0003 isolation, with no delegated branch.
--
-- The omission is deliberate and is worth stating: a run carries no property_id, so
-- there is nothing for is_delegated_unit() to be judged against, and adding a
-- grant-level branch would hand a management firm every durable operation of the
-- owner that granted it — including payouts to that owner's bank account, which is
-- not the firm's business. A firm sees the payments and the drift for the units it
-- manages; how the money was moved is between the owner and the platform.
DROP POLICY IF EXISTS workflow_runs_tenant_isolation ON workflow_runs;
CREATE POLICY workflow_runs_tenant_isolation ON workflow_runs
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS workflow_steps_tenant_isolation ON workflow_steps;
CREATE POLICY workflow_steps_tenant_isolation ON workflow_steps
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A run that escalated and a step that failed are the
-- evidence in the dispute that follows, and the reason this record exists rather
-- than relying on Temporal's is precisely that it has to survive.
DROP POLICY IF EXISTS workflow_runs_no_delete ON workflow_runs;
CREATE POLICY workflow_runs_no_delete ON workflow_runs AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS workflow_steps_no_delete ON workflow_steps;
CREATE POLICY workflow_steps_no_delete ON workflow_steps AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Money owns durable operations, because every operation on the list is a money or
-- document operation. Every other module reads: a lease screen shows whether the
-- deposit refund is in flight, and a support console shows why it is not.
GRANT SELECT, INSERT, UPDATE ON workflow_runs, workflow_steps TO dwellm8_money;
GRANT SELECT ON workflow_runs, workflow_steps TO dwellm8_lease, dwellm8_property,
    dwellm8_identity, dwellm8_notify;

-- ===========================================================================
-- public listings and prospects (ADR-0019)
-- ===========================================================================

-- The listing site is the only surface used by people who are not customers and may
-- never sign in. It is therefore the first read path in this schema that does not fail
-- closed, and that is the decision this section is about.
--
-- ADR-0003's rule is that current_tenant_id() is NULL when unset, so every policy denies
-- and an unscoped session sees nothing. An anonymous visitor is exactly an unscoped
-- session, so a public listing needs a branch that does not depend on a tenant — and
-- every such branch is a hole in the isolation model unless it is narrow enough to
-- reason about.
--
-- It is narrowed three ways, and all three matter:
--
--   1. One table. Only `listings` has a public branch, and assertion 17 refuses one
--      anywhere else. A future table that quietly becomes world-readable is the failure
--      this section is most likely to cause.
--   2. The row opts in. `published_at IS NOT NULL AND state = 'live'` — publication is an
--      act by the owner, not a default, and unpublishing removes the row from the public
--      view immediately.
--   3. The columns are the listing's own. A listing carries what a stranger may see: the
--      locality, the rent, the photographs. property_id and unit_id are present because
--      the product needs them, and they lead nowhere — every other table still denies an
--      unscoped session, so a uuid is opaque.

CREATE TABLE IF NOT EXISTS listings (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    unit_parent_id uuid,

    state         text NOT NULL DEFAULT 'draft' CHECK (state IN (
                      'draft', 'live', 'paused', 'let', 'withdrawn')),
    -- Publication is an act, and an unpublished listing is invisible to a stranger even
    -- if its state says live. Two columns rather than one because "the owner published
    -- this" and "it is currently being advertised" are different facts: pausing keeps the
    -- publication history.
    published_at  timestamptz,

    -- What a stranger may see. Denormalised on purpose: an anonymous reader must not need
    -- to join to properties or units, because those deny.
    headline      text NOT NULL,
    locality      text NOT NULL,
    city          text NOT NULL,
    state_code    char(2) NOT NULL,
    -- Deliberately not the full address. A listing shows a locality until an inspection is
    -- booked, which is the industry norm and is also what stops the site being a map of
    -- which flats are empty.
    rent_minor    bigint NOT NULL CHECK (rent_minor > 0),
    deposit_minor bigint NOT NULL DEFAULT 0 CHECK (deposit_minor >= 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    bedrooms      int CHECK (bedrooms IS NULL OR bedrooms BETWEEN 0 AND 20),
    carpet_area_sqft numeric(10,2) CHECK (carpet_area_sqft IS NULL OR carpet_area_sqft > 0),
    available_from date,

    -- What a search engine may index. Robots are told no for anything but a live,
    -- published listing, and the column exists so that decision is data rather than a
    -- template condition somebody edits.
    indexable     boolean NOT NULL DEFAULT true,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT listings_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT listings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT listings_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT listings_amount_representable CHECK (rent_minor <= 9007199254740991),
    -- A live listing is published. The reverse is not required: a paused listing keeps its
    -- publication date, which is what makes pausing different from withdrawing.
    CONSTRAINT listings_live_is_published CHECK (state <> 'live' OR published_at IS NOT NULL)
);

COMMENT ON TABLE listings IS
    'ADR-0019. The only publicly readable table in this schema. A row is visible to a stranger only when its owner published it and it is live.';

-- One live listing per unit. Two adverts for the same flat at different rents is the
-- thing a prospect screenshots.
CREATE UNIQUE INDEX IF NOT EXISTS listings_one_live_per_unit
    ON listings (tenant_id, unit_id) WHERE state IN ('live', 'paused');
-- The search query: live listings in a city, by rent.
CREATE INDEX IF NOT EXISTS listings_search_idx
    ON listings (city, locality, rent_minor) WHERE state = 'live' AND published_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS listings_owner_idx ON listings (tenant_id, state);

-- A prospect: somebody who is not a customer and may never be one.
--
-- Identified the way ADR-0021 identifies a demo visitor, and for the same reason — an
-- opaque token, stored hashed, because a database copy must not hand out somebody's
-- browsing history. Shortlisting is anonymous, so the token is all there is until the
-- verification point.
CREATE TABLE IF NOT EXISTS prospects (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- No tenant_id. A prospect belongs to nobody: they are browsing the whole site, and
    -- attributing them to the first owner whose listing they opened would be wrong and
    -- would leak their interest in the others. Assertion 12 requires this table's writes
    -- to be platform-only, which they are.
    token_hash      bytea NOT NULL UNIQUE CHECK (length(token_hash) = 32),

    -- The verification point. NULL until the prospect books an inspection or makes an
    -- enquiry, which is the moment a phone number is required.
    verified_at     timestamptz,
    -- The masked-calling provider's reference for this person, and the masked form for
    -- display. The raw number is never here: the provider holds it, we hold a token, and
    -- neither party's number can leak from this database because it is not in it.
    contact_ref     text,
    contact_masked  text CHECK (contact_masked IS NULL OR contact_masked ~ '^[X*]{6}[0-9]{4}$'),

    -- Where they end up, if they sign up. The edge case the story names: a prospect who
    -- signs up must not lose their shortlist or enquiry history, so the prospect row is
    -- kept and pointed at the party rather than replaced.
    converted_party_id uuid,
    converted_at    timestamptz,

    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),

    -- Verification is a package: the timestamp, the provider reference and the masked
    -- form arrive together or not at all. A half-verified prospect is one that can be
    -- called and not displayed, or displayed and not called.
    CONSTRAINT prospects_verification_shape CHECK (
        (verified_at IS NULL) = (contact_ref IS NULL)
        AND (verified_at IS NULL) = (contact_masked IS NULL)),
    CONSTRAINT prospects_conversion_shape CHECK (
        (converted_at IS NULL) = (converted_party_id IS NULL)),
    -- Signing up requires having verified: an account is built on a verified contact.
    CONSTRAINT prospects_conversion_needs_verification CHECK (
        converted_at IS NULL OR verified_at IS NOT NULL)
);

COMMENT ON TABLE prospects IS
    'ADR-0019. Somebody browsing who may never sign in. No raw phone number: the masked-calling provider holds it and this holds a reference.';

CREATE INDEX IF NOT EXISTS prospects_converted_idx
    ON prospects (converted_party_id) WHERE converted_party_id IS NOT NULL;

-- The shortlist, once a prospect has a record. Before that it is local state in the
-- browser, which is what makes browsing genuinely anonymous.
CREATE TABLE IF NOT EXISTS prospect_shortlist (
    prospect_id   uuid NOT NULL REFERENCES prospects(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),
    added_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (prospect_id, listing_id)
);

COMMENT ON TABLE prospect_shortlist IS
    'ADR-0019. Survives sign-up, because the prospect row is kept and pointed at the party rather than replaced.';

-- An enquiry or an inspection booking: the point at which a prospect becomes visible to
-- an owner.
CREATE TABLE IF NOT EXISTS enquiries (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The owner's organisation. An enquiry is the first row in this funnel that belongs
    -- to somebody, which is why it is the first one with ordinary tenancy.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),
    prospect_id   uuid NOT NULL REFERENCES prospects(id),

    kind          text NOT NULL CHECK (kind IN ('enquiry', 'inspection', 'callback')),
    state         text NOT NULL DEFAULT 'new' CHECK (state IN (
                      'new', 'owner_responded', 'scheduled', 'completed', 'closed', 'spam')),
    message       text,
    scheduled_for timestamptz,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    -- An inspection has a time. An enquiry does not.
    CONSTRAINT enquiries_inspection_is_scheduled CHECK (
        kind <> 'inspection' OR state <> 'scheduled' OR scheduled_for IS NOT NULL)
);

COMMENT ON TABLE enquiries IS
    'ADR-0019. The verification point: making one requires a verified prospect, enforced by a trigger.';

CREATE INDEX IF NOT EXISTS enquiries_listing_idx ON enquiries (listing_id, created_at);
CREATE INDEX IF NOT EXISTS enquiries_owner_idx ON enquiries (tenant_id, state, created_at);
CREATE INDEX IF NOT EXISTS enquiries_prospect_idx ON enquiries (prospect_id, created_at);

-- The verification point, enforced rather than documented. Browsing and shortlisting are
-- anonymous; making contact is not.
CREATE OR REPLACE FUNCTION enquiries_need_a_verified_prospect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prospects p
                    WHERE p.id = NEW.prospect_id AND p.verified_at IS NOT NULL) THEN
        RAISE EXCEPTION 'enquiry % is from an unverified prospect: browsing and shortlisting need '
                        'no account, and making contact needs a verified phone number — which is '
                        'the only thing standing between an owner and a thousand fake enquiries',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS enquiries_verification_point ON enquiries;
CREATE TRIGGER enquiries_verification_point
    BEFORE INSERT ON enquiries
    FOR EACH ROW EXECUTE FUNCTION enquiries_need_a_verified_prospect();

-- Contact protection. Neither number is exposed, ever, and the bridge is what connects
-- them.
--
-- The story's edge case is that neither party's number may be exposed before both have
-- engaged. This goes further, because it is cheaper to go further: neither number is in
-- this database at all. The masked-calling provider holds both and this holds two
-- references, so there is nothing here to expose at any point.
--
-- What the constraint below enforces is the timing: a bridge exists only once the owner
-- has responded, so a prospect cannot dial an owner off the back of an unanswered enquiry.
CREATE TABLE IF NOT EXISTS contact_bridges (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    enquiry_id    uuid NOT NULL UNIQUE REFERENCES enquiries(id),

    -- The provider's handle for the connection. Never a number.
    provider      text NOT NULL,
    provider_ref  text NOT NULL,
    -- What each side sees, which is the provider's proxy number.
    proxy_masked  text NOT NULL CHECK (proxy_masked ~ '^[X*]{6}[0-9]{4}$'),

    opened_at     timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,

    CONSTRAINT contact_bridges_window CHECK (expires_at > opened_at)
);

COMMENT ON TABLE contact_bridges IS
    'ADR-0019. A masked connection between an owner and a prospect. Neither number is in this database — the provider holds both.';

CREATE INDEX IF NOT EXISTS contact_bridges_expiry_idx ON contact_bridges (expires_at);

-- Both sides must have engaged. The prospect engaged by making the enquiry; the owner
-- engages by responding, and until they do there is nobody to connect them to.
CREATE OR REPLACE FUNCTION contact_bridges_need_mutual_engagement() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    enquiry_state text;
BEGIN
    SELECT state INTO enquiry_state FROM enquiries WHERE id = NEW.enquiry_id;
    IF enquiry_state IS NULL OR enquiry_state IN ('new', 'spam', 'closed') THEN
        RAISE EXCEPTION 'contact bridge % is for an enquiry in state %: a connection is opened once '
                        'both sides have engaged, and an unanswered enquiry is one side',
            NEW.id, coalesce(enquiry_state, 'missing') USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS contact_bridges_mutual ON contact_bridges;
CREATE TRIGGER contact_bridges_mutual
    BEFORE INSERT ON contact_bridges
    FOR EACH ROW EXECUTE FUNCTION contact_bridges_need_mutual_engagement();

ALTER TABLE listings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE listings           FORCE  ROW LEVEL SECURITY;
ALTER TABLE prospects          ENABLE ROW LEVEL SECURITY;
ALTER TABLE prospects          FORCE  ROW LEVEL SECURITY;
ALTER TABLE prospect_shortlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE prospect_shortlist FORCE  ROW LEVEL SECURITY;
ALTER TABLE enquiries          ENABLE ROW LEVEL SECURITY;
ALTER TABLE enquiries          FORCE  ROW LEVEL SECURITY;
ALTER TABLE contact_bridges    ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_bridges    FORCE  ROW LEVEL SECURITY;

-- The one public read branch in this schema.
--
-- An unscoped session — which is what an anonymous visitor is — matches only the third
-- clause, so it sees live published listings and nothing else. The owner sees their own
-- whatever the state, and a delegated firm sees the ones for units it manages, because
-- advertising a flat is squarely what a management grant is for.
--
-- WITH CHECK has no public branch: publishing is a write, and a write always needs a
-- tenant. That asymmetry is the point — the hole is read-only by construction.
DROP POLICY IF EXISTS listings_public_read ON listings;
CREATE POLICY listings_public_read ON listings
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.read')
           OR (state = 'live' AND published_at IS NOT NULL))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.write'));

-- A prospect belongs to nobody, so the row is the platform's. The site reads a prospect
-- by presenting its token, which the application resolves — never by scanning the table.
DROP POLICY IF EXISTS prospects_platform_only ON prospects;
CREATE POLICY prospects_platform_only ON prospects
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS prospect_shortlist_platform_only ON prospect_shortlist;
CREATE POLICY prospect_shortlist_platform_only ON prospect_shortlist
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- An enquiry is the first row in this funnel that belongs to somebody: the owner whose
-- listing it is. Ordinary tenancy, and nothing else.
--
-- The first version had a delegated branch written as
-- `EXISTS (SELECT 1 FROM listings l WHERE l.id = listing_id)`, on the reasoning that a
-- firm which can see the listing may answer its enquiries. That was a leak, and the
-- isolation test found it: **listings is publicly readable**, so the subquery was true for
-- everybody, and an anonymous visitor could read every enquiry on every published listing
-- — names, messages and all.
--
-- The lesson generalises and is why it is written here rather than fixed quietly: once one
-- table is world-readable, any policy that reaches it through a subquery inherits that.
-- Assertion 17 cannot see this — the policy does mention current_tenant_id(), so it looks
-- correct — and a delegated branch on this table has to be written against the property,
-- which means denormalising it here. That is a later story; until then a management firm
-- reads enquiries through the owner's session.
DROP POLICY IF EXISTS enquiries_tenant_isolation ON enquiries;
CREATE POLICY enquiries_tenant_isolation ON enquiries
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS contact_bridges_tenant_isolation ON contact_bridges;
CREATE POLICY contact_bridges_tenant_isolation ON contact_bridges
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A withdrawn listing is the record of what was advertised at what rent, which is what a
-- rent-control or misrepresentation complaint turns on. An enquiry likewise.
DROP POLICY IF EXISTS listings_no_delete ON listings;
CREATE POLICY listings_no_delete ON listings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS enquiries_no_delete ON enquiries;
CREATE POLICY enquiries_no_delete ON enquiries AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS contact_bridges_no_delete ON contact_bridges;
CREATE POLICY contact_bridges_no_delete ON contact_bridges AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON listings TO dwellm8_property, dwellm8_discovery;
GRANT SELECT, INSERT, UPDATE ON prospects, prospect_shortlist, enquiries, contact_bridges
    TO dwellm8_discovery;
GRANT SELECT ON listings TO dwellm8_lease, dwellm8_money, dwellm8_identity, dwellm8_notify;
GRANT SELECT, UPDATE ON enquiries TO dwellm8_property;
-- The purge grant for these tables is with the others, after dwellm8_purge is created:
-- this file is applied top to bottom and the role does not exist yet here.

-- ===========================================================================
-- demo sandbox (ADR-0021)
-- ===========================================================================

-- The sandbox is an unauthenticated, write-capable surface exposed to the whole internet.
-- Anyone can start a demo with no account, so session identity, isolation, expiry and
-- cost bounds are decided here rather than discovered.
--
-- organisations.is_sandbox has existed since ADR-0003 carrying a promise nothing kept:
-- "Nothing in it may ever cause a side effect: no money moves, no message is sent." This
-- section is what makes that true, and the enforcement is in two halves that hold each
-- other up — see sandbox_purge_permitted() above.

CREATE TABLE IF NOT EXISTS demo_sessions (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The ephemeral organisation this session owns. One per session, never shared: two
    -- visitors editing the same demo is the failure that makes a sandbox worthless.
    tenant_id      uuid NOT NULL UNIQUE REFERENCES organisations(id),

    -- The opaque token, hashed. The token itself is never stored, for the same reason
    -- ADR-0013 stores no full identifier: a database copy would otherwise hand out live
    -- sessions. sha256 rather than a slow hash on purpose — this is a 256-bit random
    -- value, so there is no dictionary to defend against and a slow hash would only make
    -- every request slower.
    token_hash     bytea NOT NULL UNIQUE CHECK (length(token_hash) = 32),

    -- Sliding, so a visitor returning after several days resumes rather than silently
    -- receiving a fresh sandbox with their work gone.
    expires_at     timestamptz NOT NULL,
    -- Absolute. A sliding window with no ceiling is a session that never expires, and
    -- the storage cost of one that never expires is unbounded.
    hard_expires_at timestamptz NOT NULL,

    -- Which template seeded it, so a template change does not silently mean two visitors
    -- saw different products.
    template       text NOT NULL,

    -- Coarse, for the abuse case. Not an address: a /24 or a hashed prefix is enough to
    -- rate-limit on and does not build a log of who visited.
    origin_bucket  text,

    created_at     timestamptz NOT NULL DEFAULT now(),
    last_seen_at   timestamptz NOT NULL DEFAULT now(),
    converted_at   timestamptz,

    CONSTRAINT demo_sessions_window CHECK (
        expires_at > created_at AND hard_expires_at >= expires_at),
    -- A sliding window may not slide past the ceiling, which is what makes the ceiling one.
    CONSTRAINT demo_sessions_ceiling CHECK (hard_expires_at > created_at)
);

COMMENT ON TABLE demo_sessions IS
    'ADR-0021. One ephemeral organisation per visitor. The token is stored hashed; the sliding window resumes, the hard ceiling ends.';

CREATE INDEX IF NOT EXISTS demo_sessions_expiry_idx ON demo_sessions (expires_at);
CREATE INDEX IF NOT EXISTS demo_sessions_origin_idx
    ON demo_sessions (origin_bucket, created_at) WHERE origin_bucket IS NOT NULL;

-- The organisation a demo session points at must actually be a sandbox, or the session
-- is a way to reach a real organisation without an account.
CREATE OR REPLACE FUNCTION demo_sessions_point_at_a_sandbox() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT is_sandbox_tenant(NEW.tenant_id) THEN
        RAISE EXCEPTION 'demo session % points at organisation %, which is not a sandbox — an '
                        'unauthenticated session must not reach a real organisation',
            NEW.id, NEW.tenant_id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS demo_sessions_sandbox_only ON demo_sessions;
CREATE TRIGGER demo_sessions_sandbox_only
    BEFORE INSERT OR UPDATE OF tenant_id ON demo_sessions
    FOR EACH ROW EXECUTE FUNCTION demo_sessions_point_at_a_sandbox();

-- ADR-0021 §3. The side-effect ban, made structural for the one table that can move real
-- money.
--
-- A demo has payments in it — it is a demo of a rent platform — so the rule is not "no
-- payments" but "no payment through a real provider". A sandbox payment names the sandbox
-- adapter and nothing else, so a demo cannot create an order at Razorpay however the code
-- is wired.
--
-- This is the half that makes the purge safe: nothing real originates in a sandbox, so
-- nothing real is lost when one is dropped.
CREATE OR REPLACE FUNCTION payments_sandbox_has_no_real_provider() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF is_sandbox_tenant(NEW.tenant_id) AND NEW.provider <> 'sandbox' THEN
        RAISE EXCEPTION 'payment % is in a sandbox organisation and names provider %: a demo may '
                        'not reach a real payment provider, and the sandbox being purgeable '
                        'depends on it', NEW.id, NEW.provider
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_sandbox_provider ON payments;
CREATE TRIGGER payments_sandbox_provider
    BEFORE INSERT OR UPDATE OF provider, tenant_id ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_sandbox_has_no_real_provider();

-- And the same for a durable operation: a sandbox may not run one that reaches outside.
-- recon.day is platform-wide and never sandbox; everything else on ADR-0015's list either
-- moves money or files a document, so none of them may originate in a demo.
CREATE OR REPLACE FUNCTION workflow_runs_sandbox_has_no_external_effect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF is_sandbox_tenant(NEW.tenant_id) THEN
        RAISE EXCEPTION 'workflow run % is in a sandbox organisation and runs %: every durable '
                        'operation reaches a provider, a bank or a government gateway, and a demo '
                        'may reach none of them', NEW.id, NEW.operation
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS workflow_runs_sandbox_ban ON workflow_runs;
CREATE TRIGGER workflow_runs_sandbox_ban
    BEFORE INSERT ON workflow_runs
    FOR EACH ROW EXECUTE FUNCTION workflow_runs_sandbox_has_no_external_effect();

-- ADR-0021 §5. The cost bound, as a hard cap on live sandboxes.
--
-- "The cost stays within the stated cap" is only true if something states it and
-- something enforces it. Rate limiting lives at the edge, where it belongs, and it fails
-- open under a distributed attack; this is the floor beneath it, and it fails closed.
--
-- The cap is deliberately in the schema rather than in configuration: a number an
-- operator can raise under pressure at 3am is a number that gets raised.
CREATE OR REPLACE FUNCTION demo_sessions_within_the_cap() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    live int;
    cap  CONSTANT int := 500;
BEGIN
    SELECT count(*) INTO live FROM demo_sessions WHERE expires_at > now();
    IF live >= cap THEN
        RAISE EXCEPTION 'the demo sandbox is at its cap of % live sessions: creation is bounded so '
                        'a script cannot make the storage cost unbounded, and existing sessions are '
                        'unaffected', cap
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS demo_sessions_cap ON demo_sessions;
CREATE TRIGGER demo_sessions_cap
    BEFORE INSERT ON demo_sessions
    FOR EACH ROW EXECUTE FUNCTION demo_sessions_within_the_cap();

ALTER TABLE demo_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE demo_sessions FORCE  ROW LEVEL SECURITY;

-- The session row is the platform's: it is created before there is a tenant to scope to,
-- and it holds the token hash. A demo session reads its own *organisation's* data through
-- ordinary tenancy, exactly as a real one does — which is the point of §6. It never reads
-- this table.
DROP POLICY IF EXISTS demo_sessions_platform_only ON demo_sessions;
CREATE POLICY demo_sessions_platform_only ON demo_sessions
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Deletable, unlike everything else in this schema, and by the same rule: it is the
-- sandbox's own record.
DROP POLICY IF EXISTS demo_sessions_purgeable ON demo_sessions;
CREATE POLICY demo_sessions_purgeable ON demo_sessions AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON demo_sessions TO dwellm8_identity;

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

-- ADR-0021 §4. The demo cleanup job's role.
--
-- Separate from dwellm8_platform on purpose. This schema protects its history with two
-- locks — the privilege is revoked *and* a RESTRICTIVE policy refuses the delete — and
-- granting DELETE back to the platform role would remove one of them for onboarding,
-- support and reporting alike. A third role keeps both locks intact everywhere except
-- the one job that needs them open, and that job's policy still only reaches a sandbox.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_purge') THEN
        CREATE ROLE dwellm8_purge LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_purge;
GRANT USAGE ON SCHEMA public TO dwellm8_purge;
GRANT dwellm8_app TO dwellm8_purge;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_api, dwellm8_platform;
GRANT USAGE ON SCHEMA public TO dwellm8_api, dwellm8_platform;
GRANT dwellm8_app TO dwellm8_api, dwellm8_platform;

-- Deliberately NOT granted here: membership of dwellm8_platform for the table
-- owner.
--
-- It is tempting, because a data migration in this file cannot otherwise touch a
-- row (see the migrations section). But the bootstrap job and — today — the API
-- both connect as dwellm8, so making the owner a member of dwellm8_platform
-- would make every request platform-exempt and switch tenant isolation off for
-- the whole application, silently, with every policy still reading correctly.
--
-- Verified against the cluster rather than assumed: the API deployment's
-- DATABASE_URL uses the CNPG app credentials, whose username is dwellm8. Until
-- the API connects as dwellm8_api, the owner must stay unexempted, and the
-- migrations section pays for that with an explicit, transaction-scoped window
-- instead.

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
GRANT EXECUTE ON FUNCTION current_active_grant(uuid, text) TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_delegated_unit(uuid, uuid, uuid, uuid, text) TO dwellm8_app;

-- After the blanket grant above, not before it, or it would hand DELETE straight
-- back. A grant is history the moment it exists: the RESTRICTIVE policy refuses
-- the delete, and withholding the privilege means a session never reaches the
-- policy at all. Two locks, because the record of who was allowed to touch an
-- owner's property is exactly what a bad actor would want gone.
REVOKE DELETE ON delegation_grants, delegation_grant_scopes FROM dwellm8_app;

-- And the tree, for the reason written above its RESTRICTIVE policies: a
-- deleted unit orphans the money posted against it. ADR-0009.
REVOKE DELETE ON properties, blocks, units FROM dwellm8_app;

-- The ledger is append-only, and UPDATE is revoked as well as DELETE — which is
-- the difference between this table and every other one in the file. A
-- corrected amount that leaves no trace is indistinguishable from a corrected
-- amount that was theft. ADR-0006 §3: the only correction is a reversing entry.
REVOKE UPDATE, DELETE ON journal_entries, ledger_postings FROM dwellm8_app;

-- A payment does have a lifecycle, so UPDATE stays; DELETE does not. An
-- abandoned collection is the record an owner asks for when a tenant says they
-- paid, and a webhook delivery is evidence whether or not it was ever acted on.
-- ADR-0011 §4.
REVOKE DELETE ON payments, payment_events FROM dwellm8_app;

-- And the reconciliation tables. A settlement file that was ingested and a
-- disagreement that was found are the evidence in the dispute that comes later,
-- and a batch's totals are the provider's statement rather than our note of it —
-- so the batch loses UPDATE as well. ADR-0012 §6.
REVOKE DELETE ON settlement_batches, settlement_lines, settlement_drift,
    reconciliation_runs FROM dwellm8_app;
REVOKE UPDATE ON settlement_batches FROM dwellm8_app;

-- ADR-0015. A run that escalated and a step that failed are the evidence in the
-- dispute that follows, and the reason this record exists rather than relying on
-- Temporal's is precisely that it has to survive longer than a retention window.
REVOKE DELETE ON workflow_runs, workflow_steps FROM dwellm8_app;

-- The ageing view, for the reason ledger_balances is revoked below: GRANT ... ON
-- ALL TABLES covers views, and a privilege list that claims an aggregate can be
-- written is a privilege list nobody can review.
REVOKE INSERT, UPDATE, DELETE ON settlement_drift_ageing FROM dwellm8_app;

-- The chart of accounts and the posting templates are the rule, not the data.
-- The application reads them; this file is the only thing that writes them, so a
-- request cannot invent an account and post against it.
REVOKE INSERT, UPDATE, DELETE ON ledger_accounts, posting_templates,
    posting_template_lines FROM dwellm8_app;

-- And the statutory rules, for the same reason one step further out: a request
-- that can write a TDS rate is a request that can decide its own tax. ADR-0023 §2
-- — a rate change is a reviewed commit to this file, and assertion 18 fails the
-- bootstrap if the privilege ever comes back.
REVOKE INSERT, UPDATE, DELETE ON statutory_rules, statutory_rule_slabs
    FROM dwellm8_app;
REVOKE INSERT, UPDATE, DELETE ON statutory_rules_review_due FROM dwellm8_app;

-- GRANT ... ON ALL TABLES covers views too, so the blanket grant above handed
-- out INSERT, UPDATE and DELETE on a balances view. PostgreSQL would refuse all
-- three anyway — an aggregate view is not updatable — but a privilege list that
-- claims a balance can be written is a privilege list nobody can review.
REVOKE INSERT, UPDATE, DELETE ON ledger_balances FROM dwellm8_app;

-- identity_principals holds a verified phone number and email for every person
-- who has ever signed in, and it has no tenant_id — so row-level security has
-- nothing to scope it by, and the blanket GRANT above would let any module read
-- every principal on the platform.
--
-- The privilege is the boundary here rather than a policy: only the identity
-- module needs this table, and it holds its grant directly. ADR-0027 §6.
REVOKE ALL ON identity_principals FROM dwellm8_app;


-- ADR-0021 §4. And DELETE back, to the purge role only.
--
-- After every REVOKE above, so this is the last word. Every one of these tables refuses
-- the delete in its policy unless the row belongs to a sandbox, so the privilege alone
-- reaches nothing — but without the privilege the policy is never consulted, which is
-- what the two-lock design means and why this grant has to be explicit and narrow.
GRANT DELETE ON properties, blocks, units,
                delegation_grants, delegation_grant_scopes,
                journal_entries, ledger_postings,
                payments, payment_events,
                settlement_lines, settlement_drift,
                leases, lease_parties, rent_schedule,
                property_ownership,
                workflow_runs, workflow_steps,
                kyc_verifications, kyc_access_log,
                listings, enquiries, contact_bridges, prospects, prospect_shortlist,
                audit_events, organisations, demo_sessions
    TO dwellm8_purge;

-- No ALTER ROLE ... NOBYPASSRLS here: changing the attribute at all requires
-- superuser, which this job does not have and should not want. The roles are
-- created without it, and the guard that matters is the assertion in
-- 003_tenancy_assertions.sql, which fails the bootstrap if it ever appears.

-- ===========================================================================
-- data migrations
-- ===========================================================================

-- Statements that touch rows rather than definitions.
--
-- A data migration in this file has a problem that cost a debugging session and
-- is invisible in review: **it cannot see any row**. The bootstrap connects as
-- the table owner, FORCE row level security applies to the owner (ADR-0003 §2 is
-- entirely about that), and the job sets no app.tenant_id because it is not a
-- request. So every policy evaluates to false and an UPDATE here matches nothing.
-- It does not error. It reports UPDATE 0 and the file carries on.
--
-- Measured: replaying ADR-0009 onto a database that already held a grant scope,
-- the backfill silently touched zero rows and the CHECK constraint two statements
-- later failed on the row the backfill was supposed to have fixed — "check
-- constraint delegation_grant_scopes_property_shape ... is violated by some row".
--
-- So each migration opens the smallest possible window: NO FORCE, the statement,
-- FORCE again, inside one DO block and therefore one transaction. If anything
-- raises, the transaction rolls back and FORCE is restored with it; the ALTER
-- takes an ACCESS EXCLUSIVE lock, so no other session can read the table
-- unforced. The alternative — granting the owner membership of dwellm8_platform —
-- would exempt the API too, because it connects as the same role.
--
-- Assertion 1 at the foot of this file is what catches a window left open.

-- ADR-0009. Resolve grant scopes written before scope_property_id existed.
-- A property scope resolves to itself. A unit scope cannot be resolved — no
-- units existed to point at, so any such row named a unit that was never real,
-- which is what ADR-0005 recorded as the gap this ADR closes.
DO $$
DECLARE
    unresolved int;
BEGIN
    ALTER TABLE delegation_grant_scopes NO FORCE ROW LEVEL SECURITY;

    UPDATE delegation_grant_scopes
       SET scope_property_id = scope_id
     WHERE scope_kind = 'property' AND scope_property_id IS NULL;

    SELECT count(*) INTO unresolved
      FROM delegation_grant_scopes
     WHERE scope_kind <> 'portfolio' AND scope_property_id IS NULL;

    ALTER TABLE delegation_grant_scopes FORCE ROW LEVEL SECURITY;

    IF unresolved > 0 THEN
        -- Do not add the constraint over rows that violate it; that fails the
        -- whole bootstrap and takes every unrelated change down with it. Say
        -- what is wrong instead, and leave the rest of the file to run.
        RAISE WARNING '% grant scope row(s) could not be resolved to a property — '
                      'the shape constraint is not being added. These are unit scopes '
                      'written before ADR-0009, and they grant nothing.', unresolved;
    ELSIF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conname = 'delegation_grant_scopes_property_shape') THEN
        -- ADD CONSTRAINT IF NOT EXISTS does not exist, and a bare ADD CONSTRAINT
        -- fails the replay on the second run.
        ALTER TABLE delegation_grant_scopes ADD CONSTRAINT delegation_grant_scopes_property_shape
            CHECK ((scope_kind = 'portfolio') = (scope_property_id IS NULL));
    END IF;
END
$$;

-- ADR-0012. Widen journal_entries_kind for the two settlement kinds.
--
-- This is a definition, not data, and it needs no row-level security window. What
-- it does need is to exist at all: the CHECK is written inside CREATE TABLE IF NOT
-- EXISTS, which does not revisit a table that is already there. Adding a kind to
-- that clause alone reaches every fresh database — including CI — and no existing
-- one, so the first entry of the new kind would have failed in production against
-- a schema whose tests were green.
--
-- Dropped and re-added rather than altered, because a CHECK cannot be altered, and
-- unconditionally rather than IF NOT EXISTS, because the point is to replace an
-- older definition with a wider one.
DO $$
BEGIN
    ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entries_kind;
    ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_kind CHECK (entry_kind IN (
        'invoice', 'late_fee', 'payment', 'payment_with_tds', 'settlement',
        'settlement_with_fee', 'clearing_write_off',
        'deposit_collection', 'deposit_refund', 'payout', 'platform_fee',
        'gst_remittance', 'refund', 'write_off', 'reversal'));
END
$$;

-- ADR-0015. The platform organisation, which ADR-0002 §1 has assumed since it was
-- written and nothing ever created.
--
-- Found while wiring the durable-operations tables: every platform-level fact in
-- ADR-0002 carries "the platform organisation", workflow_runs.tenant_id has a
-- foreign key to organisations, and there was no such row. The first platform-level
-- event would have failed that key in production, having passed every test that
-- never wrote one.
--
-- It is here, in the scoped window, because the section above this one explains
-- exactly why: the bootstrap connects as the table owner, FORCE row level security
-- applies to the owner, and no app.tenant_id is set, so every policy evaluates
-- false. Measured — as an inline INSERT beside the table definitions it fails the
-- whole bootstrap:
--
--   ERROR:  new row violates row-level security policy for table "organisations"
--
-- Which is the same cause as the silent UPDATE 0 described above and the opposite
-- symptom. The loud one is the better failure, and it is only loud because an
-- INSERT is judged by WITH CHECK rather than filtered by USING.
--
-- The uuid is the one internal/money/domain already uses as the platform *party*
-- on ledger postings. One number for one actor: two magic uuids that both mean
-- "us" is a thing every reader has to look up.
DO $$
BEGIN
    ALTER TABLE organisations NO FORCE ROW LEVEL SECURITY;

    INSERT INTO organisations (id, slug, name, kind, state)
    VALUES ('00000000-0000-0000-0000-0000000000d8', 'dwellm8-platform', 'Dwellm8', 'platform', 'active')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE organisations FORCE ROW LEVEL SECURITY;
END
$$;

-- ADR-0015. Widen journal_entries_reversal_reason_check for `workflow_compensated`.
--
-- Same reason and same shape as the entry_kind migration above: the inline clause
-- in CREATE TABLE IF NOT EXISTS never reaches a database that already exists, so
-- without this the first compensating reversal would be refused in production by a
-- constraint every test had seen the wider version of.
--
-- The reason is its own rather than operator_error because nobody made an error: the
-- entry was correct when it was posted and a later step of the same operation
-- failed. ADR-0015 §4.
DO $$
BEGIN
    ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entries_reversal_reason_check;
    ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_reversal_reason_check
        CHECK (reversal_reason IS NULL OR reversal_reason IN (
            'duplicate', 'wrong_amount', 'wrong_account', 'wrong_party',
            'wrong_period', 'provider_chargeback', 'operator_error',
            'settlement_mismatch', 'workflow_compensated'));
END
$$;

-- ADR-0010 §7. journal_entries.lease_id — the tenancy an entry bills.
--
-- Added here rather than in the CREATE TABLE for the reason the block below exists:
-- CREATE TABLE IF NOT EXISTS never revisits a table that already exists, and
-- journal_entries has existed since ADR-0006. ADD COLUMN IF NOT EXISTS does exist, so
-- unlike a CHECK this one can be written once.
--
-- Nullable: most entries have no tenancy. The rule that remains is one-directional —
-- a lease charge names its lease — which is what keeps ADR-0010 §7's trigger enforcing.
--
-- The converse was withdrawn by the ADR-0006 §5 amendment: it forbade a payment
-- (source_kind 'payment') from naming the lease it paid, so a per-lease position summed
-- the invoices and none of the receipts.
DO $$
BEGIN
    ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS lease_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'journal_entries_lease_fkey') THEN
        ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_lease_fkey
            FOREIGN KEY (lease_id, tenant_id) REFERENCES leases (id, tenant_id);
    END IF;

    -- The source_kind vocabulary stays open — ADR-0006 deliberately left it free text so
    -- any module can name its own cause — but 'lease_charge' now means something the
    -- database checks.
    --
    -- Compared by definition, not by name: an older database has the stricter rule
    -- under this same name, so IF NOT EXISTS alone would skip it forever. `<>` appears
    -- in the implication and in no earlier version.
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'journal_entries_lease_charge_shape'
                  AND pg_get_constraintdef(oid) NOT LIKE '%<>%') THEN
        ALTER TABLE journal_entries DROP CONSTRAINT journal_entries_lease_charge_shape;
        RAISE NOTICE 'relaxed journal_entries_lease_charge_shape: lease_id now names the '
                     'tenancy an entry concerns, not only the tenancy it bills';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'journal_entries_lease_charge_shape') THEN
        ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_lease_charge_shape
            CHECK (source_kind <> 'lease_charge' OR lease_id IS NOT NULL);
    END IF;
END
$$;

-- "What has this tenancy been billed" — the retrospective-termination trigger's own
-- query, and the owner's statement for a lease.
CREATE INDEX IF NOT EXISTS journal_entries_lease_idx
    ON journal_entries (tenant_id, lease_id, occurred_on) WHERE lease_id IS NOT NULL;

-- payments.lease_id — the tenancy a collection pays. Issue #42.
--
-- Nullable: a deposit or an ad-hoc collection has no tenancy. Where it is set, the
-- entry the capture posts inherits it, which is what puts receipts into a lease
-- position alongside the charges. Added by migration for the usual reason, and after
-- leases because a foreign key cannot precede its target.
DO $$
BEGIN
    ALTER TABLE payments ADD COLUMN IF NOT EXISTS lease_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payments_lease_fkey') THEN
        ALTER TABLE payments ADD CONSTRAINT payments_lease_fkey
            FOREIGN KEY (lease_id, tenant_id) REFERENCES leases (id, tenant_id);
    END IF;
END
$$;

-- "What has this tenancy paid" — the other half of the lease statement.
CREATE INDEX IF NOT EXISTS payments_lease_idx
    ON payments (tenant_id, lease_id) WHERE lease_id IS NOT NULL;

-- The load-bearing rules.
--
-- Every CHECK an ADR argues for at length lives here rather than inside its
-- CREATE TABLE, and this block is the third and last entry in this file's longest-
-- running trap: **a CHECK written inside CREATE TABLE IF NOT EXISTS is skipped
-- entirely on a database that already has the table.** The file replays, exits 0,
-- reports nothing, and the constraint is simply absent — present in CI, where every
-- database is fresh, and missing in the one place it matters.
--
-- Measured, on a database where one had been dropped by hand:
--
--   $ psql -v ON_ERROR_STOP=1 -f dwellm8.sql      # exit 0, no output
--   $ SELECT count(*) FROM pg_constraint
--       WHERE conname = 'workflow_runs_compensated_means_reversible';
--     0
--
-- The two vocabulary migrations above (journal_entries_kind, and the reversal
-- reasons) were the first two times it bit, and both were fixed one at a time. This
-- block is the structural version: one definition per rule, in a position that
-- reaches every database, and assertion 13 fails the bootstrap if any of them is
-- absent afterwards. Duplicating them — inline *and* here — was the obvious fix and
-- is worse: two definitions of one rule drift, and the one that runs is the one
-- nobody reads.
--
-- ADD CONSTRAINT has no IF NOT EXISTS, hence the guard on each.
--
-- And it validates the rows already there, which is the second thing this block has
-- to handle. A constraint that went missing let data in that violates it, so adding
-- it back fails — and failing here would take every unrelated statement below down
-- with it, on every bootstrap, forever. ADR-0009's backfill hit the same wall and
-- set the precedent: count the offending rows and RAISE WARNING rather than
-- aborting. Measured:
--
--   ERROR:  check constraint "workflow_runs_compensated_means_reversible" of
--           relation "workflow_runs" is violated by some row
--
-- Assertion 13 still fails and still names the constraint, which is the outcome
-- wanted: loud and specific, without holding the rest of the schema hostage to rows
-- somebody has to look at.
--
-- `WHERE NOT (expr)` is the right test rather than `WHERE expr IS NOT TRUE`: a CHECK
-- is satisfied by NULL, and so is this.
--
-- And the count needs the row-level security window, which is this file's oldest
-- trap biting the guard written for its second-oldest. The first version counted
-- without one: the bootstrap connects as the owner, FORCE row level security applies
-- to the owner, and no app.tenant_id is set — so the count came back 0 from a table
-- with a violating row in it, the block decided the table was clean, and the ALTER
-- failed anyway because DDL validates every row regardless of any policy. The
-- symptom was the error this block exists to avoid, produced by the check meant to
-- avoid it.
DO $$
DECLARE
    r record;
    bad bigint;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            -- ADR-0011 §3. Money the provider has and the ledger does not know
            -- about is the exact shape of the defect that subsystem prevents.
            ('payments', 'payments_captured_has_entry',
             $c$status NOT IN ('captured', 'settled') OR entry_id IS NOT NULL$c$),

            -- ADR-0012 §2. A file we parsed wrong must not be able to look like a
            -- file we disagree with.
            ('settlement_batches', 'settlement_batches_adds_up',
             $c$net_minor = gross_minor - refund_minor - fee_minor - tax_minor$c$),

            -- ADR-0012 §5. A line that did not reconcile cannot have caused an
            -- entry, whatever the code believed.
            ('settlement_lines', 'settlement_lines_only_matched_lines_post',
             $c$entry_id IS NULL OR match_class IN ('exact', 'fee_adjusted')$c$),

            -- ADR-0012 §8. A comparison over no lines looks perfectly clean.
            ('reconciliation_runs', 'reconciliation_runs_reconciled_saw_the_file',
             $c$state NOT IN ('reconciled', 'drift') OR file_present$c$),

            -- ADR-0015 §4. Recording a compensation after money has left says the
            -- world was put back, and every report downstream believes it.
            ('workflow_runs', 'workflow_runs_compensated_means_reversible',
             $c$state <> 'compensated' OR NOT past_no_return$c$),

            -- ADR-0013 §2. A full identifier does not fit in the only column that could
            -- hold one. Per kind, because the mask of a PAN is a different shape from the
            -- mask of an Aadhaar and a single loose pattern would accept both a mask and
            -- the thing it was made from. The patterns come from internal/platform/pii and
            -- the store contract test compares them.
            ('kyc_verifications', 'kyc_verifications_reference_is_a_mask',
             $c$CASE kind
                WHEN 'aadhaar'         THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'pan'             THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'bank_account'    THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'passport'        THEN masked_reference ~ '^X+[0-9A-Z]{3}$'
                WHEN 'driving_licence' THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'voter_id'        THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'ifsc'            THEN masked_reference ~ '^[A-Z]{4}0[A-Z0-9]{6}$'
                WHEN 'gstin'           THEN masked_reference ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z][Z][0-9A-Z]$'
                WHEN 'upi_vpa'         THEN masked_reference ~ '^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$'
                END$c$),

            -- ADR-0013 §5. A support read with no grant behind it is the thing an audit
            -- exists to catch.
            ('kyc_access_log', 'kyc_access_log_support_needs_a_grant',
             $c$actor_kind <> 'support' OR support_grant_id IS NOT NULL$c$),

            -- ADR-0022 §2. An active authority nobody can ask the provider about is
            -- one that cannot be confirmed, paused or revoked — it can only be
            -- debited, which is the wrong half to keep.
            ('mandates', 'mandates_active_has_provider_id',
             $c$status <> 'active' OR provider_mandate_id IS NOT NULL$c$),

            -- ADR-0022 §4. The inbox rule extended to authorities: nothing
            -- unverified may ever be attributed to one.
            ('payment_events', 'payment_events_unverified_names_no_mandate',
             $c$signature_verified OR mandate_id IS NULL$c$),

            -- ADR-0023 §3. The value matches the kind that names it. A rate read as
            -- an amount is 18 paise of GST, and nothing about the invoice looks wrong.
            ('statutory_rules', 'statutory_rules_value_shape',
             $c$(value_kind = 'rate'   AND rate_bps     IS NOT NULL AND amount_minor IS NULL AND count_value IS NULL)
             OR (value_kind = 'amount' AND amount_minor IS NOT NULL AND rate_bps     IS NULL AND count_value IS NULL)
             OR (value_kind = 'count'  AND count_value  IS NOT NULL AND rate_bps     IS NULL AND amount_minor IS NULL)
             OR (value_kind = 'slabs'  AND rate_bps IS NULL AND amount_minor IS NULL AND count_value IS NULL)$c$),

            -- ADR-0023 §4. A cap enforced from a blog post is worse than no cap,
            -- because it is wrong with authority.
            ('statutory_rules', 'statutory_rules_unverified_cannot_block',
             $c$enforcement <> 'block' OR verification_status = 'verified'$c$)
        ) AS t(tbl, name, expr)
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM pg_constraint WHERE conname = r.name);

        -- The scoped window, as in every other data-touching statement in this
        -- section. One transaction, so a failure restores FORCE with the rollback.
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', r.tbl);
        EXECUTE format('SELECT count(*) FROM %I WHERE NOT (%s)', r.tbl, r.expr) INTO bad;
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', r.tbl);
        IF bad > 0 THEN
            RAISE WARNING '% row(s) in % violate %, so it is not being added. Those rows were '
                          'written while the rule was absent and need a decision, not a migration; '
                          'assertion 13 will fail until they are dealt with.', bad, r.tbl, r.name;
        ELSE
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK (%s)', r.tbl, r.name, r.expr);
            RAISE NOTICE 'added missing constraint %.%', r.tbl, r.name;
        END IF;
    END LOOP;
END
$$;

-- ===========================================================================
-- the event outbox (ADR-0002)
-- ===========================================================================

-- The one table every module writes, and the single exception to ADR-0001's
-- one-writer rule: the outbox is infrastructure, not a domain.
--
-- The rule it exists to enforce is that the state change and the event are one
-- transaction. A handler that publishes after committing loses the event
-- whenever the process dies in between, and that gap is not theoretical — it is
-- every rolling restart.
CREATE TABLE IF NOT EXISTS outbox (
    id              text PRIMARY KEY,
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    type            text NOT NULL,
    version         int  NOT NULL DEFAULT 1,
    subject_kind    text NOT NULL,
    subject_id      text NOT NULL,
    correlation_id  text NOT NULL,
    causation_id    text,
    actor_kind      text NOT NULL,
    actor_id        uuid,
    occurred_at     timestamptz NOT NULL,
    payload         jsonb NOT NULL,

    -- NULL until the broker has durably acknowledged it. The relay's whole
    -- state machine is this column plus the two below it.
    published_at    timestamptz,
    attempts        int NOT NULL DEFAULT 0,
    last_error      text,
    next_attempt_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT outbox_type_shape CHECK (type ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
    CONSTRAINT outbox_version_positive CHECK (version >= 1),
    CONSTRAINT outbox_actor_kind CHECK (actor_kind IN ('user', 'system', 'provider', 'support')),
    -- A user actor with no id names nobody, which is the state a support call
    -- cannot get past.
    CONSTRAINT outbox_user_actor_has_an_id CHECK (actor_kind <> 'user' OR actor_id IS NOT NULL),
    CONSTRAINT outbox_subject_present CHECK (btrim(subject_kind) <> '' AND btrim(subject_id) <> '')
);

COMMENT ON TABLE outbox IS
    'ADR-0002. Domain events, written in the same transaction as the state change they describe and drained to JetStream by the relay.';
COMMENT ON COLUMN outbox.published_at IS
    'When the broker acknowledged it. NULL is the backlog, and its oldest occurred_at is the lag alerted on.';

-- The relay's claim: unpublished, due, and in the order the facts happened.
CREATE INDEX IF NOT EXISTS outbox_unpublished_idx
    ON outbox (next_attempt_at, occurred_at) WHERE published_at IS NULL;
-- Answering "did this ever publish" during a support call, by subject.
CREATE INDEX IF NOT EXISTS outbox_subject_idx
    ON outbox (tenant_id, subject_kind, subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS outbox_correlation_idx
    ON outbox (correlation_id, occurred_at);

ALTER TABLE outbox ENABLE ROW LEVEL SECURITY;
ALTER TABLE outbox FORCE ROW LEVEL SECURITY;

-- A module writes its own organisation's events and reads them back; the relay
-- runs as the platform session because draining is inherently cross-tenant.
DROP POLICY IF EXISTS outbox_tenant_isolation ON outbox;
CREATE POLICY outbox_tenant_isolation ON outbox
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()));

-- An event is a record of something that happened, so it is not deletable by a
-- module. The sandbox purge is the one exception, as everywhere else.
DROP POLICY IF EXISTS outbox_no_delete ON outbox;
CREATE POLICY outbox_no_delete ON outbox AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Every module appends. Only the platform role marks a row published, because
-- only the relay does.
GRANT SELECT, INSERT ON outbox TO dwellm8_money, dwellm8_lease, dwellm8_identity,
    dwellm8_property, dwellm8_maintenance, dwellm8_community, dwellm8_discovery,
    dwellm8_notify;
GRANT SELECT, INSERT, UPDATE ON outbox TO dwellm8_platform;

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
    WHERE rolname IN ('dwellm8_api', 'dwellm8_platform', 'dwellm8_app', 'dwellm8_purge')
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
    --
    --    ADR-0021 scoped the predicate from `false` to sandbox_purge_permitted(), for the
    --    reason given at assertion 7: a demo sandbox has to be cleanable, and it is safe
    --    because no real effect may originate in one. The grantee still cannot erase
    --    anything — the predicate requires a platform session *and* a sandbox
    --    organisation, so a firm deleting the record of what it was permitted to do is
    --    exactly as impossible as it was.
    SELECT string_agg(t, ', ') INTO offending
    FROM unnest(ARRAY['delegation_grants', 'delegation_grant_scopes']) AS t
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           -- pg_policies.permissive is text, not boolean: 'RESTRICTIVE'.
           AND p.cmd = 'DELETE' AND p.permissive = 'RESTRICTIVE'
           AND (p.qual = 'false' OR p.qual LIKE '%sandbox_purge_permitted%'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'no RESTRICTIVE deny-delete policy on: % — a grantee could erase the evidence', offending;
    END IF;

    -- 5. A table that is property-scoped must say so in its policy. Passing
    --    NULL for row_property, or omitting the delegated branch entirely,
    --    silently widens a two-unit grant to the grantor's whole portfolio.
    --    This bit for the first time with ADR-0009's blocks table, as predicted.
    --
    --    is_delegated_unit() also satisfies it, and is strictly stronger: it
    --    checks the exact unit. A table that has both columns should use it.
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
             AND (p.qual LIKE '%is_delegated(%property_id%'
               OR p.qual LIKE '%is_delegated_unit(%property_id%'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) with property_id whose policy does not pass it to is_delegated(): % '
                        '— a scoped grant would widen to the whole portfolio', offending;
    END IF;

    -- 6. And the same one level down. A table that identifies a unit must be
    --    judged at unit granularity, or a mandate over one flat reads every flat
    --    in the tower — which assertion 5 would happily allow, because
    --    property_id is passed and the check is honest about the wrong thing.
    --
    --    units itself is included by name: its unit column is `id`, so no column
    --    scan finds it, and it is the table where getting this wrong matters
    --    most. ADR-0009 §4.
    SELECT string_agg(DISTINCT t, ', ') INTO offending
    FROM (
        SELECT c.relname AS t
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN information_schema.columns col
          ON col.table_schema = 'public' AND col.table_name = c.relname
         AND col.column_name = 'unit_id'
        WHERE n.nspname = 'public' AND c.relkind = 'r'
        UNION
        SELECT 'units'
    ) unit_tables
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = unit_tables.t
           AND p.qual LIKE '%is_delegated_unit(%');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) identifying a unit whose policy does not use is_delegated_unit(): % '
                        '— a one-unit mandate would read every unit in the property', offending;
    END IF;

    -- 7. The ledger is append-only. Both tables need a RESTRICTIVE policy
    --    denying UPDATE and one denying DELETE — the privileges are revoked as
    --    well, but a future GRANT that hands them back must still hit a wall.
    --    ADR-0006 §3.
    --    The alias is `required_cmd` rather than `cmd` for a reason that cost a
    --    round of testing: with the obvious name, `p.cmd = cmd` inside the
    --    subquery resolves to pg_policies' own column, the condition becomes
    --    `p.cmd = p.cmd`, and the assertion passes as long as *either* policy
    --    exists. Measured — dropping ledger_postings_no_update and running the
    --    assertion block alone came out green.
    --
    --    ADR-0021 relaxed the DELETE half, and it is the only relaxation of this rule in
    --    the file. It reads `sandbox_purge_permitted(tenant_id)` rather than `false`,
    --    which means: no ledger row of a *real* organisation may ever be deleted, and a
    --    demo sandbox's may be purged by the platform.
    --
    --    That is a genuine weakening and its safety rests entirely on ADR-0021 §3 — no
    --    real effect may originate in a sandbox, so a sandbox ledger contains no real
    --    money. If that ban is ever weakened this must go back to `false`, and assertion
    --    16 is what would otherwise let the two drift apart. UPDATE stays absolute: there
    --    is no reason to edit a posting even in a demo, and the seed writes them once.
    SELECT string_agg(format('%s:%s', t, required_cmd), ', ') INTO offending
    FROM unnest(ARRAY['journal_entries', 'ledger_postings']) AS t
    CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE']) AS required_cmd
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           AND p.cmd = required_cmd AND p.permissive = 'RESTRICTIVE'
           AND (p.qual = 'false'
             OR (required_cmd = 'DELETE' AND p.qual LIKE '%sandbox_purge_permitted%')));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'the ledger is mutable: no RESTRICTIVE deny policy for % — a corrected '
                        'amount that leaves no trace is indistinguishable from theft. DELETE may '
                        'be scoped to sandbox_purge_permitted() and to nothing else; UPDATE may '
                        'not be scoped at all', offending;
    END IF;

    -- 8. Money is an integer of minor units. This is ADR-0007's standard
    --    arriving early, because the first table to hold an amount is landing
    --    now and an inexact column added later would be found by a rounding
    --    complaint rather than by a build.
    --
    --    Two rules, and the split is deliberate. Typing the column is what
    --    matters, so the first clause is about types: nothing money-shaped may
    --    be numeric, real, double precision or money. The second is about the
    --    name, so that *_minor keeps meaning what it says. An earlier version
    --    matched on the name alone and failed on posting_template_lines
    --    .amount_role, which holds the word 'gross' — the assertion was right
    --    that the name looked like money and wrong that the column was.
    SELECT string_agg(format('%s.%s (%s)', col.table_name, col.column_name, col.data_type), ', ')
      INTO offending
    FROM information_schema.columns col
    JOIN pg_class c ON c.relname = col.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    WHERE col.table_schema = 'public' AND c.relkind = 'r'
      AND (
        (col.data_type IN ('numeric', 'real', 'double precision', 'money')
         AND (col.column_name ~ '(amount|price|fee|balance|total|rent|deposit|payable|receivable)'))
        OR (col.column_name LIKE '%\_minor' AND col.data_type <> 'bigint')
      );
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'money column(s) that are not an integer of minor units: % '
                        '— an inexact type in a money path is the defect ADR-0007 exists to prevent', offending;
    END IF;

    -- 9. A posting template that posts to one side only would produce an entry
    --    the balance trigger rejects at commit, which is a failure discovered by
    --    a customer rather than by this file. 'reversal' is exempt by design: it
    --    is the original entry flipped, not a rule about accounts.
    SELECT string_agg(t.event_kind, ', ') INTO offending
    FROM posting_templates t
    WHERE t.event_kind <> 'reversal'
      AND NOT (EXISTS (SELECT 1 FROM posting_template_lines l
                        WHERE l.event_kind = t.event_kind AND l.version = t.version AND l.side = 'debit')
           AND EXISTS (SELECT 1 FROM posting_template_lines l
                        WHERE l.event_kind = t.event_kind AND l.version = t.version AND l.side = 'credit'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'posting template(s) with only one side: % — every entry they produce would be rejected', offending;
    END IF;

    -- 10. Every view must run as its caller. A view without security_invoker
    --     executes as its owner, so every policy on the tables underneath it is
    --     evaluated for the wrong role — it does not leak, it under-reports,
    --     which is the harder failure to notice. ADR-0006 §5.
    --
    --     Written by name for ledger_balances first, and generalised when
    --     ADR-0012 added a second view. Naming the view was the same mistake
    --     assertion 6 was written not to make: a guard that covers the objects
    --     its author had in mind decays with the next migration, and here the
    --     decay would be silent under-reporting of an ageing report.
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION 'PostgreSQL % is too old: this schema''s views need security_invoker (15+)',
            current_setting('server_version');
    END IF;
    SELECT string_agg(c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'view(s) that are not security_invoker: % — they would be evaluated as their owner, '
                        'and every delegated or platform session would silently see the wrong numbers', offending;
    END IF;

    -- 11. No table owner may inherit dwellm8_platform.
    --
    --     is_platform_session() exempts a session from every policy in this
    --     file, and the role that owns these tables is the role the bootstrap
    --     job — and, today, the API deployment — connects as. If it inherits the
    --     platform role, tenant isolation is off for the whole application while
    --     every policy still reads correctly.
    --
    --     This is not hypothetical: from PostgreSQL 16 a CREATEROLE role is
    --     automatically granted the roles it creates, and the first version of
    --     is_platform_session() asked 'MEMBER', which that grant satisfies. See
    --     the comment on the function.
    SELECT string_agg(DISTINCT pg_get_userbyid(c.relowner), ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND c.relrowsecurity
      AND pg_has_role(pg_get_userbyid(c.relowner), 'dwellm8_platform', 'USAGE');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table owner(s) inherit dwellm8_platform: % — every session connecting as '
                        'that role is exempt from every policy in this file, and nothing looks wrong', offending;
    END IF;

    -- 12. A table whose rows may belong to no organisation must be writable only
    --     by a platform session.
    --
    --     ADR-0011 §5 introduced that exception once, for the webhook inbox, with
    --     a paragraph explaining why. ADR-0012 added three more tables of the same
    --     shape, and at that point it stopped being an exception and became a
    --     pattern — so it gets a guard rather than a paragraph.
    --
    --     The hazard is specific. A nullable or absent tenant_id means
    --     `tenant_id = current_tenant_id()` is not a filter for every row, so the
    --     ordinary ADR-0003 policy shape does not constrain writes at all: an
    --     organisation could insert a row with a NULL tenant, and nothing would
    --     refuse it. The only WITH CHECK that is sound on such a table is
    --     is_platform_session() alone, and the consequence — that ingestion is a
    --     platform-role path — is a real architectural constraint rather than an
    --     implementation detail.
    --
    --     Reference tables have no row-level security at all and are therefore not
    --     considered here; that is deliberate, and assertion 1 is what keeps a
    --     tenant-scoped table from quietly joining them.
    --
    --     organisations is excluded by name, for the same reason assertion 6 has to
    --     include units by name: its tenant column is `id`, so no column scan finds
    --     it. Measured — the first version of this assertion failed the bootstrap on
    --     organisations, which is correctly scoped by `id = current_tenant_id()` and
    --     is the one table where that is the right shape. The exclusion is a named
    --     row rather than a widened rule, so a second table that grows this shape
    --     has to argue for itself.
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
      AND c.relname <> 'organisations'
      -- Either no tenant_id column at all, or one that admits NULL.
      AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns col
           WHERE col.table_schema = 'public' AND col.table_name = c.relname
             AND col.column_name = 'tenant_id' AND col.is_nullable = 'NO')
      AND NOT EXISTS (
          SELECT 1 FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
             AND p.permissive = 'PERMISSIVE'
             AND p.with_check = 'is_platform_session()');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose rows may belong to no organisation and whose writes are not '
                        'platform-only: % — on such a table tenant_id = current_tenant_id() constrains '
                        'nothing, so any organisation could write a row belonging to none', offending;
    END IF;

    -- 13. The constraints and triggers this file's ADRs actually depend on, asserted
    --     by name.
    --
    --     This exists because of the trap the migrations section is now three
    --     entries long for: a CHECK written inside CREATE TABLE IF NOT EXISTS never
    --     reaches a database that already has the table. The file replays, reports
    --     nothing, and the constraint is simply absent — present in CI, where every
    --     database is fresh, and missing in the one place it matters.
    --
    --     Measured on a database where workflow_runs_compensated_means_reversible
    --     had been dropped: replay exit 0, constraint count 0.
    --
    --     A named list is the honest shape. It cannot be derived — there is no way
    --     to ask PostgreSQL which constraints a file meant to create — so this is a
    --     list somebody maintains, and the thing that makes it worth having is that
    --     it fails the bootstrap rather than a review. Each entry is a rule an ADR
    --     argues for at length, not every constraint in the file: a list of
    --     everything would be a second copy of the schema and would rot.
    --
    --     It does not catch a replay that aborted half way — that case is already
    --     loud, because the job fails. It catches the quiet one.
    -- 14. An effective-dated table must be able to answer an as-of question with one
    --     row, and the database must be what guarantees it.
    --
    --     Column-driven, like assertion 6, so it polices a table nobody updated it
    --     for. Three clauses:
    --
    --     (a) A table with `valid_from date` is effective-dated in ADR-0008's sense
    --         and must have the generated `validity` column. Without it every query
    --         hand-writes `valid_from <= $1 AND (valid_to IS NULL OR valid_to > $1)`,
    --         which has two places to get the open-ended case wrong.
    --     (b) It must have an EXCLUDE constraint over that column. A trigger cannot
    --         do this job: it reads the table it protects, so it is racy under
    --         concurrency — which is exactly when two people revise the same flat.
    --     (c) `valid_from timestamptz` means an authorisation window rather than an
    --         effective date, which is a real distinction (delegation_grants) and a
    --         plausible mistake. Those tables are named, so a new one argues for
    --         itself instead of quietly escaping (a) and (b).
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns vf
      ON vf.table_schema = 'public' AND vf.table_name = c.relname AND vf.column_name = 'valid_from'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND vf.data_type = 'date'
      AND (NOT EXISTS (
              SELECT 1 FROM information_schema.columns v
               WHERE v.table_schema = 'public' AND v.table_name = c.relname
                 AND v.column_name = 'validity' AND v.udt_name = 'daterange')
           OR NOT EXISTS (
              SELECT 1 FROM pg_constraint x
               WHERE x.conrelid = c.oid AND x.contype = 'x'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'effective-dated table(s) without a generated validity range and an '
                        'exclusion constraint over it: % — an as-of query would hand-write the '
                        'open-ended case and two revisions of the same subject could both be live',
                        offending;
    END IF;

    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns vf
      ON vf.table_schema = 'public' AND vf.table_name = c.relname AND vf.column_name = 'valid_from'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND vf.data_type <> 'date'
      -- delegation_grants (ADR-0005) is an authorisation window: access begins at a
      -- moment and no legal document is dated by it. Anything else with a
      -- timestamptz validity is an effective date that lost its timezone argument.
      AND c.relname <> 'delegation_grants';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose validity is a timestamp rather than a date: % — an '
                        'effective date has no time and no zone, or 1 April means two different '
                        'days five and a half hours apart. If it is an authorisation window rather '
                        'than an effective date, say so here', offending;
    END IF;

    -- 15. No column anywhere may be named after a prohibited identifier, and the KYC
    --     table may hold nothing but the fields ADR-0013 lists.
    --
    --     Two clauses, because they catch different developers.
    --
    --     (a) A name scan. Weak on its own — somebody determined calls the column
    --         `national_id` — and it catches the careless case, which is the common one:
    --         the vendor SDK returns `aadhaarNumber` and the obvious column name follows
    --         it. The list lives in internal/platform/pii so there is one copy, and the
    --         arch test reads the same one.
    --     (b) A positive allowlist on kyc_verifications. This is the strong half: *any*
    --         column not on the list fails the bootstrap, so a field cannot be added to
    --         the KYC table without arguing for it here. That is the mechanism the
    --         story's failure scenario asks for — a developer adding a field that would
    --         persist a full identifier is blocked, whatever they call it.
    SELECT string_agg(format('%s.%s', col.table_name, col.column_name), ', ') INTO offending
    FROM information_schema.columns col
    JOIN pg_class c ON c.relname = col.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    WHERE col.table_schema = 'public' AND c.relkind = 'r'
      AND lower(col.column_name) ~ '(aadhaar|aadhar|adhaar|adhar|uidai)';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'column(s) named after a prohibited identifier: % — the Aadhaar number may '
                        'not be stored in any form, and a column named for it is where one ends up',
                        offending;
    END IF;

    SELECT string_agg(col.column_name, ', ') INTO offending
    FROM information_schema.columns col
    WHERE col.table_schema = 'public' AND col.table_name = 'kyc_verifications'
      AND col.column_name <> ALL (ARRAY[
          'id', 'tenant_id', 'subject_party_id', 'kind', 'masked_reference', 'result',
          'provider', 'provider_txn_id', 'consent_artefact_id', 'verified_at',
          'expires_at', 'created_at']);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'kyc_verifications has column(s) ADR-0013 does not list: % — a completed '
                        'verification holds the result, a masked reference, the provider and its '
                        'transaction, a timestamp and the consent artefact. Anything else has to be '
                        'argued for in an ADR and added to this list', offending;
    END IF;

    -- 16. Every tenant-scoped table's no-delete policy must permit the sandbox purge.
    --
    --     Column-driven, so a table added by a future ADR is covered before anybody
    --     writes a test for it — which is the whole point, because the failure is not
    --     visible from the new table. It shows up as a demo sandbox that cannot be
    --     cleaned up, months later, as storage that only grows.
    --
    --     The two platform-owned tables with no tenant_id are exempt by name: a
    --     settlement batch and a reconciliation run belong to no organisation, so they
    --     belong to no sandbox, and theirs stay at `false`.
    SELECT string_agg(DISTINCT p.tablename, ', ') INTO offending
    FROM pg_policies p
    JOIN information_schema.columns col
      ON col.table_schema = 'public' AND col.table_name = p.tablename
     AND col.column_name = 'tenant_id'
    WHERE p.schemaname = 'public'
      AND p.cmd = 'DELETE' AND p.permissive = 'RESTRICTIVE'
      AND p.qual NOT LIKE '%sandbox_purge_permitted%';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose no-delete policy does not permit the sandbox purge: % '
                        '— an expired demo sandbox would leave rows in them forever, and the '
                        'failure shows up as storage that only grows', offending;
    END IF;

    -- 17. Nothing but `listings` may be readable without a tenant.
    --
    --     ADR-0019 opened the first read path in this schema that does not fail closed,
    --     and this is what keeps it the only one. A PERMISSIVE read policy that mentions
    --     neither current_tenant_id() nor is_platform_session() has a branch an unscoped
    --     session can match — which is what an anonymous visitor is.
    --
    --     RESTRICTIVE policies are excluded because they narrow rather than widen: a
    --     deny-delete policy legitimately mentions neither.
    --
    --     The failure this prevents is silent and total. A new table given a convenience
    --     policy while somebody is debugging is a table the whole internet can read, and
    --     nothing about it looks wrong from the application.
    SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ') INTO offending
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd IN ('ALL', 'SELECT')
      AND p.tablename <> 'listings'
      AND coalesce(p.qual, '') NOT LIKE '%current_tenant_id()%'
      AND coalesce(p.qual, '') NOT LIKE '%is_platform_session()%';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'policy/policies readable without a tenant: % — an unscoped session is an '
                        'anonymous visitor, so this is world-readable. Only listings may be, and '
                        'only for a row its owner published', offending;
    END IF;

    -- And the other direction: the one public branch must stay scoped to a published,
    -- live row. Widening it to every listing would advertise drafts.
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = 'listings' AND p.cmd = 'ALL'
           AND p.qual LIKE '%published_at IS NOT NULL%' AND p.qual LIKE '%live%') THEN
        RAISE EXCEPTION 'the public listing policy is not scoped to a published, live row — a '
                        'draft listing would be advertised before its owner published it';
    END IF;

    -- A public read path with a public *write* path is a different thing entirely.
    IF EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = 'listings' AND p.cmd = 'ALL'
           AND coalesce(p.with_check, '') NOT LIKE '%current_tenant_id()%') THEN
        RAISE EXCEPTION 'the listings policy admits a write without a tenant — the hole is meant to '
                        'be read-only by construction';
    END IF;

    -- 18. Reference data has no runtime writer, and no unverified rule blocks.
    --
    --     The chart of accounts, the posting templates and the statutory rules are
    --     the rule rather than the data: this file writes them, and a request reads
    --     them. The privilege is revoked at the foot of each section, which is one
    --     line that a later `GRANT ... ON ALL TABLES` would silently undo — and it
    --     does exist, three sections up. So the state is asserted rather than the
    --     statement trusted.
    --
    --     What it prevents is specific and is not a leak: an organisation that can
    --     INSERT into statutory_rules can write itself a zero TDS rate with a
    --     valid_from of last April, and every deduction after it resolves correctly
    --     against a rule nobody authorised.
    SELECT string_agg(format('%s:%s', t, priv), ', ') INTO offending
    FROM unnest(ARRAY['ledger_accounts', 'posting_templates', 'posting_template_lines',
                      'statutory_rules', 'statutory_rule_slabs']) AS t
    CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) AS priv
    WHERE has_table_privilege('dwellm8_app', t, priv);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'reference data is writable at runtime: % — a request that can write a rate '
                        'is a request that can decide its own tax, and the rule would have no review '
                        'and no citation', offending;
    END IF;

    --     And the rule india-property-compliance.md §1.1 states, asserted over the
    --     rows rather than over the constraint: a CHECK written inside CREATE TABLE
    --     IF NOT EXISTS never reaches a database that already has the table, so on a
    --     replayed database this clause is the only thing between an unverified row
    --     and a lease the product refuses to create for a reason nobody can source.
    SELECT string_agg(format('%s/%s/%s', rule_type, jurisdiction, rule_key), ', ') INTO offending
    FROM statutory_rules
    WHERE retired_at IS NULL AND enforcement = 'block' AND verification_status <> 'verified';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'unverified statutory rule(s) set to block: % — a cap enforced from a blog '
                        'post is worse than no cap, because it is wrong with authority', offending;
    END IF;

    SELECT string_agg(want, ', ') INTO offending
    FROM unnest(ARRAY[
        -- ADR-0003: the composite key every tenant-scoped foreign key points at.
        -- Absent, the tables that reference it do not create at all, which is
        -- what happened to lease_tax_facts, tds_obligations and mandates.
        'leases_tenant_id_unique',
        -- ADR-0002 §1: an event names its tenant, its subject and its author.
        'outbox_actor_kind',
        'outbox_user_actor_has_an_id',
        'outbox_subject_present',
        -- ADR-0006 §3: the ledger balances, and an entry has lines.
        'ledger_postings_balance',
        'journal_entries_have_postings',
        -- ADR-0007: money is representable, and the currency is one.
        'journal_entries_kind',
        'journal_entries_reversal_reason_check',
        -- ADR-0011 §3: a payment walks forward, and a captured one posted.
        'payments_forward_only',
        'payments_captured_has_entry',
        -- ADR-0012 §2 and §5: a settlement file adds up, and an unreconciled line
        -- posts nothing.
        'settlement_batches_adds_up',
        'settlement_lines_only_matched_lines_post',
        'reconciliation_runs_counters',
        'reconciliation_runs_reconciled_saw_the_file',
        -- ADR-0015 §4: a run past the point of no return was not compensated, and
        -- the point of no return is monotonic.
        'workflow_runs_compensated_means_reversible',
        'workflow_runs_forward',
        -- ADR-0008 §4: two owners of the same flat cannot both be current.
        'property_ownership_no_overlap_unit',
        'property_ownership_no_overlap_property',
        'property_ownership_no_edit',
        -- ADR-0010: one flat cannot be let twice over the same days, a terminated
        -- tenancy says what happened to the money, and the agreement is not editable.
        'leases_no_double_let',
        'rent_schedule_no_overlap',
        'leases_termination_shape',
        'leases_legal_transitions',
        'leases_retrospective_end',
        -- ADR-0010 §7: an entry that bills a tenancy names it, so the trigger above is
        -- enforcing rather than inert.
        'journal_entries_lease_charge_shape',
        -- ADR-0013: a full identifier does not fit in the only column that could hold one.
        'kyc_verifications_reference_is_a_mask',
        'kyc_access_log_support_needs_a_grant',
        -- ADR-0019: browsing is anonymous and making contact is not, and neither party's
        -- number is reachable before both have engaged.
        'enquiries_verification_point',
        'contact_bridges_mutual',
        -- ADR-0021 §3: no real effect originates in a demo, which is what makes a demo
        -- purgeable at all.
        'payments_sandbox_provider',
        'workflow_runs_sandbox_ban',
        'demo_sessions_sandbox_only',
        'demo_sessions_cap',
        -- ADR-0023: one statutory rule in force at a time, the value shape matches the
        -- kind, an unverified rule cannot block, and a scale has no hole in it.
        'statutory_rules_no_overlap',
        'statutory_rules_value_shape',
        'statutory_rules_unverified_cannot_block',
        'statutory_rules_slabs_shape'
    ]) AS want
    WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = want)
      AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = want AND NOT tgisinternal);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'the rule(s) this schema is built on are missing: % — a CHECK inside '
                        'CREATE TABLE IF NOT EXISTS never reaches a database that already has the '
                        'table, so this is what a green replay with an absent constraint looks like',
                        offending;
    END IF;
END
$$;
