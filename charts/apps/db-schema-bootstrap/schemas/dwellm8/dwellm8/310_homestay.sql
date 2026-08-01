-- ===========================================================================
-- HomeStay: short-stay booking as a Dwellm8 surface (#233)
-- ===========================================================================

-- A stay listing advertises a unit by the night the way listings advertises it
-- by the month — same tree (properties/units), same organisations, and the
-- guest is a prospect: the browsing-token identity and its phone-verification
-- gate (ADR-0019) are reused whole, because a person booking a weekend needs
-- exactly the same standing as a person booking a viewing.
--
-- No public read branch. Assertion 17 admits one table (listings) and this is
-- not it: the anonymous stay search runs through the platform session like
-- slots and shortlists do.

CREATE TABLE IF NOT EXISTS stay_listings (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,

    state         text NOT NULL DEFAULT 'draft' CHECK (state IN (
                      'draft', 'live', 'paused', 'withdrawn')),
    published_at  timestamptz,

    headline      text NOT NULL,
    locality      text NOT NULL,
    city          text NOT NULL,
    state_code    char(2) NOT NULL,

    -- The whole price, itemised the way #134 demands of long lets: the night,
    -- the clean, and the refundable deposit. All minor units (ADR-0007).
    nightly_minor  bigint NOT NULL CHECK (nightly_minor > 0),
    cleaning_minor bigint NOT NULL DEFAULT 0 CHECK (cleaning_minor >= 0),
    deposit_minor  bigint NOT NULL DEFAULT 0 CHECK (deposit_minor >= 0),
    currency       char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    max_guests    int NOT NULL DEFAULT 2 CHECK (max_guests BETWEEN 1 AND 20),
    min_nights    int NOT NULL DEFAULT 1 CHECK (min_nights BETWEEN 1 AND 90),
    max_nights    int NOT NULL DEFAULT 30 CHECK (max_nights BETWEEN 1 AND 365),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT stay_listings_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT stay_listings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT stay_listings_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT stay_listings_night_window CHECK (max_nights >= min_nights),
    CONSTRAINT stay_listings_live_is_published CHECK (state <> 'live' OR published_at IS NOT NULL),
    CONSTRAINT stay_listings_amount_representable CHECK (nightly_minor <= 9007199254740991)
);

COMMENT ON TABLE stay_listings IS
    '#233. A unit advertised by the night. Same inventory tree as listings; the guest side reads through the platform session, never a public branch.';

CREATE UNIQUE INDEX IF NOT EXISTS stay_listings_one_live_per_unit
    ON stay_listings (tenant_id, unit_id) WHERE state IN ('live', 'paused');
CREATE INDEX IF NOT EXISTS stay_listings_search_idx
    ON stay_listings (city, nightly_minor) WHERE state = 'live' AND published_at IS NOT NULL;

-- A booking. `held` is a shopping cart with a deadline; `confirmed` is a
-- commitment; the exclusion constraint below is the double-booking arbiter —
-- of two guests racing for the same nights, PostgreSQL lets exactly one in.
CREATE TABLE IF NOT EXISTS stay_bookings (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES stay_listings(id),
    unit_id       uuid NOT NULL,
    -- The guest is a prospect (ADR-0019): verified phone before money or
    -- occupancy, enforced by the trigger below.
    prospect_id   uuid NOT NULL REFERENCES prospects(id),

    state         text NOT NULL DEFAULT 'held' CHECK (state IN (
                      'held', 'confirmed', 'cancelled', 'completed', 'no_show')),
    guests        int NOT NULL CHECK (guests BETWEEN 1 AND 20),
    check_in      date NOT NULL,
    check_out     date NOT NULL,
    stay          daterange GENERATED ALWAYS AS (daterange(check_in, check_out, '[)')) STORED,

    -- The price as agreed at booking, denormalised on purpose: the listing's
    -- rate can change tomorrow and this guest's cannot.
    nightly_minor  bigint NOT NULL CHECK (nightly_minor > 0),
    cleaning_minor bigint NOT NULL DEFAULT 0 CHECK (cleaning_minor >= 0),
    total_minor    bigint NOT NULL CHECK (total_minor > 0),
    currency       char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- A hold that nobody confirms releases itself: confirm refuses after this,
    -- and the sweep closes it. Fifteen minutes of somebody's indecision must
    -- not block a week of somebody else's holiday.
    hold_expires_at timestamptz,
    cancelled_by    text CHECK (cancelled_by IS NULL OR cancelled_by IN ('guest', 'host')),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT stay_bookings_window CHECK (check_out > check_in),
    CONSTRAINT stay_bookings_held_expires CHECK (state <> 'held' OR hold_expires_at IS NOT NULL),
    CONSTRAINT stay_bookings_cancel_shape CHECK ((state = 'cancelled') = (cancelled_by IS NOT NULL)),
    CONSTRAINT stay_bookings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id)
);

COMMENT ON TABLE stay_bookings IS
    '#233. One row per stay. The exclusion constraint is the whole double-booking story; the price is the one agreed, not the one advertised later.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'stay_bookings_no_double_book') THEN
        ALTER TABLE stay_bookings ADD CONSTRAINT stay_bookings_no_double_book
            EXCLUDE USING gist (unit_id WITH =, stay WITH &&)
            WHERE (state IN ('held', 'confirmed'));
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS stay_bookings_host_idx ON stay_bookings (tenant_id, state, check_in);
CREATE INDEX IF NOT EXISTS stay_bookings_guest_idx ON stay_bookings (prospect_id, created_at);

-- The verification point, the same one enquiries enforce: browsing is
-- anonymous, occupancy is not.
CREATE OR REPLACE FUNCTION stay_bookings_need_a_verified_prospect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prospects p
                    WHERE p.id = NEW.prospect_id AND p.verified_at IS NOT NULL) THEN
        RAISE EXCEPTION 'stay booking % is from an unverified prospect: browsing needs no account, '
                        'and sleeping in somebody''s flat needs a verified phone number',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS stay_bookings_verification_point ON stay_bookings;
CREATE TRIGGER stay_bookings_verification_point
    BEFORE INSERT ON stay_bookings
    FOR EACH ROW EXECUTE FUNCTION stay_bookings_need_a_verified_prospect();

ALTER TABLE stay_listings ENABLE ROW LEVEL SECURITY;
ALTER TABLE stay_listings FORCE  ROW LEVEL SECURITY;
ALTER TABLE stay_bookings ENABLE ROW LEVEL SECURITY;
ALTER TABLE stay_bookings FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS stay_listings_tenant_isolation ON stay_listings;
CREATE POLICY stay_listings_tenant_isolation ON stay_listings
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS stay_bookings_tenant_isolation ON stay_bookings;
CREATE POLICY stay_bookings_tenant_isolation ON stay_bookings
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A cancelled booking is the record a chargeback turns on. No deletes outside
-- a sandbox purge, the same rule as every funnel table.
DROP POLICY IF EXISTS stay_listings_no_delete ON stay_listings;
CREATE POLICY stay_listings_no_delete ON stay_listings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS stay_bookings_no_delete ON stay_bookings;
CREATE POLICY stay_bookings_no_delete ON stay_bookings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON stay_listings, stay_bookings
    TO dwellm8_discovery, dwellm8_property;
