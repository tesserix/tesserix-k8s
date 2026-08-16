-- ===========================================================================
-- 090 storefront
-- ===========================================================================

-- theme and blocks are validated JSONB against a versioned schema before they
-- are written. No string from a tenant is ever interpolated into CSS or HTML
-- (ADR-0008) — theming is data, not code.
CREATE TABLE IF NOT EXISTS storefront.storefront (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id      uuid NOT NULL UNIQUE REFERENCES identity.tenant(id) ON DELETE CASCADE,
    template       text NOT NULL DEFAULT 'rider',
    theme          jsonb NOT NULL DEFAULT '{}'::jsonb,
    theme_version  int NOT NULL DEFAULT 1,
    locales        text[] NOT NULL DEFAULT '{en}',
    default_locale text NOT NULL DEFAULT 'en',
    published_at   timestamptz,
    draft          jsonb NOT NULL DEFAULT '{}'::jsonb
);

-- A shop always keeps its <slug>.tesserix.app host — it is the fallback that
-- works when a custom domain's certificate or DNS does not.
CREATE TABLE IF NOT EXISTS storefront.storefront_domain (
    id                 uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id          uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    host               citext NOT NULL UNIQUE,
    kind               text NOT NULL CHECK (kind IN ('platform','custom')),
    verification_token text,
    verified_at        timestamptz,
    cert_state         text NOT NULL DEFAULT 'pending'
                       CHECK (cert_state IN ('pending','issuing','ready','failed')),
    created_at         timestamptz NOT NULL DEFAULT now()
);

-- Exactly one platform host per tenant, so host → tenant resolution can never
-- be ambiguous at request time.
CREATE UNIQUE INDEX IF NOT EXISTS storefront_domain_one_platform_host
    ON storefront.storefront_domain (tenant_id)
    WHERE kind = 'platform';

CREATE TABLE IF NOT EXISTS storefront.storefront_page (
    id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id    uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    slug         text NOT NULL,
    locale       text NOT NULL DEFAULT 'en',
    title        text NOT NULL,
    blocks       jsonb NOT NULL DEFAULT '[]'::jsonb,
    seo          jsonb NOT NULL DEFAULT '{}'::jsonb,
    published_at timestamptz,
    UNIQUE (tenant_id, slug, locale)
);

-- support.conversation is a pointer, not the transcript. Messages live in
-- MongoDB (ADR-0012); this row is what a booking joins to.
CREATE TABLE IF NOT EXISTS support.conversation (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    customer_id     uuid REFERENCES kyc.customer(id) ON DELETE SET NULL,
    booking_id      uuid REFERENCES booking.booking(id) ON DELETE SET NULL,
    channel         text NOT NULL CHECK (channel IN ('chat','whatsapp','email','phone')),
    mongo_thread_id text NOT NULL,
    state           text NOT NULL DEFAULT 'open'
                    CHECK (state IN ('open','waiting','resolved','closed')),
    opened_at       timestamptz NOT NULL DEFAULT now(),
    closed_at       timestamptz,
    UNIQUE (mongo_thread_id)
);

CREATE INDEX IF NOT EXISTS conversation_tenant_opened_idx
    ON support.conversation (tenant_id, opened_at DESC);
