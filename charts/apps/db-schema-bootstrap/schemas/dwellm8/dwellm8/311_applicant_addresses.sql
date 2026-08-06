-- ===========================================================================
-- five years of address history (#259)
-- ===========================================================================

-- The first question a manager asks is where the applicant has been living,
-- and the second is who the landlord there was. Five years covers a typical
-- Indian rental history: two or three 11-month tenancies plus a family home.
--
-- The gaps are the point. A hole in the history is reported, never silently
-- accepted, so the manager asks about it rather than discovering it later.
-- Detection lives in the API, not here — a gap is a question, not a violation.

CREATE TABLE IF NOT EXISTS applicant_addresses (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    uuid NOT NULL REFERENCES organisations(id),
    profile_id   uuid NOT NULL REFERENCES applicant_profiles(id),

    kind         text NOT NULL CHECK (kind IN
                     ('rented', 'owned', 'family', 'employer_provided', 'hostel')),
    line1        text NOT NULL CHECK (btrim(line1) <> ''),
    locality     text,
    city         text NOT NULL CHECK (btrim(city) <> ''),
    state_code   text,
    pin          text,
    country      text NOT NULL DEFAULT 'IN' CHECK (country ~ '^[A-Z]{2}$'),

    -- Months, not days: nobody remembers the date they moved in 2021, and a
    -- spurious precision would make the gap arithmetic lie.
    from_month   date NOT NULL,
    -- NULL is the present address, and there is only one of those.
    to_month     date,

    -- A previous landlord seeds a reference (#261) instead of being retyped.
    landlord_name  text,
    landlord_phone text CHECK (landlord_phone IS NULL OR landlord_phone ~ '^\+[1-9][0-9]{7,14}$'),

    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT applicant_addresses_months CHECK (
        from_month = date_trunc('month', from_month)::date
        AND (to_month IS NULL OR to_month = date_trunc('month', to_month)::date)),
    CONSTRAINT applicant_addresses_order CHECK (to_month IS NULL OR to_month >= from_month),
    CONSTRAINT applicant_addresses_not_future CHECK (
        from_month <= date_trunc('month', CURRENT_DATE)::date),
    -- An Indian address without a state and a PIN cannot be posted to, and a
    -- foreign one has neither. Each shape is required to be itself.
    CONSTRAINT applicant_addresses_indian_shape CHECK (
        country <> 'IN'
        OR (state_code ~ '^[A-Z]{2}$' AND pin ~ '^[1-9][0-9]{5}$'))
);

COMMENT ON TABLE applicant_addresses IS
    '#259. Where the applicant has lived, by month. Gaps are reported by the API, not rejected here.';

CREATE INDEX IF NOT EXISTS applicant_addresses_profile_idx
    ON applicant_addresses (profile_id, from_month DESC);

ALTER TABLE applicant_addresses ENABLE ROW LEVEL SECURITY;
ALTER TABLE applicant_addresses FORCE  ROW LEVEL SECURITY;

-- The history hangs off the pack and reaches the mandate through it, exactly
-- as the household does (#259).
DROP POLICY IF EXISTS applicant_addresses_tenant_isolation ON applicant_addresses;
CREATE POLICY applicant_addresses_tenant_isolation ON applicant_addresses
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR applicant_pack_delegated(profile_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR applicant_pack_delegated(profile_id, 'property.write'));

DROP POLICY IF EXISTS applicant_addresses_resident_denied ON applicant_addresses;
CREATE POLICY applicant_addresses_resident_denied ON applicant_addresses AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- The set is replaced whole by its owner, so DELETE is ordinary here; the
-- platform sweep still needs its own path for a declined pack past retention.
DROP POLICY IF EXISTS applicant_addresses_no_delete ON applicant_addresses;
CREATE POLICY applicant_addresses_no_delete ON applicant_addresses AS RESTRICTIVE FOR DELETE
    USING (tenant_id = current_tenant_id()
           OR applicant_pack_delegated(profile_id, 'property.write')
           OR sandbox_purge_permitted(tenant_id)
           OR is_platform_session());

GRANT SELECT, INSERT, UPDATE, DELETE ON applicant_addresses
    TO dwellm8_discovery, dwellm8_property;
GRANT DELETE ON applicant_addresses TO dwellm8_platform;
