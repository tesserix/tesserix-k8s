-- ===========================================================================
-- 040 pricing
-- ===========================================================================

CREATE TABLE IF NOT EXISTS pricing.rate_plan (
    id                       uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id                uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name                     text NOT NULL,
    version                  int NOT NULL DEFAULT 1,
    effective_from           timestamptz NOT NULL DEFAULT now(),
    effective_to             timestamptz,
    base_daily_paise         bigint NOT NULL CHECK (base_daily_paise >= 0),
    hourly_paise             bigint CHECK (hourly_paise >= 0),
    weekly_paise             bigint CHECK (weekly_paise >= 0),
    monthly_paise            bigint CHECK (monthly_paise >= 0),
    km_included_per_day      int,
    per_km_overage_paise     bigint CHECK (per_km_overage_paise >= 0),
    fuel_policy              text CHECK (fuel_policy IN ('full_to_full','same_to_same','prepaid')),
    deposit_paise            bigint NOT NULL DEFAULT 0 CHECK (deposit_paise >= 0),
    late_fee_per_hour_paise  bigint NOT NULL DEFAULT 0 CHECK (late_fee_per_hour_paise >= 0),
    min_days                 int,
    max_days                 int,
    created_at               timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name, version),
    CHECK (effective_to IS NULL OR effective_to > effective_from)
);

CREATE TABLE IF NOT EXISTS pricing.rate_modifier (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id      uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    rate_plan_id   uuid NOT NULL REFERENCES pricing.rate_plan(id) ON DELETE CASCADE,
    kind           text NOT NULL CHECK (kind IN ('season','weekend','holiday','long_stay','promo')),
    from_date      date,
    to_date        date,
    -- Bit 0 = Monday. A mask rather than seven booleans, because every read is
    -- "does today match" and that is one AND.
    dow_mask       int NOT NULL DEFAULT 127 CHECK (dow_mask BETWEEN 0 AND 127),
    multiplier_bps int CHECK (multiplier_bps >= 0),
    flat_paise     bigint
);

CREATE TABLE IF NOT EXISTS pricing.addon (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name        text NOT NULL,
    price_paise bigint NOT NULL CHECK (price_paise >= 0),
    per         text NOT NULL DEFAULT 'booking' CHECK (per IN ('booking','day','km','person')),
    stock       int,
    active      boolean NOT NULL DEFAULT true,
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS pricing.coupon (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id  uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    code       citext NOT NULL,
    kind       text NOT NULL CHECK (kind IN ('percent','flat')),
    value      bigint NOT NULL CHECK (value >= 0),
    valid_from timestamptz,
    valid_to   timestamptz,
    max_uses   int,
    used_count int NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, code)
);

-- A quote stores its fully resolved breakdown — every line, every multiplier,
-- every rounding. A dispute six months later is settled by reading the quote,
-- not by replaying today's pricing rules against yesterday's dates. This is the
-- single most important modelling decision in pricing.
CREATE TABLE IF NOT EXISTS pricing.quote (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id     uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id    uuid REFERENCES catalog.vehicle(id) ON DELETE SET NULL,
    category_id   uuid REFERENCES catalog.vehicle_category(id) ON DELETE SET NULL,
    period        tstzrange NOT NULL,
    breakdown     jsonb NOT NULL,
    total_paise   bigint NOT NULL CHECK (total_paise >= 0),
    deposit_paise bigint NOT NULL DEFAULT 0 CHECK (deposit_paise >= 0),
    currency      char(3) NOT NULL DEFAULT 'INR',
    expires_at    timestamptz NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    CHECK (vehicle_id IS NOT NULL OR category_id IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS quote_tenant_created_idx
    ON pricing.quote (tenant_id, created_at DESC);

-- Deferred from 030: the FK would have required pricing before catalog.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_category_default_rate_plan_fkey'
    ) THEN
        ALTER TABLE catalog.vehicle_category
            ADD CONSTRAINT vehicle_category_default_rate_plan_fkey
            FOREIGN KEY (default_rate_plan_id)
            REFERENCES pricing.rate_plan(id) ON DELETE SET NULL;
    END IF;
END
$$;
