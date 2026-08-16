-- ===========================================================================
-- 030 catalog — the fleet
-- ===========================================================================

CREATE TABLE IF NOT EXISTS catalog.vehicle_category (
    id                     uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id              uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name                   text NOT NULL,
    class                  text NOT NULL CHECK (class IN ('scooter','motorcycle','car','suv','van','bicycle','ev')),
    licence_class_required text,
    default_rate_plan_id   uuid,
    images                 text[] NOT NULL DEFAULT '{}',
    created_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name)
);

CREATE TABLE IF NOT EXISTS catalog.vehicle (
    id                     uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id              uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    category_id            uuid NOT NULL REFERENCES catalog.vehicle_category(id) ON DELETE RESTRICT,
    registration_no        text NOT NULL,
    vin                    text,
    make                   text,
    model                  text,
    variant                text,
    year                   int CHECK (year BETWEEN 1950 AND 2100),
    fuel                   text CHECK (fuel IN ('petrol','diesel','electric','hybrid','cng')),
    transmission           text CHECK (transmission IN ('manual','automatic')),
    engine_cc              int,
    colour                 text,
    odometer_km            int NOT NULL DEFAULT 0 CHECK (odometer_km >= 0),
    acquisition_cost_paise bigint CHECK (acquisition_cost_paise >= 0),
    acquired_at            date,
    useful_life_months     int,
    status                 text NOT NULL DEFAULT 'draft'
                           CHECK (status IN ('draft','active','off_fleet','maintenance','sold','stolen')),
    pickup_point_id        uuid REFERENCES identity.pickup_point(id) ON DELETE SET NULL,
    gps_device_id          uuid,
    -- Derived from vehicle_document expiry and materialised, so availability can
    -- filter on it without joining four document rows per vehicle per search.
    compliance_status      text NOT NULL DEFAULT 'unknown'
                           CHECK (compliance_status IN ('unknown','compliant','expiring','expired')),
    off_fleet_until        timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    -- Per tenant, not global: two shops can legitimately hold records for the
    -- same vehicle over its lifetime.
    UNIQUE (tenant_id, registration_no)
);

-- Redundant against the primary key, and load-bearing anyway: it is the target
-- other modules point a composite (tenant_id, vehicle_id) FK at. A foreign key
-- check runs with RLS bypassed, so a plain FK to id lets one tenant reference
-- another tenant's vehicle.
DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'vehicle_tenant_id_id_key'
           AND conrelid = 'catalog.vehicle'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle
            ADD CONSTRAINT vehicle_tenant_id_id_key UNIQUE (tenant_id, id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'vehicle_category_tenant_id_id_key'
           AND conrelid = 'catalog.vehicle_category'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle_category
            ADD CONSTRAINT vehicle_category_tenant_id_id_key UNIQUE (tenant_id, id);
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS catalog.vehicle_document (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id      uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    kind            text NOT NULL CHECK (kind IN ('rc','insurance','puc','permit','fitness','tax')),
    number          text,
    issued_at       date,
    expires_at      date,
    verified_source text CHECK (verified_source IN ('manual','vahan','digilocker')),
    object_key      text,
    created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS catalog.vehicle_media (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id  uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('photo','video','document')),
    object_key text NOT NULL,
    position   int NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS vehicle_tenant_created_idx
    ON catalog.vehicle (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS vehicle_document_expiry_idx
    ON catalog.vehicle_document (tenant_id, expires_at)
    WHERE expires_at IS NOT NULL;
