-- ===========================================================================
-- the applicant pack (#258)
-- ===========================================================================

-- listing_applications (#227) records that somebody applied. It records
-- nothing about who they are, so everything an Indian landlord actually asks
-- before handing over keys lives in WhatsApp. This is where it lives instead.
--
-- The pack is effective-dated (ADR-0008): an applicant who corrects their
-- employer does not overwrite what the manager saw when deciding, because a
-- decline has to be explicable months later. A correction retires the row it
-- replaces and names it, exactly as property_ownership does.
--
-- #103 draws the boundary this chapter must not cross: the pack belongs to
-- the owner who collected it. There is no cross-owner path, no score, and no
-- table here that could become one.

CREATE TABLE IF NOT EXISTS applicant_profiles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),
    application_id uuid NOT NULL REFERENCES listing_applications(id),
    -- The delegation quad (ADR-0009): a firm's mandate reads the pack the way
    -- it reads the application it hangs off.
    property_id    uuid NOT NULL,
    unit_id        uuid NOT NULL,

    full_name      text NOT NULL CHECK (btrim(full_name) <> ''),
    date_of_birth  date,
    -- ISO 3166-1 alpha-2. An applicant on an employment visa is ordinary here.
    nationality    text NOT NULL DEFAULT 'IN' CHECK (nationality ~ '^[A-Z]{2}$'),
    -- Tax residency, not citizenship — the same distinction the lease's TDS
    -- facts draw for the owner (ADR-0024).
    tax_residency  text NOT NULL DEFAULT 'resident'
                        CHECK (tax_residency IN ('resident', 'non_resident')),

    -- How the flat will actually be used. Occupancy drives the society's
    -- expectations and, for a co-living unit, the bed count.
    occupants      int NOT NULL DEFAULT 1 CHECK (occupants BETWEEN 1 AND 20),
    pets           boolean NOT NULL DEFAULT false,
    pets_note      text,

    -- A half-finished pack is the normal state: sixty months of address
    -- history is not one sitting. Only a submitted pack is decidable.
    state          text NOT NULL DEFAULT 'draft'
                        CHECK (state IN ('draft', 'submitted')),
    submitted_at   timestamptz,

    valid_from     date NOT NULL DEFAULT CURRENT_DATE,
    valid_to       date,
    validity       daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at     timestamptz,
    corrects       uuid REFERENCES applicant_profiles(id),

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT applicant_profiles_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT applicant_profiles_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT applicant_profiles_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT applicant_profiles_correction_shape CHECK (corrects IS NULL OR corrects <> id),
    CONSTRAINT applicant_profiles_submission_shape CHECK (
        (state = 'submitted') = (submitted_at IS NOT NULL)),
    -- A date of birth in the future, or one that makes the applicant 150, is a
    -- typo rather than a tenant.
    CONSTRAINT applicant_profiles_birth_plausible CHECK (
        date_of_birth IS NULL
        OR (date_of_birth < CURRENT_DATE AND date_of_birth > CURRENT_DATE - INTERVAL '150 years'))
);

COMMENT ON TABLE applicant_profiles IS
    '#258. Who the applicant is, effective-dated. One live row per application; a correction retires the row it replaces rather than editing it.';

-- One live pack per application. A correction supersedes by retiring first,
-- so the two never coexist.
CREATE UNIQUE INDEX IF NOT EXISTS applicant_profiles_one_live
    ON applicant_profiles (application_id)
    WHERE retired_at IS NULL AND valid_to IS NULL;

CREATE INDEX IF NOT EXISTS applicant_profiles_owner_idx
    ON applicant_profiles (tenant_id, created_at DESC);

-- Everyone else who will live there, or stand behind the rent. Separate rows
-- rather than a JSON blob because each may need their own ID proof (#262).
CREATE TABLE IF NOT EXISTS applicant_people (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    profile_id    uuid NOT NULL REFERENCES applicant_profiles(id),

    role          text NOT NULL CHECK (role IN ('co_applicant', 'dependant', 'guarantor')),
    full_name     text NOT NULL CHECK (btrim(full_name) <> ''),
    relationship  text,
    date_of_birth date,
    -- E.164, the one phone shape this platform accepts (ADR-0029).
    phone         text CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$'),
    email         text,

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT applicant_people_birth_plausible CHECK (
        date_of_birth IS NULL
        OR (date_of_birth < CURRENT_DATE AND date_of_birth > CURRENT_DATE - INTERVAL '150 years'))
);

COMMENT ON TABLE applicant_people IS
    '#258. Co-applicants, dependants and guarantors. One row each, because each may need their own ID proof.';

CREATE INDEX IF NOT EXISTS applicant_people_profile_idx
    ON applicant_people (profile_id, role);

ALTER TABLE applicant_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE applicant_profiles FORCE  ROW LEVEL SECURITY;
ALTER TABLE applicant_people   ENABLE ROW LEVEL SECURITY;
ALTER TABLE applicant_people   FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS applicant_profiles_tenant_isolation ON applicant_profiles;
CREATE POLICY applicant_profiles_tenant_isolation ON applicant_profiles
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.write'));

DROP POLICY IF EXISTS applicant_people_tenant_isolation ON applicant_people;
CREATE POLICY applicant_people_tenant_isolation ON applicant_people
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- The applicant reaches their own pack through the resident surface's platform
-- session, exactly as they reach the application itself (#227).
DROP POLICY IF EXISTS applicant_profiles_resident_denied ON applicant_profiles;
CREATE POLICY applicant_profiles_resident_denied ON applicant_profiles AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS applicant_people_resident_denied ON applicant_people;
CREATE POLICY applicant_people_resident_denied ON applicant_people AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- Deletion follows the application it hangs off: a sandbox purge, or the
-- platform sweep clearing a declined applicant whose retention has passed.
DROP POLICY IF EXISTS applicant_profiles_no_delete ON applicant_profiles;
CREATE POLICY applicant_profiles_no_delete ON applicant_profiles AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id)
           OR (is_platform_session() AND EXISTS (
                 SELECT 1 FROM listing_applications a
                  WHERE a.id = applicant_profiles.application_id
                    AND a.state = 'declined'
                    AND a.retain_until IS NOT NULL
                    AND a.retain_until <= CURRENT_DATE)));

DROP POLICY IF EXISTS applicant_people_no_delete ON applicant_people;
CREATE POLICY applicant_people_no_delete ON applicant_people AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id)
           OR (is_platform_session() AND EXISTS (
                 SELECT 1 FROM applicant_profiles p
                   JOIN listing_applications a ON a.id = p.application_id
                  WHERE p.id = applicant_people.profile_id
                    AND a.state = 'declined'
                    AND a.retain_until IS NOT NULL
                    AND a.retain_until <= CURRENT_DATE)));

-- A retired row stays retired: history that can be edited is not history.
CREATE OR REPLACE FUNCTION applicant_profiles_retired_is_final() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF OLD.retired_at IS NOT NULL AND NEW.retired_at IS DISTINCT FROM OLD.retired_at THEN
        RAISE EXCEPTION 'applicant profile % is retired: correct it with a new row, do not revive it', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS applicant_profiles_no_revival ON applicant_profiles;
CREATE TRIGGER applicant_profiles_no_revival
    BEFORE UPDATE ON applicant_profiles
    FOR EACH ROW EXECUTE FUNCTION applicant_profiles_retired_is_final();

GRANT SELECT, INSERT, UPDATE ON applicant_profiles, applicant_people
    TO dwellm8_discovery, dwellm8_property;
GRANT DELETE ON applicant_profiles, applicant_people TO dwellm8_platform;
