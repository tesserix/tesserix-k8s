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
-- write. Without the second half, a scoped session can still insert a row
-- belonging to another organisation and then be unable to read it back —
-- which is worse than either failing or succeeding cleanly.
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
