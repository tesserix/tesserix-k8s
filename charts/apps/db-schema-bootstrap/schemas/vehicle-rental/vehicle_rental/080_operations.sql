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

CREATE TABLE IF NOT EXISTS maintenance.part (
    id              uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id       uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    sku             text NOT NULL,
    name            text NOT NULL,
    stock           int NOT NULL DEFAULT 0,
    unit_cost_paise bigint NOT NULL DEFAULT 0,
    UNIQUE (tenant_id, sku)
);

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
