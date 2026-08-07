-- ===========================================================================
-- party documents — what the owner produced to prove who they are (#318)
-- ===========================================================================

-- manager_documents is the firm's own paperwork and documents is a property's.
-- Neither holds the landlord's: an owner's PAN copy belongs to the owner, is
-- collected before any property is onboarded, and follows them across flats.
--
-- The reason this table exists rather than a column on party_tax_profiles is
-- attestation. An owner living abroad cannot walk into an office with an
-- original, so a copy is self-attested — signed and dated across the face by
-- the holder — and for some purposes attested by an Indian mission or under
-- the Hague apostille instead. Which of those it was is the fact a bank, a
-- registrar or an assessing officer asks about, and it is per document.
CREATE TABLE IF NOT EXISTS party_documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    party_id      uuid NOT NULL,

    kind          text NOT NULL CHECK (kind IN (
                      -- identity
                      'pan_card', 'aadhaar_masked', 'passport', 'oci_card',
                      'visa', 'residence_permit', 'photograph', 'signature',
                      -- where they live, when it is not India
                      'overseas_address_proof', 'address_proof',
                      -- what keeps them out of the 206AA floor
                      'tax_residency_certificate', 'form_10f',
                      'section_197_certificate',
                      -- what lets somebody else act, and what proves the title
                      'power_of_attorney', 'ownership_proof', 'bank_proof')),

    object_path   text NOT NULL UNIQUE CHECK (btrim(object_path) <> ''),
    filename      text NOT NULL CHECK (btrim(filename) <> ''),
    content_type  text NOT NULL CHECK (btrim(content_type) <> ''),

    -- Which country issued it. A passport is the usual reason: the nationality
    -- on it is not the residence country, and both get asked for.
    issuing_country char(2) CHECK (issuing_country IS NULL OR issuing_country ~ '^[A-Z]{2}$'),

    -- ADR-0013 §2. The mask, never the number. Aadhaar is masked at source as
    -- well: UIDAI's own rules permit the last four digits and nothing more, so
    -- the kind is named for the redacted copy rather than the card.
    number_masked text CHECK (number_masked IS NULL OR number_masked ~ '^X+[0-9A-Z]{4}$'),

    issued_on     date,
    expires_on    date,

    -- A copy is worth what the attestation on it is worth. 'none' is a scan
    -- taken in the office beside the original; 'self' is the signed copy an
    -- owner abroad posts; the last two are what a bank asks a non-resident for.
    attestation   text NOT NULL DEFAULT 'none' CHECK (attestation IN
                      ('none', 'self', 'notary', 'indian_mission', 'apostille')),
    attested_on   date,
    -- The notary, mission or officer named on the endorsement. Free text: it is
    -- a name and a seal number in whatever form that country writes them.
    attested_by   text,

    state         text NOT NULL DEFAULT 'uploaded' CHECK (state IN
                      ('uploaded', 'accepted', 'rejected', 'expired')),
    reason        text,

    uploaded_by   text NOT NULL CHECK (btrim(uploaded_by) <> ''),
    created_at    timestamptz NOT NULL DEFAULT now(),
    reviewed_at   timestamptz,

    CONSTRAINT party_documents_window CHECK (
        expires_on IS NULL OR issued_on IS NULL OR expires_on > issued_on),
    -- An attestation with no date cannot be tested against the document it
    -- attests, and a date with no attestation is a date attached to nothing.
    CONSTRAINT party_documents_attestation_shape CHECK (
        (attestation = 'none') = (attested_on IS NULL)),
    -- Only a person attests in their own name. A self-attested copy that names
    -- somebody else is one of the two facts being wrong.
    CONSTRAINT party_documents_attested_by_shape CHECK (
        attestation NOT IN ('notary', 'indian_mission', 'apostille')
        OR (attested_by IS NOT NULL AND btrim(attested_by) <> '')),
    CONSTRAINT party_documents_reason_shape CHECK (
        state <> 'rejected' OR (reason IS NOT NULL AND btrim(reason) <> ''))
);

COMMENT ON TABLE party_documents IS
    '#318. The landlord''s own paperwork — PAN, passport, TRC, proof of an address abroad — and how each copy was attested. Not documents (property-scoped) and not manager_documents (the firm''s own).';
COMMENT ON COLUMN party_documents.attestation IS
    'What the copy is worth. An owner abroad self-attests; a bank or a registrar may require a mission endorsement or an apostille instead.';
COMMENT ON COLUMN party_documents.number_masked IS
    'ADR-0013. The mask, never the number. Aadhaar is only ever held as the redacted copy UIDAI permits.';

-- The newest document of a kind is what the onboarding checklist reads.
CREATE INDEX IF NOT EXISTS party_documents_kind_idx
    ON party_documents (tenant_id, party_id, kind, created_at DESC);
-- "Whose passport or certificate lapses this quarter" — the chase before an
-- owner abroad discovers it at the moment they need to sign something.
CREATE INDEX IF NOT EXISTS party_documents_expiry_idx
    ON party_documents (tenant_id, expires_on)
    WHERE expires_on IS NOT NULL AND state <> 'rejected';

ALTER TABLE party_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE party_documents FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS party_documents_tenant_isolation ON party_documents;
CREATE POLICY party_documents_tenant_isolation ON party_documents
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- ADR-0029. Declared here rather than inherited: chapter 220's generator runs
-- before this one and would not see the table on a fresh replay. The name is
-- what the generator would produce, so a later replay replaces this policy
-- instead of adding a second one beside it.
DROP POLICY IF EXISTS party_documents_resident_denied ON party_documents;
CREATE POLICY party_documents_resident_denied ON party_documents AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- A rejected copy is history too: "we asked twice and it never came" is the
-- answer to why an onboarding stalled.
DROP POLICY IF EXISTS party_documents_no_delete ON party_documents;
CREATE POLICY party_documents_no_delete ON party_documents AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON party_documents TO dwellm8_identity;
-- The tenancy shows what is still outstanding and the money side proves the
-- rate it deducted at. Neither collects the paperwork.
GRANT SELECT ON party_documents TO dwellm8_lease, dwellm8_money, dwellm8_property;
