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

-- The renter a request is acting as, ADR-0029. Same nullif() treatment and for
-- the same reason as the two above.
--
-- Declared here beside the other session helpers rather than in ADR-0029's own
-- section, because the delegated-read guard on lease_parties calls it and that
-- policy is written long before the resident scope. A helper that is defined
-- after its first caller works — plpgsql resolves names at run time — and it
-- works by luck.
CREATE OR REPLACE FUNCTION current_resident_party_id() RETURNS uuid
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT nullif(current_setting('app.resident_party_id', true), '')::uuid $$;

COMMENT ON FUNCTION current_resident_party_id() IS
    'ADR-0029. The renter a request is acting as, or NULL for every other kind of session.';

CREATE OR REPLACE FUNCTION is_resident_session() RETURNS boolean
    LANGUAGE sql STABLE PARALLEL SAFE AS
$$ SELECT current_resident_party_id() IS NOT NULL $$;

COMMENT ON FUNCTION is_resident_session() IS
    'True only when the request is a renter reading their own tenancy. Every resident policy is a no-op when this is false.';

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

