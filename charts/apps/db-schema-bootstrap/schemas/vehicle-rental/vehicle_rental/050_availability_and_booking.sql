-- ===========================================================================
-- 050 availability and booking
-- ===========================================================================

-- The exclusion constraint below is how double-booking is prevented. Not
-- application logic, not a SELECT ... FOR UPDATE dance, not optimistic retries —
-- a database constraint that cannot be defeated by a race, a retry, a concurrent
-- admin action, or a future developer who forgets. A conflicting insert raises
-- 23P01, which the handler maps to 409 vehicle_unavailable.
--
-- Buffer time between rentals (cleaning, refuelling) is modelled by extending
-- `period`, never by arithmetic at read time.
CREATE TABLE IF NOT EXISTS availability.reservation (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id  uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    -- The FK is composite and lives below, not here: see reservation_vehicle_fkey.
    vehicle_id uuid NOT NULL,
    booking_id uuid,
    kind       text NOT NULL CHECK (kind IN ('hold','confirmed','active','block','service')),
    period     tstzrange NOT NULL,
    -- Holds expire in 15 minutes and are swept by the worker, with a Temporal
    -- timer as backstop. A swept hold is deleted, not soft-deleted, so it leaves
    -- the constraint rather than lingering inside it.
    expires_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT reservation_no_overlap EXCLUDE USING gist (
        vehicle_id WITH =,
        period     WITH &&
    ),
    CHECK (kind <> 'hold' OR expires_at IS NOT NULL)
);

-- RLS does not apply to foreign key checks — they run as the referenced table's
-- owner. A plain FK to catalog.vehicle(id) therefore lets tenant B reserve
-- tenant A's vehicle by guessing its id, which RLS cannot see and the exclusion
-- constraint happily allows. Carrying tenant_id into the FK closes it in the
-- database rather than in every future call site.
DO $$ BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'reservation_vehicle_id_fkey'
           AND conrelid = 'availability.reservation'::regclass
    ) THEN
        ALTER TABLE availability.reservation DROP CONSTRAINT reservation_vehicle_id_fkey;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'reservation_vehicle_fkey'
           AND conrelid = 'availability.reservation'::regclass
    ) THEN
        ALTER TABLE availability.reservation
            ADD CONSTRAINT reservation_vehicle_fkey
            FOREIGN KEY (tenant_id, vehicle_id)
            REFERENCES catalog.vehicle (tenant_id, id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS reservation_expiry_sweep_idx
    ON availability.reservation (expires_at)
    WHERE kind = 'hold';

CREATE TABLE IF NOT EXISTS booking.booking (
    id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id           uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    reference           text NOT NULL,
    -- All three FKs are composite and live below: see booking_customer_fkey.
    customer_id         uuid NOT NULL,
    vehicle_id          uuid,
    category_id         uuid,
    quote_id            uuid REFERENCES pricing.quote(id) ON DELETE RESTRICT,
    -- A cache of the last booking_event. The event log is the truth.
    state               text NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending','confirmed','active','completed','cancelled','no_show')),
    period              tstzrange NOT NULL,
    pickup_point_id     uuid REFERENCES identity.pickup_point(id) ON DELETE SET NULL,
    dropoff_point_id    uuid REFERENCES identity.pickup_point(id) ON DELETE SET NULL,
    agreement_id        uuid,
    total_paise         bigint NOT NULL DEFAULT 0 CHECK (total_paise >= 0),
    deposit_paise       bigint NOT NULL DEFAULT 0 CHECK (deposit_paise >= 0),
    currency            char(3) NOT NULL DEFAULT 'INR',
    channel             text NOT NULL DEFAULT 'storefront'
                        CHECK (channel IN ('storefront','counter','partner','api')),
    -- UC-33's linked continuation: a rider extending into a second vehicle.
    replaced_booking_id uuid REFERENCES booking.booking(id) ON DELETE SET NULL,
    trip_id             uuid,
    created_by          uuid,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, reference)
);

-- Same reasoning as reservation_vehicle_fkey: a booking takes a vehicle and a
-- category id straight from a request, and only a composite FK keeps them
-- inside the tenant. customer_id gets the same treatment in 060, where
-- kyc.customer exists.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_vehicle_id_fkey'
                 AND conrelid = 'booking.booking'::regclass) THEN
        ALTER TABLE booking.booking DROP CONSTRAINT booking_vehicle_id_fkey;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_category_id_fkey'
                 AND conrelid = 'booking.booking'::regclass) THEN
        ALTER TABLE booking.booking DROP CONSTRAINT booking_category_id_fkey;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_vehicle_fkey'
                     AND conrelid = 'booking.booking'::regclass) THEN
        ALTER TABLE booking.booking ADD CONSTRAINT booking_vehicle_fkey
            FOREIGN KEY (tenant_id, vehicle_id)
            REFERENCES catalog.vehicle (tenant_id, id) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_category_fkey'
                     AND conrelid = 'booking.booking'::regclass) THEN
        ALTER TABLE booking.booking ADD CONSTRAINT booking_category_fkey
            FOREIGN KEY (tenant_id, category_id)
            REFERENCES catalog.vehicle_category (tenant_id, id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS booking.booking_line (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id  uuid NOT NULL REFERENCES booking.booking(id) ON DELETE CASCADE,
    kind        text NOT NULL CHECK (kind IN ('rental','addon','fee','discount','damage','fuel','late','tax')),
    description text NOT NULL,
    qty         numeric(12,3) NOT NULL DEFAULT 1,
    unit_paise  bigint NOT NULL,
    tax_bps     int NOT NULL DEFAULT 0 CHECK (tax_bps BETWEEN 0 AND 10000),
    total_paise bigint NOT NULL
);

-- Append-only: the audit of the state machine. 900 revokes UPDATE and DELETE.
CREATE TABLE IF NOT EXISTS booking.booking_event (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id  uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id uuid NOT NULL REFERENCES booking.booking(id) ON DELETE CASCADE,
    from_state text,
    to_state   text NOT NULL,
    actor      text,
    reason     text,
    at         timestamptz NOT NULL DEFAULT now()
);

-- UC-11: per-person KYC. Every named rider on a booking is verified, not just
-- the person who paid.
CREATE TABLE IF NOT EXISTS booking.rider (
    id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id           uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id          uuid NOT NULL REFERENCES booking.booking(id) ON DELETE CASCADE,
    customer_id         uuid NOT NULL,
    vehicle_id          uuid REFERENCES catalog.vehicle(id) ON DELETE SET NULL,
    licence_verified_at timestamptz,
    UNIQUE (booking_id, customer_id)
);

CREATE TABLE IF NOT EXISTS handover.handover (
    id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id   uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id  uuid NOT NULL REFERENCES booking.booking(id) ON DELETE CASCADE,
    direction   text NOT NULL CHECK (direction IN ('out','in')),
    at          timestamptz NOT NULL DEFAULT now(),
    odometer_km int,
    fuel_pct    int CHECK (fuel_pct BETWEEN 0 AND 100),
    checklist   jsonb NOT NULL DEFAULT '{}'::jsonb,
    media       text[] NOT NULL DEFAULT '{}',
    signature_object_key text,
    staff_id    uuid REFERENCES identity.staff(id) ON DELETE SET NULL,
    UNIQUE (booking_id, direction)
);

CREATE INDEX IF NOT EXISTS booking_tenant_created_idx
    ON booking.booking (tenant_id, created_at DESC);

-- The Today screen, which is the most-run query in the product.
CREATE INDEX IF NOT EXISTS booking_today_idx
    ON booking.booking (tenant_id, state)
    WHERE state IN ('confirmed','active');
