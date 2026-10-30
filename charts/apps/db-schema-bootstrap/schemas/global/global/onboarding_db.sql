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

GRANT USAGE ON SCHEMA public TO onboarding;

GRANT SELECT, INSERT, UPDATE, DELETE ON
    products, organizations, org_products, domains, idps, idempotency_keys,
    registry_tenants, registry_credentials
    TO onboarding;

-- The whole point: the application may append to the ledger and read it back,
-- and can do nothing else to it.
GRANT SELECT, INSERT ON audit_events TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON audit_events FROM onboarding;

-- Durable Staff creation input outlives the expiring request cache. Retain the
-- tenant/product references on offboarding; deleting an identity is no reason
-- to discard whether its creation was already dispatched.
CREATE TABLE IF NOT EXISTS staff_identity_commands (
    id                  UUID PRIMARY KEY CHECK (substring(id::text, 15, 1) = '7'),
    org_id              UUID NOT NULL REFERENCES organizations (id) ON DELETE RESTRICT,
    product_key         TEXT NOT NULL REFERENCES products (key) ON DELETE RESTRICT,
    machine_subject     TEXT NOT NULL CHECK (machine_subject ~ '^[A-Za-z0-9_-]{1,200}$'),
    actor_subject       TEXT NOT NULL CHECK (actor_subject ~ '^[A-Za-z0-9_-]{1,200}$'),
    provider_org_id     TEXT NOT NULL CHECK (provider_org_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    provider_project_id TEXT NOT NULL CHECK (provider_project_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    provider_user_id    TEXT NOT NULL UNIQUE CHECK (provider_user_id ~ '^[A-Za-z0-9_-]{1,200}$'),
    binding_nonce       TEXT NOT NULL UNIQUE CHECK (binding_nonce ~ '^[A-Za-z0-9_-]{16,200}$'),
    email               TEXT NOT NULL CHECK (length(email) BETWEEN 3 AND 200
                            AND email = btrim(email) AND email !~ '[[:cntrl:]]'),
    given_name          TEXT NOT NULL CHECK (length(given_name) BETWEEN 1 AND 200
                            AND given_name = btrim(given_name) AND given_name !~ '[[:cntrl:]]'),
    family_name         TEXT NOT NULL CHECK (length(family_name) BETWEEN 1 AND 200
                            AND family_name = btrim(family_name) AND family_name !~ '[[:cntrl:]]'),
    reason              TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id, provider_user_id)
);

CREATE INDEX IF NOT EXISTS staff_identity_commands_org_idx
    ON staff_identity_commands (org_id, product_key, created_at DESC, id DESC);
CREATE INDEX IF NOT EXISTS staff_identity_commands_product_idx
    ON staff_identity_commands (product_key, created_at DESC, id DESC);

GRANT SELECT, INSERT ON staff_identity_commands TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_commands FROM onboarding;

-- Never expire or delete dispatch claims: an uncertain response may conceal a
-- successful provider creation, including one subsequently deleted upstream.
CREATE TABLE IF NOT EXISTS staff_identity_dispatches (
    command_id UUID PRIMARY KEY REFERENCES staff_identity_commands (id) ON DELETE RESTRICT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

GRANT SELECT, INSERT ON staff_identity_dispatches TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_dispatches FROM onboarding;

CREATE TABLE IF NOT EXISTS staff_identity_creations (
    command_id          UUID PRIMARY KEY REFERENCES staff_identity_dispatches (command_id) ON DELETE RESTRICT,
    provider_user_id    TEXT NOT NULL,
    -- Preserve the provider timestamp's exact nanoseconds; PostgreSQL native
    -- timestamps round to microseconds and cannot replay this source fact.
    source_creation_time TEXT NOT NULL CHECK (
        length(source_creation_time) BETWEEN 20 AND 30
        AND source_creation_time ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?Z$'
        AND source_creation_time::timestamptz > '0001-01-01T00:00:00Z'::timestamptz
    ),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (command_id, provider_user_id)
        REFERENCES staff_identity_commands (id, provider_user_id) ON DELETE RESTRICT
);

GRANT SELECT, INSERT ON staff_identity_creations TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_creations FROM onboarding;

-- A new command cannot bypass an unresolved create by changing its command ID.
-- The root is permanent; reviewed replacements must retain explicit lineage.
CREATE UNIQUE INDEX IF NOT EXISTS staff_identity_commands_contact_idx
    ON staff_identity_commands (id, provider_org_id, email);

CREATE TABLE IF NOT EXISTS staff_identity_contact_claims (
    root_command_id UUID PRIMARY KEY,
    provider_org_id TEXT NOT NULL,
    email           TEXT NOT NULL,
    -- Computed by the owner with Go strings.ToLower, as in Zitadel v4.15.3
    -- username constraints. Never use address-provider-specific rewriting.
    email_key       TEXT NOT NULL CHECK (length(email_key) BETWEEN 3 AND 200
                         AND email_key = btrim(email_key) AND email_key !~ '[[:cntrl:]]'),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (provider_org_id, email_key),
    FOREIGN KEY (root_command_id, provider_org_id, email)
        REFERENCES staff_identity_commands (id, provider_org_id, email) ON DELETE RESTRICT
);

GRANT SELECT, INSERT ON staff_identity_contact_claims TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_contact_claims FROM onboarding;

CREATE INDEX IF NOT EXISTS audit_events_staff_command_idx
    ON audit_events (org_id, product_key, actor_id, target, seq DESC)
    WHERE actor_type = 'product' AND action LIKE 'staff.identity.%';

-- Ephemeral pagination positions, not authority or immutable business facts.
CREATE TABLE IF NOT EXISTS staff_identity_history_cursors (
    token_hash  TEXT PRIMARY KEY CHECK (token_hash ~ '^[0-9a-f]{64}$'),
    command_id  UUID NOT NULL REFERENCES staff_identity_commands(id) ON DELETE CASCADE,
    scope_hash  TEXT NOT NULL CHECK (scope_hash ~ '^[0-9a-f]{64}$'),
    before_seq  BIGINT NOT NULL CHECK (before_seq > 0),
    expires_at  TIMESTAMPTZ NOT NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (expires_at > created_at)
);
CREATE INDEX IF NOT EXISTS staff_identity_history_cursors_expiry_idx
    ON staff_identity_history_cursors (expires_at, token_hash);
CREATE INDEX IF NOT EXISTS staff_identity_history_cursors_command_idx
    ON staff_identity_history_cursors (command_id);
GRANT SELECT, INSERT, DELETE ON staff_identity_history_cursors TO onboarding;
REVOKE UPDATE, TRUNCATE ON staff_identity_history_cursors FROM onboarding;
-- PostgreSQL row locking needs an UPDATE privilege; RLS below rejects every
-- actual update while allowing continuation/collector locks.
GRANT UPDATE (token_hash) ON staff_identity_history_cursors TO onboarding;
ALTER TABLE staff_identity_history_cursors ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_identity_history_cursors FORCE ROW LEVEL SECURITY;
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_policies WHERE schemaname='public'
                   AND tablename='staff_identity_history_cursors' AND policyname='staff_history_cursor_select') THEN
        CREATE POLICY staff_history_cursor_select ON staff_identity_history_cursors
            FOR SELECT TO onboarding USING (true);
    END IF;
    IF NOT EXISTS (SELECT FROM pg_policies WHERE schemaname='public'
                   AND tablename='staff_identity_history_cursors' AND policyname='staff_history_cursor_insert') THEN
        CREATE POLICY staff_history_cursor_insert ON staff_identity_history_cursors
            FOR INSERT TO onboarding WITH CHECK (true);
    END IF;
    IF NOT EXISTS (SELECT FROM pg_policies WHERE schemaname='public'
                   AND tablename='staff_identity_history_cursors' AND policyname='staff_history_cursor_delete_expired') THEN
        CREATE POLICY staff_history_cursor_delete_expired ON staff_identity_history_cursors
            FOR DELETE TO onboarding USING (expires_at<=now());
    END IF;
    IF NOT EXISTS (SELECT FROM pg_policies WHERE schemaname='public'
                   AND tablename='staff_identity_history_cursors' AND policyname='staff_history_cursor_lock_only') THEN
        CREATE POLICY staff_history_cursor_lock_only ON staff_identity_history_cursors
            FOR UPDATE TO onboarding USING (true) WITH CHECK (false);
    END IF;
END $$;

-- Recovery retains the original initiator and separate maker/reviewer facts.
CREATE UNIQUE INDEX IF NOT EXISTS staff_identity_commands_recovery_actor_idx
    ON staff_identity_commands (id, actor_subject, provider_user_id);

CREATE TABLE IF NOT EXISTS staff_identity_recovery_requests (
    id                        UUID PRIMARY KEY CHECK (substring(id::text, 15, 1) = '7'),
    command_id                UUID NOT NULL REFERENCES staff_identity_dispatches(command_id) ON DELETE RESTRICT,
    original_actor_subject    TEXT NOT NULL,
    original_user_id          TEXT NOT NULL,
    requested_by              TEXT NOT NULL CHECK (requested_by ~ '^[A-Za-z0-9_-]{1,200}$'),
    requested_action          TEXT NOT NULL CHECK (requested_action IN ('close_unresolved', 'replace')),
    replacement_actor_subject TEXT NOT NULL DEFAULT '',
    reason                    TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000
                                  AND reason !~ '[[:cntrl:]]'),
    evidence_reference        TEXT NOT NULL CHECK (evidence_reference ~ '^[A-Za-z0-9][A-Za-z0-9._:/-]{0,199}$'),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((requested_action = 'close_unresolved' AND replacement_actor_subject = '')
        OR (requested_action = 'replace' AND replacement_actor_subject ~ '^[A-Za-z0-9_-]{1,200}$')),
    FOREIGN KEY (command_id, original_actor_subject, original_user_id)
        REFERENCES staff_identity_commands (id, actor_subject, provider_user_id) ON DELETE RESTRICT,
    UNIQUE (id, command_id, requested_by, original_actor_subject, original_user_id, requested_action, replacement_actor_subject)
);
CREATE INDEX IF NOT EXISTS staff_identity_recovery_requests_command_idx
    ON staff_identity_recovery_requests(command_id, created_at DESC, id DESC);
GRANT SELECT, INSERT ON staff_identity_recovery_requests TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_recovery_requests FROM onboarding;

CREATE TABLE IF NOT EXISTS staff_identity_recovery_decisions (
    request_id                UUID PRIMARY KEY,
    command_id                UUID NOT NULL,
    requested_by              TEXT NOT NULL,
    original_actor_subject    TEXT NOT NULL,
    original_user_id          TEXT NOT NULL,
    requested_action          TEXT NOT NULL,
    replacement_actor_subject TEXT NOT NULL DEFAULT '',
    reviewed_by               TEXT NOT NULL CHECK (reviewed_by ~ '^[A-Za-z0-9_-]{1,200}$'),
    decision                  TEXT NOT NULL CHECK (decision IN ('approved', 'rejected')),
    reason                    TEXT NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000
                                  AND reason !~ '[[:cntrl:]]'),
    created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (reviewed_by <> requested_by AND reviewed_by <> original_actor_subject
        AND reviewed_by <> replacement_actor_subject AND reviewed_by <> original_user_id),
    FOREIGN KEY (request_id, command_id, requested_by, original_actor_subject, original_user_id, requested_action, replacement_actor_subject)
        REFERENCES staff_identity_recovery_requests
            (id, command_id, requested_by, original_actor_subject, original_user_id, requested_action, replacement_actor_subject)
        ON DELETE RESTRICT
);
CREATE UNIQUE INDEX IF NOT EXISTS staff_identity_recovery_decisions_replacement_idx
    ON staff_identity_recovery_decisions(command_id)
    WHERE decision = 'approved' AND requested_action = 'replace';
CREATE INDEX IF NOT EXISTS staff_identity_recovery_decisions_command_idx
    ON staff_identity_recovery_decisions(command_id, created_at DESC, request_id DESC);
GRANT SELECT, INSERT ON staff_identity_recovery_decisions TO onboarding;
REVOKE UPDATE, DELETE, TRUNCATE ON staff_identity_recovery_decisions FROM onboarding;
