-- ===========================================================================
-- 020 identity — the rental shop, its staff, and where riders collect vehicles
-- ===========================================================================

CREATE TABLE IF NOT EXISTS identity.tenant (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    type           text NOT NULL DEFAULT 'shop' CHECK (type IN ('shop','platform','partner')),
    -- The slug IS the hostname: <slug>.tesserix.app and <slug>-admin.tesserix.app.
    -- Reserved words are rejected here rather than in the app, because the app
    -- is not the only writer.
    slug           citext NOT NULL UNIQUE
                   CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$'
                          AND slug NOT IN ('www','api','auth','admin','rentme','app','static','cdn')
                          AND slug NOT LIKE '%-admin'),
    legal_name     text NOT NULL,
    display_name   text NOT NULL,
    zitadel_org_id text UNIQUE,
    gstin          text,
    pan            text,
    state          text,
    status         text NOT NULL DEFAULT 'onboarding'
                   CHECK (status IN ('onboarding','active','suspended','closed')),
    -- A cache of "current". History is never lost — it lives in
    -- payments.fee_schedule with an effective date.
    fee_bps        int NOT NULL DEFAULT 699 CHECK (fee_bps BETWEEN 0 AND 10000),
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS identity.tenant_link (
    from_tenant_id uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    to_tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    kind           text NOT NULL CHECK (kind IN ('fleet_share','partner','group')),
    scopes         text[] NOT NULL DEFAULT '{}',
    state          text NOT NULL DEFAULT 'pending'
                   CHECK (state IN ('pending','active','revoked')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (from_tenant_id, to_tenant_id, kind),
    CHECK (from_tenant_id <> to_tenant_id)
);

CREATE TABLE IF NOT EXISTS identity.staff (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    zitadel_user_id text NOT NULL,
    name            text NOT NULL,
    phone           text,
    roles           text[] NOT NULL DEFAULT '{}',
    status          text NOT NULL DEFAULT 'active'
                    CHECK (status IN ('invited','active','suspended')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, zitadel_user_id)
);

CREATE TABLE IF NOT EXISTS identity.pickup_point (
    id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id    uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name         text NOT NULL,
    address      text,
    location     geography(Point, 4326),
    hours        jsonb NOT NULL DEFAULT '{}'::jsonb,
    instructions text,
    active       boolean NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS pickup_point_location_idx
    ON identity.pickup_point USING gist (location);
CREATE INDEX IF NOT EXISTS staff_tenant_created_idx
    ON identity.staff (tenant_id, created_at DESC);
