-- ===========================================================================
-- party tax profiles — what is known about the landlord, not the tenancy
-- ===========================================================================

-- lease_tax_facts answers "which section governs this tenancy". This answers
-- "what has this payee furnished", which is a different question with a
-- different lifetime: section 206AA turns on the payee having given a PAN, and
-- rule 37BC on a non-resident having given five particulars. An owner with two
-- flats furnishes once.
--
-- Effective dated for lease_tax_facts' reason: a landlord who moves abroad in
-- October was a resident in April, and April's deduction was correct.
CREATE TABLE IF NOT EXISTS party_tax_profiles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),
    party_id       uuid NOT NULL,

    tax_residency  text NOT NULL CHECK (tax_residency IN ('resident', 'non_resident')),

    -- §206AA turns on furnishing a PAN to the deductor, not on holding one. The
    -- number itself is never here: kyc_verifications keeps the mask (ADR-0013).
    pan_furnished  boolean NOT NULL DEFAULT false,

    residence_country char(2) NOT NULL DEFAULT 'IN' CHECK (residence_country ~ '^[A-Z]{2}$'),

    -- Rule 37BC(2)'s particulars. The TIN is an identifier, so it is masked here
    -- like every other; a return that needs the whole thing reads the ciphertext.
    foreign_tin_masked text,
    trc_number         text,
    trc_valid_from     date,
    trc_valid_to       date,
    foreign_address    text,
    foreign_email      text,
    foreign_phone      text,

    -- Derived, never asserted. A caller that set this itself would be one commit
    -- away from marking a payee exempt with three of the five particulars.
    rule_37bc_furnished boolean GENERATED ALWAYS AS (
        tax_residency = 'non_resident'
        AND foreign_tin_masked IS NOT NULL AND btrim(foreign_tin_masked) <> ''
        AND trc_number IS NOT NULL AND btrim(trc_number) <> ''
        AND foreign_address IS NOT NULL AND btrim(foreign_address) <> ''
        AND foreign_email IS NOT NULL AND btrim(foreign_email) <> ''
        AND foreign_phone IS NOT NULL AND btrim(foreign_phone) <> ''
    ) STORED,

    -- Who says so. "The owner declared it on this date" is an answer to an
    -- assessing officer; "the system had it" is not.
    source         text NOT NULL CHECK (btrim(source) <> ''),

    valid_from     date NOT NULL,
    valid_to       date,
    validity       daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at     timestamptz,
    corrects       uuid REFERENCES party_tax_profiles(id),

    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,

    CONSTRAINT party_tax_profiles_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT party_tax_profiles_correction_shape CHECK (corrects IS NULL OR corrects <> id),
    -- A non-resident living in India is one of the two facts being wrong, and the
    -- pair is what selects section 195 over 194-I.
    CONSTRAINT party_tax_profiles_residence_agrees CHECK (
        (tax_residency = 'non_resident') = (residence_country <> 'IN')),
    -- A certificate with no window cannot be tested against a payment date, and a
    -- window with no certificate is a date range attached to nothing.
    CONSTRAINT party_tax_profiles_trc_shape CHECK (
        (trc_number IS NULL) = (trc_valid_from IS NULL)
        AND (trc_valid_to IS NULL OR trc_valid_to > trc_valid_from))
);

COMMENT ON TABLE party_tax_profiles IS
    'What a landlord has furnished for TDS purposes — PAN, and for a non-resident rule 37BC''s particulars. Effective dated: residency changes and the earlier months stay as they were deducted.';
COMMENT ON COLUMN party_tax_profiles.rule_37bc_furnished IS
    'Derived from the particulars themselves, so a payee cannot be marked outside section 206AA with some of them.';
COMMENT ON COLUMN party_tax_profiles.foreign_tin_masked IS
    'ADR-0013. The mask, never the TIN — an identifier is kept masked or not at all.';

-- One profile true at a time, per party. An EXCLUDE rather than a trigger, for
-- lease_tax_facts' reason: a trigger reads the table it protects and is racy
-- exactly when two writers revise the same payee.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'party_tax_profiles_no_overlap') THEN
        ALTER TABLE party_tax_profiles ADD CONSTRAINT party_tax_profiles_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, party_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS party_tax_profiles_asof_idx
    ON party_tax_profiles (tenant_id, party_id, valid_from DESC)
    WHERE retired_at IS NULL;
-- "Whose certificate lapses this quarter" — the chase before it costs a rate.
CREATE INDEX IF NOT EXISTS party_tax_profiles_trc_expiry_idx
    ON party_tax_profiles (tenant_id, trc_valid_to)
    WHERE trc_valid_to IS NOT NULL AND retired_at IS NULL;

ALTER TABLE party_tax_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE party_tax_profiles FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS party_tax_profiles_tenant_isolation ON party_tax_profiles;
CREATE POLICY party_tax_profiles_tenant_isolation ON party_tax_profiles
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. What the payee furnished, and when, is the whole
-- defence when a rate is questioned years later.
DROP POLICY IF EXISTS party_tax_profiles_no_delete ON party_tax_profiles;
CREATE POLICY party_tax_profiles_no_delete ON party_tax_profiles AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- ADR-0029. Chapter 220's generator runs before this one, so on a fresh replay it
-- would not see this table — the deny is declared here rather than inherited. The
-- name matches what the generator would produce, so a later replay replaces it
-- with an identical policy instead of adding a second.
DROP POLICY IF EXISTS party_tax_profiles_resident_denied ON party_tax_profiles;
CREATE POLICY party_tax_profiles_resident_denied ON party_tax_profiles AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

GRANT SELECT, INSERT, UPDATE ON party_tax_profiles TO dwellm8_identity;
-- The rate is resolved where the money is, and the tenancy shows what is still
-- outstanding. Neither writes what the payee furnished.
GRANT SELECT ON party_tax_profiles TO dwellm8_money, dwellm8_lease;
