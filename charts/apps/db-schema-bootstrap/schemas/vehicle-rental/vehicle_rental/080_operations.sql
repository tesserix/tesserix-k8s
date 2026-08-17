-- ===========================================================================
-- 080 telematics, maintenance, incidents, partners, trips
-- ===========================================================================

CREATE TABLE IF NOT EXISTS telematics.device (
    id               uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id        uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id       uuid REFERENCES catalog.vehicle(id) ON DELETE SET NULL,
    imei             text NOT NULL UNIQUE,
    vendor           text,
    model            text,
    cert_fingerprint text,
    provisioned_at   timestamptz,
    last_seen_at     timestamptz,
    firmware         text
);

-- Partitioned daily, 30 days retained, then dropped. History lives in
-- ClickHouse; this table is only the window the live map reads.
CREATE TABLE IF NOT EXISTS telematics.position_hot (
    tenant_id  uuid NOT NULL,
    vehicle_id uuid NOT NULL,
    at         timestamptz NOT NULL,
    location   geography(Point, 4326) NOT NULL,
    speed_kph  real,
    heading    real,
    ignition   boolean,
    battery_v  real,
    hdop       real,
    source     text
) PARTITION BY RANGE (at);

DO $$
DECLARE
    d date := current_date;
    i int;
BEGIN
    FOR i IN -1..31 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS telematics.position_hot_%s PARTITION OF telematics.position_hot
               FOR VALUES FROM (%L) TO (%L)',
            to_char(d + i, 'YYYY_MM_DD'), (d + i)::date, (d + i + 1)::date);
    END LOOP;
END
$$;

-- BRIN, not btree: append-only and time-ordered, so BRIN is ~100x smaller here
-- and answers the only query anyone runs against it.
CREATE INDEX IF NOT EXISTS position_hot_at_brin
    ON telematics.position_hot USING brin (at);

-- One mutable row per vehicle, so the live map is one indexed scan rather than
-- an aggregate over a time series.
CREATE TABLE IF NOT EXISTS telematics.vehicle_state (
    vehicle_id    uuid PRIMARY KEY REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    tenant_id     uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    last_position geography(Point, 4326),
    last_at       timestamptz,
    ignition      boolean,
    odometer_km   int,
    fuel_pct      int CHECK (fuel_pct BETWEEN 0 AND 100),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS telematics.geofence (
    id        uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name      text NOT NULL,
    kind      text NOT NULL CHECK (kind IN ('allowed','restricted','depot','border')),
    geometry  geography(Polygon, 4326) NOT NULL,
    rules     jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE INDEX IF NOT EXISTS geofence_geometry_idx
    ON telematics.geofence USING gist (geometry);

CREATE TABLE IF NOT EXISTS telematics.telemetry_alert (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id      uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    booking_id      uuid REFERENCES booking.booking(id) ON DELETE SET NULL,
    kind            text NOT NULL,
    confidence      real,
    raised_at       timestamptz NOT NULL DEFAULT now(),
    acknowledged_by uuid,
    resolved_at     timestamptz
);

-- --- maintenance -----------------------------------------------------------

CREATE TABLE IF NOT EXISTS maintenance.service_schedule (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id     uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    category_id   uuid REFERENCES catalog.vehicle_category(id) ON DELETE CASCADE,
    vehicle_id    uuid REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    interval_km   int,
    interval_days int,
    tasks         jsonb NOT NULL DEFAULT '[]'::jsonb,
    CHECK (category_id IS NOT NULL OR vehicle_id IS NOT NULL)
);

ALTER TABLE maintenance.service_schedule
    ADD COLUMN IF NOT EXISTS spec_model_id uuid REFERENCES catalog.spec_model(id) ON DELETE CASCADE,
    ADD COLUMN IF NOT EXISTS name text NOT NULL DEFAULT 'Scheduled service',
    ADD COLUMN IF NOT EXISTS duration_hours int NOT NULL DEFAULT 8 CHECK (duration_hours BETWEEN 1 AND 168),
    ADD COLUMN IF NOT EXISTS safety_critical boolean NOT NULL DEFAULT false;

DO $$ BEGIN
    ALTER TABLE maintenance.service_schedule DROP CONSTRAINT IF EXISTS service_schedule_check;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'service_schedule_target_check'
           AND conrelid = 'maintenance.service_schedule'::regclass
    ) THEN
        ALTER TABLE maintenance.service_schedule
            ADD CONSTRAINT service_schedule_target_check
            CHECK (num_nonnulls(category_id, vehicle_id, spec_model_id) = 1);
    END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS service_schedule_vehicle_name_idx
    ON maintenance.service_schedule (tenant_id, vehicle_id, name) WHERE vehicle_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS service_schedule_model_name_idx
    ON maintenance.service_schedule (tenant_id, spec_model_id, name) WHERE spec_model_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS maintenance.garage_bay (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name        text NOT NULL,
    active      boolean NOT NULL DEFAULT true,
    description text,
    UNIQUE (tenant_id, name),
    UNIQUE (tenant_id, id)
);

CREATE TABLE IF NOT EXISTS maintenance.work_order (
    id                 uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id          uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id         uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE RESTRICT,
    kind               text NOT NULL CHECK (kind IN ('scheduled','breakdown','damage','recall','cleaning')),
    state              text NOT NULL DEFAULT 'open'
                       CHECK (state IN ('open','in_progress','awaiting_parts','closed','cancelled')),
    opened_at          timestamptz NOT NULL DEFAULT now(),
    closed_at          timestamptz,
    odometer_km        int,
    bay_id             uuid,
    partner_booking_id uuid,
    labour_paise       bigint NOT NULL DEFAULT 0,
    parts_paise        bigint NOT NULL DEFAULT 0,
    notes              text,
    checklist          jsonb NOT NULL DEFAULT '{}'::jsonb
);

ALTER TABLE maintenance.work_order
    ADD COLUMN IF NOT EXISTS schedule_id uuid REFERENCES maintenance.service_schedule(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS reservation_id uuid REFERENCES availability.reservation(id) ON DELETE SET NULL,
    ADD COLUMN IF NOT EXISTS period tstzrange,
    ADD COLUMN IF NOT EXISTS location_type text NOT NULL DEFAULT 'in_house',
    ADD COLUMN IF NOT EXISTS partner_name text;

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'work_order_location_type_check'
           AND conrelid = 'maintenance.work_order'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order ADD CONSTRAINT work_order_location_type_check
            CHECK (location_type IN ('in_house','partner'));
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'work_order_bay_fkey'
           AND conrelid = 'maintenance.work_order'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order ADD CONSTRAINT work_order_bay_fkey
            FOREIGN KEY (tenant_id, bay_id)
            REFERENCES maintenance.garage_bay (tenant_id, id) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'work_order_bay_no_overlap'
           AND conrelid = 'maintenance.work_order'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order ADD CONSTRAINT work_order_bay_no_overlap
            EXCLUDE USING gist (bay_id WITH =, period WITH &&)
            WHERE (bay_id IS NOT NULL AND state IN ('open','in_progress','awaiting_parts'));
    END IF;
END $$;

CREATE OR REPLACE FUNCTION maintenance.safety_service_overdue(p_vehicle_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = pg_catalog, public, catalog, maintenance
AS $$
    WITH configured AS (
        SELECT s.interval_km, s.interval_days, s.safety_critical,
               CASE WHEN s.vehicle_id IS NOT NULL THEN 0
                    WHEN s.spec_model_id IS NOT NULL THEN 1 ELSE 3 END AS priority
          FROM catalog.vehicle v
          JOIN maintenance.service_schedule s
            ON s.vehicle_id = v.id
            OR (s.vehicle_id IS NULL AND s.spec_model_id = v.spec_model_id)
            OR (s.vehicle_id IS NULL AND s.spec_model_id IS NULL AND s.category_id = v.category_id)
         WHERE v.id = p_vehicle_id
        UNION ALL
        SELECT (m.attributes #>> '{service,interval_km}')::int,
               (m.attributes #>> '{service,interval_days}')::int,
               (m.attributes #>> '{service,safety_critical}')::boolean, 2
          FROM catalog.vehicle v JOIN catalog.spec_model m ON m.id = v.spec_model_id
         WHERE v.id = p_vehicle_id AND m.attributes ? 'service'
    ), applicable AS (
        SELECT c.interval_km, c.interval_days, v.odometer_km, v.created_at,
               row_number() OVER (
                   ORDER BY c.priority
               ) AS preference
          FROM catalog.vehicle v CROSS JOIN configured c
         WHERE v.id = p_vehicle_id AND c.safety_critical
    ), last_service AS (
        SELECT odometer_km, closed_at
          FROM maintenance.work_order
         WHERE vehicle_id = p_vehicle_id AND kind = 'scheduled' AND state = 'closed'
         ORDER BY closed_at DESC NULLS LAST
         LIMIT 1
    )
    SELECT coalesce(bool_or(
        (a.interval_km IS NOT NULL AND
         a.odometer_km - coalesce(l.odometer_km, 0) >= a.interval_km)
        OR
        (a.interval_days IS NOT NULL AND
         coalesce(l.closed_at, a.created_at) + make_interval(days => a.interval_days) <= now())
    ), false)
      FROM applicable a
      LEFT JOIN last_service l ON true
     WHERE a.preference = 1
$$;

CREATE INDEX IF NOT EXISTS work_order_vehicle_history_idx
    ON maintenance.work_order (tenant_id, vehicle_id, closed_at DESC, opened_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS work_order_one_open_service_idx
    ON maintenance.work_order (tenant_id, vehicle_id)
    WHERE kind = 'scheduled' AND state IN ('open','in_progress','awaiting_parts');
CREATE UNIQUE INDEX IF NOT EXISTS work_order_tenant_id_idx
    ON maintenance.work_order (tenant_id, id);

CREATE TABLE IF NOT EXISTS maintenance.part (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    sku             text NOT NULL,
    name            text NOT NULL,
    stock           int NOT NULL DEFAULT 0,
    unit_cost_paise bigint NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, sku),
    UNIQUE (tenant_id, id)
);

CREATE UNIQUE INDEX IF NOT EXISTS part_tenant_id_idx
    ON maintenance.part (tenant_id, id);

CREATE TABLE IF NOT EXISTS maintenance.work_order_part (
    id               uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id        uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    work_order_id    uuid NOT NULL,
    part_id          uuid,
    description      text NOT NULL,
    quantity         numeric(10,2) NOT NULL CHECK (quantity > 0),
    unit_cost_paise  bigint NOT NULL CHECK (unit_cost_paise >= 0),
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS maintenance.work_order_photo (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id     uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    work_order_id uuid NOT NULL,
    object_key    text NOT NULL,
    caption       text,
    captured_at   timestamptz NOT NULL DEFAULT now()
);

DO $$ BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'work_order_part_order_fkey'
          AND conrelid = 'maintenance.work_order_part'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order_part ADD CONSTRAINT work_order_part_order_fkey
            FOREIGN KEY (tenant_id, work_order_id)
            REFERENCES maintenance.work_order (tenant_id, id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'work_order_part_part_fkey'
          AND conrelid = 'maintenance.work_order_part'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order_part ADD CONSTRAINT work_order_part_part_fkey
            FOREIGN KEY (tenant_id, part_id)
            REFERENCES maintenance.part (tenant_id, id) ON DELETE SET NULL (part_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'work_order_photo_order_fkey'
          AND conrelid = 'maintenance.work_order_photo'::regclass
    ) THEN
        ALTER TABLE maintenance.work_order_photo ADD CONSTRAINT work_order_photo_order_fkey
            FOREIGN KEY (tenant_id, work_order_id)
            REFERENCES maintenance.work_order (tenant_id, id) ON DELETE CASCADE;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS maintenance.fuel_log (
    id           uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id    uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id   uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    at           timestamptz NOT NULL DEFAULT now(),
    litres       numeric(8,3),
    amount_paise bigint NOT NULL DEFAULT 0,
    odometer_km  int,
    booking_id   uuid REFERENCES booking.booking(id) ON DELETE SET NULL,
    filled_by    uuid
);

-- --- incidents -------------------------------------------------------------

CREATE TABLE IF NOT EXISTS incidents.policy (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id     uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    vehicle_id    uuid NOT NULL REFERENCES catalog.vehicle(id) ON DELETE CASCADE,
    insurer       text NOT NULL,
    policy_no     text NOT NULL,
    type          text,
    idv_paise     bigint,
    excess_paise  bigint,
    valid_from    date,
    valid_to      date,
    UNIQUE (tenant_id, policy_no)
);

CREATE TABLE IF NOT EXISTS incidents.incident (
    id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id         uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    kind              text NOT NULL CHECK (kind IN ('accident','theft','damage','breakdown','fine','dispute')),
    vehicle_id        uuid REFERENCES catalog.vehicle(id) ON DELETE SET NULL,
    booking_id        uuid REFERENCES booking.booking(id) ON DELETE SET NULL,
    severity          text CHECK (severity IN ('minor','major','total')),
    occurred_at       timestamptz NOT NULL,
    location          geography(Point, 4326),
    description       text,
    evidence_pack_key text,
    fir_reference     text,
    state             text NOT NULL DEFAULT 'open'
                      CHECK (state IN ('open','investigating','claimed','settled','closed'))
);

CREATE TABLE IF NOT EXISTS incidents.claim (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    incident_id     uuid NOT NULL REFERENCES incidents.incident(id) ON DELETE CASCADE,
    policy_id       uuid REFERENCES incidents.policy(id) ON DELETE SET NULL,
    state           text NOT NULL DEFAULT 'draft'
                    CHECK (state IN ('draft','submitted','approved','rejected','settled')),
    claim_no        text,
    estimate_paise  bigint,
    approved_paise  bigint,
    settled_paise   bigint,
    excess_paise    bigint,
    excess_borne_by text CHECK (excess_borne_by IN ('tenant','customer','insurer')),
    timeline        jsonb NOT NULL DEFAULT '[]'::jsonb
);

-- --- partners --------------------------------------------------------------

-- One table, four kinds. A mechanic slot and a homestay night are the same
-- shape: a bookable resource, a period, a capacity, a token, a completion, a
-- payout. Splitting them would double the code for no modelled difference.
CREATE TABLE IF NOT EXISTS partners.partner_resource (
    id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id         uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    owner_type        text NOT NULL CHECK (owner_type IN ('tenant','platform','third_party')),
    kind              text NOT NULL CHECK (kind IN ('mechanic','stay','rsa','guide')),
    name              text NOT NULL,
    capabilities      text[] NOT NULL DEFAULT '{}',
    location          geography(Point, 4326),
    service_radius_km int,
    rate_card         jsonb NOT NULL DEFAULT '{}'::jsonb,
    active            boolean NOT NULL DEFAULT true
);

CREATE INDEX IF NOT EXISTS partner_resource_location_idx
    ON partners.partner_resource USING gist (location);

CREATE TABLE IF NOT EXISTS partners.partner_slot (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    resource_id uuid NOT NULL REFERENCES partners.partner_resource(id) ON DELETE CASCADE,
    period      tstzrange NOT NULL,
    capacity    int NOT NULL DEFAULT 1 CHECK (capacity > 0)
);

CREATE TABLE IF NOT EXISTS partners.partner_booking (
    id                   uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id            uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    resource_id          uuid NOT NULL REFERENCES partners.partner_resource(id) ON DELETE RESTRICT,
    requesting_tenant_id uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    subject_type         text NOT NULL CHECK (subject_type IN ('booking','work_order','trip','incident')),
    subject_id           uuid NOT NULL,
    period               tstzrange NOT NULL,
    state                text NOT NULL DEFAULT 'requested'
                         CHECK (state IN ('requested','confirmed','completed','cancelled','no_show')),
    token_paise          bigint NOT NULL DEFAULT 0,
    total_paise          bigint NOT NULL DEFAULT 0,
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- --- trips -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS trips.trip (
    id                    uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id             uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    name                  text NOT NULL,
    state                 text NOT NULL DEFAULT 'draft'
                          CHECK (state IN ('draft','open','running','completed','cancelled')),
    starts_on             date,
    days                  int CHECK (days > 0),
    published             boolean NOT NULL DEFAULT false,
    price_per_head_paise  bigint NOT NULL DEFAULT 0,
    capacity              int,
    route_geometry        geography(LineString, 4326)
);

CREATE TABLE IF NOT EXISTS trips.trip_stage (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    trip_id     uuid NOT NULL REFERENCES trips.trip(id) ON DELETE CASCADE,
    day         int NOT NULL CHECK (day > 0),
    from_wp     text,
    to_wp       text,
    distance_m  int,
    duration_s  int,
    geometry    geography(LineString, 4326),
    notes       text,
    UNIQUE (trip_id, day)
);

CREATE TABLE IF NOT EXISTS trips.trip_booking (
    id                    uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id             uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    trip_id               uuid NOT NULL REFERENCES trips.trip(id) ON DELETE RESTRICT,
    organiser_customer_id uuid NOT NULL REFERENCES kyc.customer(id) ON DELETE RESTRICT,
    head_count            int NOT NULL CHECK (head_count > 0),
    state                 text NOT NULL DEFAULT 'pending'
                          CHECK (state IN ('pending','confirmed','cancelled','completed')),
    total_paise           bigint NOT NULL DEFAULT 0
);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_trip_fkey') THEN
        ALTER TABLE booking.booking
            ADD CONSTRAINT booking_trip_fkey
            FOREIGN KEY (trip_id) REFERENCES trips.trip(id) ON DELETE SET NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_gps_device_fkey') THEN
        ALTER TABLE catalog.vehicle
            ADD CONSTRAINT vehicle_gps_device_fkey
            FOREIGN KEY (gps_device_id) REFERENCES telematics.device(id) ON DELETE SET NULL;
    END IF;
END
$$;
