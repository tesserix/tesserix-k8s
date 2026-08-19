-- ===========================================================================
-- 030 catalog — the fleet
-- ===========================================================================

-- Shared, platform-maintained vehicle identity. Tenants may select these rows
-- but cannot create their own spellings of the same model.
CREATE TABLE IF NOT EXISTS catalog.spec_model (
    id                     uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    make                   text NOT NULL,
    model                  text NOT NULL,
    variant                text NOT NULL DEFAULT '',
    model_year_from        int CHECK (model_year_from BETWEEN 1950 AND 2100),
    model_year_to          int CHECK (model_year_to BETWEEN 1950 AND 2100),
    class                  text NOT NULL CHECK (class IN ('scooter','motorcycle','car','suv','van','bicycle','ev')),
    fuel                   text CHECK (fuel IN ('petrol','diesel','electric','hybrid','cng')),
    transmission           text CHECK (transmission IN ('manual','automatic')),
    engine_cc              int CHECK (engine_cc IS NULL OR engine_cc > 0),
    licence_class_required text,
    attributes             jsonb NOT NULL DEFAULT '{}'::jsonb,
    vahan_model_code       text UNIQUE,
    active                 boolean NOT NULL DEFAULT true,
    created_at             timestamptz NOT NULL DEFAULT now(),
    CHECK (model_year_to IS NULL OR model_year_from IS NULL OR model_year_to >= model_year_from),
    UNIQUE (make, model, variant, model_year_from)
);

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
    spec_model_id          uuid REFERENCES catalog.spec_model(id) ON DELETE SET NULL,
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
    spec_actual            jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- Shown on the storefront card and asked for at the counter; optional
    -- because a shop should not be blocked from listing a vehicle it has not
    -- measured yet.
    seats                  smallint CHECK (seats BETWEEN 1 AND 60),
    fuel_capacity_l        numeric(5,1) CHECK (fuel_capacity_l > 0),
    mileage_kmpl           numeric(4,1) CHECK (mileage_kmpl > 0),
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
    verification_status    text NOT NULL DEFAULT 'unverified'
                           CONSTRAINT vehicle_verification_status_check
                           CHECK (verification_status IN ('unverified','verified','failed')),
    verification_source    text NOT NULL DEFAULT 'manual'
                           CONSTRAINT vehicle_verification_source_check
                           CHECK (verification_source IN ('manual','vahan')),
    verified_at            timestamptz,
    registered_owner_name  text,
    off_fleet_until        timestamptz,
    retired_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    -- Per tenant, not global: two shops can legitimately hold records for the
    -- same vehicle over its lifetime.
    UNIQUE (tenant_id, registration_no)
);

-- Replays upgrade clusters created before the fleet-management fields landed.
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS spec_model_id uuid REFERENCES catalog.spec_model(id) ON DELETE SET NULL;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS spec_actual jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS verification_status text NOT NULL DEFAULT 'unverified';
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS verification_source text NOT NULL DEFAULT 'manual';
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS verified_at timestamptz;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS registered_owner_name text;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS retired_at timestamptz;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS seats smallint;
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS fuel_capacity_l numeric(5,1);
ALTER TABLE catalog.vehicle ADD COLUMN IF NOT EXISTS mileage_kmpl numeric(4,1);

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_verification_status_check') THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_verification_status_check
            CHECK (verification_status IN ('unverified','verified','failed'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_verification_source_check') THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_verification_source_check
            CHECK (verification_source IN ('manual','vahan'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_seats_check') THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_seats_check
            CHECK (seats BETWEEN 1 AND 60);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_fuel_capacity_check') THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_fuel_capacity_check
            CHECK (fuel_capacity_l > 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_mileage_check') THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_mileage_check
            CHECK (mileage_kmpl > 0);
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS catalog.tenant_spec_override (
    id                     uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id              uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    spec_model_id          uuid NOT NULL REFERENCES catalog.spec_model(id) ON DELETE CASCADE,
    display_name           text,
    description            text,
    claimed_mileage_kmpl   numeric(6,2) CHECK (claimed_mileage_kmpl IS NULL OR claimed_mileage_kmpl > 0),
    attributes             jsonb NOT NULL DEFAULT '{}'::jsonb,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, spec_model_id)
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
    IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_category_id_fkey'
          AND conrelid = 'catalog.vehicle'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle DROP CONSTRAINT vehicle_category_id_fkey;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_category_fkey'
          AND conrelid = 'catalog.vehicle'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_category_fkey
            FOREIGN KEY (tenant_id, category_id)
            REFERENCES catalog.vehicle_category (tenant_id, id) ON DELETE RESTRICT;
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_pickup_point_id_fkey'
          AND conrelid = 'catalog.vehicle'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle DROP CONSTRAINT vehicle_pickup_point_id_fkey;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_pickup_point_fkey'
          AND conrelid = 'catalog.vehicle'::regclass
    ) THEN
        ALTER TABLE catalog.vehicle ADD CONSTRAINT vehicle_pickup_point_fkey
            FOREIGN KEY (tenant_id, pickup_point_id)
            REFERENCES identity.pickup_point (tenant_id, id)
            ON DELETE SET NULL (pickup_point_id);
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

-- Child records carry tenant_id too; their foreign keys must include it or an
-- FK check (which bypasses RLS) could point at another tenant's vehicle.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_document_vehicle_id_fkey'
                 AND conrelid = 'catalog.vehicle_document'::regclass) THEN
        ALTER TABLE catalog.vehicle_document DROP CONSTRAINT vehicle_document_vehicle_id_fkey;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_document_vehicle_fkey'
                     AND conrelid = 'catalog.vehicle_document'::regclass) THEN
        ALTER TABLE catalog.vehicle_document ADD CONSTRAINT vehicle_document_vehicle_fkey
            FOREIGN KEY (tenant_id, vehicle_id)
            REFERENCES catalog.vehicle (tenant_id, id) ON DELETE CASCADE;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_media_vehicle_id_fkey'
                 AND conrelid = 'catalog.vehicle_media'::regclass) THEN
        ALTER TABLE catalog.vehicle_media DROP CONSTRAINT vehicle_media_vehicle_id_fkey;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_media_vehicle_fkey'
                     AND conrelid = 'catalog.vehicle_media'::regclass) THEN
        ALTER TABLE catalog.vehicle_media ADD CONSTRAINT vehicle_media_vehicle_fkey
            FOREIGN KEY (tenant_id, vehicle_id)
            REFERENCES catalog.vehicle (tenant_id, id) ON DELETE CASCADE;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS vehicle_tenant_created_idx
    ON catalog.vehicle (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS vehicle_document_expiry_idx
    ON catalog.vehicle_document (tenant_id, expires_at)
    WHERE expires_at IS NOT NULL;

CREATE INDEX IF NOT EXISTS vehicle_spec_model_idx
    ON catalog.vehicle (spec_model_id) WHERE spec_model_id IS NOT NULL;

-- A small usable baseline. The catalogue is platform-owned and can be enriched
-- independently; these records make the pilot's real fleet selectable now.
INSERT INTO catalog.spec_model
    (make, model, variant, model_year_from, class, fuel, transmission, engine_cc, licence_class_required, attributes)
VALUES
    ('Royal Enfield', 'Himalayan 450', '', 2024, 'motorcycle', 'petrol', 'manual', 452, 'MCWG', '{"body_type":"adventure","service":{"interval_km":5000,"interval_days":180,"duration_hours":8,"safety_critical":true,"tasks":["Engine oil and filter","Drive chain","Brakes and tyres","Fasteners"]}}'),
    ('Royal Enfield', 'Himalayan 411', '', 2021, 'motorcycle', 'petrol', 'manual', 411, 'MCWG', '{"body_type":"adventure","service":{"interval_km":5000,"interval_days":180,"duration_hours":8,"safety_critical":true,"tasks":["Engine oil and filter","Drive chain","Brakes and tyres","Fasteners"]}}'),
    ('Royal Enfield', 'Classic 350', '', 2021, 'motorcycle', 'petrol', 'manual', 349, 'MCWG', '{"body_type":"cruiser","service":{"interval_km":5000,"interval_days":180,"duration_hours":6,"safety_critical":true,"tasks":["Engine oil","Drive chain","Brakes","Electrical check"]}}'),
    ('Royal Enfield', 'Interceptor 650', '', 2018, 'motorcycle', 'petrol', 'manual', 648, 'MCWG', '{"body_type":"roadster","service":{"interval_km":5000,"interval_days":180,"duration_hours":8,"safety_critical":true,"tasks":["Engine oil and filter","Valve check","Drive chain","Brakes and tyres"]}}'),
    ('KTM', '390 Duke', '', 2024, 'motorcycle', 'petrol', 'manual', 399, 'MCWG', '{"body_type":"street","service":{"interval_km":7500,"interval_days":180,"duration_hours":8,"safety_critical":true,"tasks":["Engine oil and filter","Cooling system","Drive chain","Brakes and tyres"]}}'),
    ('Suzuki', 'Access 125', '', 2020, 'scooter', 'petrol', 'automatic', 124, 'MCWG', '{"body_type":"scooter","service":{"interval_km":4000,"interval_days":180,"duration_hours":5,"safety_critical":true,"tasks":["Engine oil","CVT inspection","Brakes and tyres","Electrical check"]}}')
ON CONFLICT (make, model, variant, model_year_from) DO UPDATE
    SET attributes = catalog.spec_model.attributes || EXCLUDED.attributes;
