-- onboarding_db — projection and audit ledger for onboarding-service.
-- Zitadel is the source of truth; on disagreement the projection is repaired.
-- Idempotent: safe to run on every CronJob execution. See docs/onboarding-api.md.

SET client_min_messages = warning;
SET lock_timeout = '5s';
SET statement_timeout = '2min';

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

-- Self-service Agent Registry workspaces. The internal UUID remains the
-- platform tenant id while zitadel_org_id is the signed org claim presented to
-- Registry. project_grant_id is required to grant publisher service users the
-- Registry project's roles without trusting caller-supplied identity ids.
CREATE TABLE IF NOT EXISTS registry_tenants (
    tenant_id         UUID PRIMARY KEY REFERENCES organizations (id) ON DELETE CASCADE,
    zitadel_org_id    TEXT        NOT NULL UNIQUE,
    owner_subject     TEXT        NOT NULL UNIQUE,
    slug              TEXT        NOT NULL UNIQUE,
    namespace         TEXT        NOT NULL UNIQUE,
    project_grant_id  TEXT        NOT NULL,
    state             TEXT        NOT NULL DEFAULT 'pending'
                      CHECK (state IN ('pending', 'ready', 'failed', 'needs_support')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Projection only: the OAuth verifier and one-time client secret live in
-- Zitadel. In particular, no secret, hash, or verifier may be added here.
CREATE TABLE IF NOT EXISTS registry_credentials (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         UUID        NOT NULL REFERENCES registry_tenants (tenant_id) ON DELETE CASCADE,
    zitadel_user_id   TEXT        NOT NULL UNIQUE,
    client_id         TEXT        NOT NULL UNIQUE,
    name              TEXT        NOT NULL,
    scopes            TEXT[]      NOT NULL,
    namespaces        TEXT[]      NOT NULL,
    kinds             TEXT[]      NOT NULL,
    created_by        TEXT        NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at        TIMESTAMPTZ NOT NULL,
    status            TEXT        NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active', 'rotating', 'expired', 'revoked')),
    rotated_from      UUID REFERENCES registry_credentials (id),
    cutover_at        TIMESTAMPTZ,
    revoked_at        TIMESTAMPTZ,
    last_used_at      TIMESTAMPTZ,
    CHECK (cardinality(scopes) BETWEEN 1 AND 3),
    CHECK (cardinality(namespaces) BETWEEN 1 AND 20),
    CHECK (cardinality(kinds) BETWEEN 1 AND 9),
    CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS registry_credentials_tenant_idx
    ON registry_credentials (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS registry_credentials_reap_idx
    ON registry_credentials (expires_at, cutover_at)
    WHERE status IN ('active', 'rotating');

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
    -- TEXT, not JSONB: the hash is taken over these exact bytes, and jsonb
    -- re-renders what it is given (key order, whitespace), so a jsonb column
    -- returns a different string than the one that was hashed.
    detail      TEXT NOT NULL DEFAULT '{}' CHECK (detail::jsonb IS NOT NULL),
    prev_hash   TEXT NOT NULL,
    hash        TEXT NOT NULL UNIQUE
);

CREATE INDEX IF NOT EXISTS audit_events_org_idx ON audit_events (org_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_actor_idx ON audit_events (actor_id, occurred_at DESC);

-- Submitted signup commands are private intake, not native or business masters.
CREATE TABLE IF NOT EXISTS customer_signups (
    id UUID PRIMARY KEY,
    product_key TEXT NOT NULL REFERENCES products(key) CHECK (product_key = 'helivanta'),
    tenant_id UUID NOT NULL UNIQUE,
    resource_id UUID NOT NULL UNIQUE,
    owner_subject TEXT NOT NULL UNIQUE,
    receipt_hash BYTEA NOT NULL CHECK (octet_length(receipt_hash) = 32),
    receipt_expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '7 days',
    receipt_verified BOOLEAN NOT NULL DEFAULT false,
    primary_credential_configured BOOLEAN NOT NULL DEFAULT false,
    proof_attempts INTEGER NOT NULL DEFAULT 0 CHECK (proof_attempts BETWEEN 0 AND 5),
    proof_window_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    mail_attempts INTEGER NOT NULL DEFAULT 0 CHECK (mail_attempts BETWEEN 0 AND 3),
    mail_window_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    intent_hash BYTEA NOT NULL CHECK (octet_length(intent_hash) = 32),
    owner_email_hash BYTEA NOT NULL CHECK (octet_length(owner_email_hash) = 32),
    input JSONB NOT NULL CHECK (jsonb_typeof(input) = 'object' AND octet_length(input::text) <= 8192),
    state TEXT NOT NULL DEFAULT 'recorded'
        CHECK (state IN ('recorded','identity_requested','existing_account','needs_support','ready')),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 20),
    retry_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    lease_until TIMESTAMPTZ,
    lease_id UUID,
    CHECK ((lease_id IS NULL) = (lease_until IS NULL)),
    error_code TEXT NOT NULL DEFAULT '' CHECK (length(error_code) <= 80),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE customer_signups ADD COLUMN IF NOT EXISTS primary_credential_configured BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE customer_signups ADD COLUMN IF NOT EXISTS existing_owner_subject TEXT NOT NULL DEFAULT ''
    CHECK (existing_owner_subject = '' OR existing_owner_subject ~ '^[A-Za-z0-9_-]{1,200}$');
ALTER TABLE customer_signups ADD COLUMN IF NOT EXISTS existing_owner_auth_time TIMESTAMPTZ;
ALTER TABLE customer_signups ADD COLUMN IF NOT EXISTS email_accepted_at TIMESTAMPTZ;
ALTER TABLE customer_signups ADD COLUMN IF NOT EXISTS email_provider_id TEXT NOT NULL DEFAULT '';
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='customer_signups'::regclass AND conname='customer_signup_email_acceptance_evidence') THEN
        ALTER TABLE customer_signups ADD CONSTRAINT customer_signup_email_acceptance_evidence
            CHECK ((email_accepted_at IS NULL) = (email_provider_id = '') AND
                (email_provider_id = '' OR email_provider_id ~ '^[A-Za-z0-9_-]{1,200}$'));
    END IF;
END $$;
CREATE OR REPLACE FUNCTION preserve_customer_signup_email_acceptance() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.email_accepted_at IS NOT NULL AND
        (NEW.email_accepted_at, NEW.email_provider_id) IS DISTINCT FROM (OLD.email_accepted_at, OLD.email_provider_id) THEN
        RAISE EXCEPTION 'Initial email acceptance evidence is immutable';
    END IF;
    RETURN NEW;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='customer_signups'::regclass AND tgname='customer_signup_email_acceptance_immutable') THEN
        CREATE TRIGGER customer_signup_email_acceptance_immutable BEFORE UPDATE ON customer_signups
            FOR EACH ROW EXECUTE FUNCTION preserve_customer_signup_email_acceptance();
    END IF;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid='customer_signups'::regclass AND conname='customer_signup_existing_owner_evidence') THEN
        ALTER TABLE customer_signups ADD CONSTRAINT customer_signup_existing_owner_evidence
            CHECK ((existing_owner_subject = '') = (existing_owner_auth_time IS NULL));
    END IF;
END $$;
CREATE INDEX IF NOT EXISTS customer_signups_created_at ON customer_signups(created_at);
-- Email is a delivery address; each tenant owns an independent native user.
DROP INDEX IF EXISTS customer_signups_new_owner_email_reservation;
DROP INDEX IF EXISTS customer_signups_email_reservation;
-- Non-unique delivery-abuse lookup; never an identity or account-reuse key.
CREATE INDEX CONCURRENTLY IF NOT EXISTS customer_signups_recipient_mail_budget
    ON customer_signups(owner_email_hash,tenant_id);
CREATE INDEX IF NOT EXISTS customer_signups_retry
    ON customer_signups(retry_at,id) WHERE state IN ('recorded','identity_requested');
CREATE INDEX IF NOT EXISTS customer_signups_unbound_legacy_retry
    ON customer_signups(retry_at,id) WHERE state='existing_account' AND existing_owner_subject='';
CREATE OR REPLACE FUNCTION preserve_customer_signup_intent() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF ROW(NEW.id,NEW.product_key,NEW.tenant_id,NEW.resource_id,NEW.owner_subject,NEW.intent_hash,NEW.owner_email_hash,NEW.input,NEW.created_at)
        IS DISTINCT FROM ROW(OLD.id,OLD.product_key,OLD.tenant_id,OLD.resource_id,OLD.owner_subject,OLD.intent_hash,OLD.owner_email_hash,OLD.input,OLD.created_at) THEN
        RAISE EXCEPTION 'customer signup intent is immutable' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'customer_signups'::regclass AND tgname = 'customer_signup_intent_immutable') THEN
        CREATE TRIGGER customer_signup_intent_immutable BEFORE UPDATE ON customer_signups
            FOR EACH ROW EXECUTE FUNCTION preserve_customer_signup_intent();
    END IF;
END $$;

CREATE OR REPLACE FUNCTION guard_customer_signup_existing_owner() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.existing_owner_subject <> '' OR NEW.existing_owner_auth_time IS NOT NULL THEN
            RAISE EXCEPTION 'existing signup owner requires authenticated continuation' USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;
    IF ROW(NEW.existing_owner_subject,NEW.existing_owner_auth_time)
        IS DISTINCT FROM ROW(OLD.existing_owner_subject,OLD.existing_owner_auth_time) THEN
        IF OLD.existing_owner_subject <> '' OR NEW.existing_owner_subject = ''
            OR OLD.state <> 'existing_account' OR NEW.state <> 'recorded'
            OR NEW.existing_owner_auth_time IS NULL
            OR NEW.existing_owner_auth_time < clock_timestamp() - interval '5 minutes'
            OR NEW.existing_owner_auth_time > clock_timestamp() + interval '30 seconds'
            OR NOT NEW.receipt_verified OR NOT NEW.primary_credential_configured
            OR NEW.receipt_hash = OLD.receipt_hash OR NEW.lease_id IS NOT NULL
            OR NEW.error_code <> ''
            OR current_setting('app.customer_signup_existing_owner', true) IS DISTINCT FROM NEW.existing_owner_subject THEN
            RAISE EXCEPTION 'existing signup owner binding is immutable or unverified' USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid='customer_signups'::regclass AND tgname='customer_signup_existing_owner_guard') THEN
        CREATE TRIGGER customer_signup_existing_owner_guard BEFORE INSERT OR UPDATE ON customer_signups
            FOR EACH ROW EXECUTE FUNCTION guard_customer_signup_existing_owner();
    END IF;
END $$;

-- Mailbox discovery is separate from signup receipts and native authentication.
CREATE TABLE IF NOT EXISTS account_discovery_challenges (
    id UUID PRIMARY KEY CHECK (substring(id::text,15,1) = '7'),
    browser_hash BYTEA NOT NULL CHECK (octet_length(browser_hash) = 32),
    source_hash BYTEA NOT NULL CHECK (octet_length(source_hash) = 32),
    email TEXT NOT NULL CHECK (length(email) BETWEEN 3 AND 200),
    code_hash BYTEA NOT NULL CHECK (octet_length(code_hash) = 32),
    attempts INTEGER NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 5),
    verified_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    expires_at TIMESTAMPTZ NOT NULL,
    CHECK (expires_at > created_at AND expires_at <= created_at + INTERVAL '10 minutes'),
    CHECK (verified_at IS NULL OR (verified_at >= created_at AND verified_at < expires_at))
);
CREATE INDEX IF NOT EXISTS account_discovery_recipient_budget ON account_discovery_challenges(email,created_at);
CREATE INDEX IF NOT EXISTS account_discovery_source_budget ON account_discovery_challenges(source_hash,created_at);
CREATE INDEX IF NOT EXISTS account_discovery_expiry ON account_discovery_challenges(created_at);

GRANT USAGE ON SCHEMA public TO onboarding;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    products, organizations, org_products, domains, idps, idempotency_keys,
    registry_tenants, registry_credentials, customer_signups, account_discovery_challenges
    TO onboarding;

-- The whole point: the application may append to the ledger and read it back,
-- and can do nothing else to it.
GRANT SELECT, INSERT ON audit_events TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM onboarding;
