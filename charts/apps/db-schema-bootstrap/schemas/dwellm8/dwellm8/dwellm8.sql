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
CREATE POLICY properties_no_delete ON properties AS RESTRICTIVE FOR DELETE USING (false);
DROP POLICY IF EXISTS blocks_no_delete ON blocks;
CREATE POLICY blocks_no_delete ON blocks AS RESTRICTIVE FOR DELETE USING (false);
DROP POLICY IF EXISTS units_no_delete ON units;
CREATE POLICY units_no_delete ON units AS RESTRICTIVE FOR DELETE USING (false);

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
                        ('gross', 'net', 'tax', 'tds', 'advance', 'principal')),
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
    -- ADR-0007 owns the money standard. Until it lands, one currency, asserted
    -- rather than assumed: a second currency would need a rounding rule and an
    -- FX policy that do not exist.
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
    reversal_reason   text CHECK (reversal_reason IS NULL OR reversal_reason IN (
                        'duplicate', 'wrong_amount', 'wrong_account', 'wrong_party',
                        'wrong_period', 'provider_chargeback', 'operator_error', 'settlement_mismatch')),

    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    -- Who acted, when it was a firm acting under a delegation. Same shape as
    -- audit_events: the entry lands in the owner's tenant, stamped with the firm.
    actor_org_id    uuid REFERENCES organisations(id),
    grant_id        uuid REFERENCES delegation_grants(id),

    CONSTRAINT journal_entries_kind CHECK (entry_kind IN (
        'invoice', 'late_fee', 'payment', 'payment_with_tds', 'settlement',
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
CREATE POLICY journal_entries_no_delete ON journal_entries AS RESTRICTIVE FOR DELETE USING (false);
DROP POLICY IF EXISTS ledger_postings_no_update ON ledger_postings;
CREATE POLICY ledger_postings_no_update ON ledger_postings AS RESTRICTIVE FOR UPDATE USING (false);
DROP POLICY IF EXISTS ledger_postings_no_delete ON ledger_postings;
CREATE POLICY ledger_postings_no_delete ON ledger_postings AS RESTRICTIVE FOR DELETE USING (false);

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

-- The chart of accounts and the posting templates are the rule, not the data.
-- The application reads them; this file is the only thing that writes them, so a
-- request cannot invent an account and post against it.
REVOKE INSERT, UPDATE, DELETE ON ledger_accounts, posting_templates,
    posting_template_lines FROM dwellm8_app;

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
    SELECT string_agg(format('%s:%s', t, required_cmd), ', ') INTO offending
    FROM unnest(ARRAY['journal_entries', 'ledger_postings']) AS t
    CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE']) AS required_cmd
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           AND p.cmd = required_cmd AND p.permissive = 'RESTRICTIVE' AND p.qual = 'false');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'the ledger is mutable: no RESTRICTIVE deny policy for % '
                        '— a corrected amount that leaves no trace is indistinguishable from theft', offending;
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

    -- 10. The balances view must run as its caller. A view without
    --     security_invoker executes as its owner, so every policy on
    --     ledger_postings is evaluated for the wrong role — it does not leak,
    --     it under-reports, which is the harder failure to notice. ADR-0006 §5.
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION 'PostgreSQL % is too old: ledger_balances needs security_invoker (15+)',
            current_setting('server_version');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_class c
                    JOIN pg_namespace n ON n.oid = c.relnamespace
                   WHERE n.nspname = 'public' AND c.relname = 'ledger_balances'
                     AND c.reloptions @> ARRAY['security_invoker=true']) THEN
        RAISE EXCEPTION 'ledger_balances is not security_invoker — it would be evaluated as its owner, '
                        'and every delegated or platform session would silently see the wrong balance';
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
END
$$;
