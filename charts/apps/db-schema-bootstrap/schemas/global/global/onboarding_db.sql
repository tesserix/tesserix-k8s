-- onboarding_db — projection and audit ledger for onboarding-service.
-- Zitadel is the source of truth; on disagreement the projection is repaired.
-- Idempotent: safe to run on every CronJob execution. See docs/onboarding-api.md.

SET client_min_messages = warning;

-- The application connects as "onboarding", which is NOT the owner of these
-- tables. That is what makes the REVOKE at the bottom of this file stick: a
-- table owner can always re-grant itself the privileges it revoked.
-- The role itself is reconciled by CNPG managedRoles in global-postgres.

-- identity and tenant_secrets are the two questions CLAUDE.md requires before
-- any product is built, recorded as data rather than as tribal knowledge: an
-- org endpoint refuses a product whose identity is 'gip' instead of silently
-- doing nothing.
CREATE TABLE IF NOT EXISTS products (
    key                TEXT PRIMARY KEY,
    display_name       TEXT        NOT NULL,
    zitadel_project_id TEXT        NOT NULL UNIQUE,
    machine_user_id    TEXT        NOT NULL UNIQUE,
    oidc_client_id     TEXT,
    hosts              TEXT[]      NOT NULL DEFAULT '{}',
    identity           TEXT        NOT NULL DEFAULT 'zitadel'
                       CHECK (identity IN ('zitadel', 'gip')),
    tenant_secrets     TEXT        NOT NULL DEFAULT 'none'
                       CHECK (tenant_secrets IN ('openbao', 'none')),
    tenancy            TEXT        NOT NULL DEFAULT 'org'
                       CHECK (tenancy IN ('org', 'ephemeral+org')),
    roles              TEXT[]      NOT NULL DEFAULT '{}',
    data_residency     TEXT        NOT NULL DEFAULT 'in',
    state              TEXT        NOT NULL DEFAULT 'active'
                       CHECK (state IN ('active', 'suspended')),
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- id IS the tenant_id: generated here, written to Zitadel org metadata, carried
-- in the token, stored on the product's own tenant row. One value, four places.
CREATE TABLE IF NOT EXISTS organizations (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    zitadel_org_id     TEXT        NOT NULL UNIQUE,
    name               TEXT        NOT NULL,
    primary_domain     TEXT,
    state              TEXT        NOT NULL DEFAULT 'active'
                       CHECK (state IN ('active', 'inactive')),
    created_by_product TEXT REFERENCES products (key),
    billing_email      TEXT,
    support_email      TEXT,
    plan               TEXT,
    seats              INTEGER,
    region             TEXT,
    -- The caller's own id for this customer (a CRM record, a signup id). The
    -- one field that makes reconciliation possible without matching on name.
    external_ref       TEXT,
    labels             JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS organizations_external_ref_idx
    ON organizations (created_by_product, external_ref) WHERE external_ref IS NOT NULL;

-- The entitlement join. Every product-scoped read and write is gated on a live
-- row here; without one the API answers 404 rather than confirming the org id.
CREATE TABLE IF NOT EXISTS org_products (
    org_id      UUID NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
    product_key TEXT NOT NULL REFERENCES products (key),
    roles       TEXT[]      NOT NULL DEFAULT '{}',
    granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at  TIMESTAMPTZ,
    PRIMARY KEY (org_id, product_key)
);

CREATE INDEX IF NOT EXISTS org_products_product_idx
    ON org_products (product_key) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS domains (
    org_id          UUID NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
    domain          TEXT NOT NULL,
    state           TEXT NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending', 'verified', 'failed')),
    challenge_type  TEXT,
    challenge_value TEXT,
    last_checked_at TIMESTAMPTZ,
    verified_at     TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (org_id, domain)
);

-- A domain resolves to at most one organization, or discovery is ambiguous.
CREATE UNIQUE INDEX IF NOT EXISTS domains_verified_unique
    ON domains (domain) WHERE state = 'verified';

-- No secrets here, ever. The IdP client secret is passed through to Zitadel's
-- encrypted eventstore; a copy, where one is genuinely needed, goes to OpenBao.
CREATE TABLE IF NOT EXISTS idps (
    org_id         UUID NOT NULL REFERENCES organizations (id) ON DELETE CASCADE,
    zitadel_idp_id TEXT NOT NULL,
    type           TEXT NOT NULL
                   CHECK (type IN ('okta', 'entra', 'google', 'github', 'oidc', 'saml', 'ldap')),
    display_name   TEXT        NOT NULL,
    auto_register  BOOLEAN     NOT NULL DEFAULT false,
    state          TEXT        NOT NULL DEFAULT 'active'
                   CHECK (state IN ('active', 'pending', 'inactive')),
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (org_id, zitadel_idp_id)
);

-- Scoped to the actor so one caller cannot replay another caller's response.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    actor         TEXT        NOT NULL,
    key           TEXT        NOT NULL,
    request_hash  TEXT        NOT NULL,
    status        INTEGER     NOT NULL,
    response_body BYTEA       NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at    TIMESTAMPTZ NOT NULL,
    PRIMARY KEY (actor, key)
);

CREATE INDEX IF NOT EXISTS idempotency_keys_expiry_idx ON idempotency_keys (expires_at);

-- Append-only and hash-chained. hash covers the row's own fields plus
-- prev_hash, so an edit or deletion breaks the chain even for someone holding
-- the application's own credential.
CREATE TABLE IF NOT EXISTS audit_events (
    seq         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_type  TEXT NOT NULL CHECK (actor_type IN ('platform', 'product', 'org_admin', 'system')),
    actor_id    TEXT NOT NULL,
    product_key TEXT,
    org_id      UUID,
    action      TEXT NOT NULL,
    target      TEXT,
    outcome     TEXT NOT NULL CHECK (outcome IN ('success', 'denied', 'error')),
    request_id  TEXT NOT NULL,
    detail      JSONB NOT NULL DEFAULT '{}'::jsonb,
    prev_hash   TEXT NOT NULL,
    hash        TEXT NOT NULL UNIQUE
);

CREATE INDEX IF NOT EXISTS audit_events_org_idx ON audit_events (org_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_actor_idx ON audit_events (actor_id, occurred_at DESC);

GRANT USAGE ON SCHEMA public TO onboarding;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    products, organizations, org_products, domains, idps, idempotency_keys
    TO onboarding;

-- The whole point: the application may append to the ledger and read it back,
-- and can do nothing else to it.
GRANT SELECT, INSERT ON audit_events TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM onboarding;
