-- ===========================================================================
-- the manager's own registration (#282)
-- ===========================================================================

-- A manager signs into the ops app with an email and a password, which is a
-- provider identity_principals was written before it had — the check listed
-- phone, Google and Apple only, and a firm being created failed at 500 on it.
-- Password is added; email is added because GIP reports an email-link sign-in
-- under that name and refusing it later would be the same outage again.
ALTER TABLE identity_principals
    DROP CONSTRAINT IF EXISTS identity_principals_sign_in_provider_check;
ALTER TABLE identity_principals
    ADD  CONSTRAINT identity_principals_sign_in_provider_check
    CHECK (sign_in_provider IN ('phone', 'password', 'email', 'google.com', 'apple.com'));

-- An email that has been proved to reach the person holding the account. A
-- password sign-in proves possession of a password, nothing more, so the firm
-- gate asks for a code before it will mint an organisation.
ALTER TABLE identity_principals
    ADD COLUMN IF NOT EXISTS email_verified_at timestamptz;

-- The code in flight.
--
-- Only its hash is kept: a six-digit code is worth nothing to an attacker who
-- has already read the table, but an operator reading a support query should
-- not be able to complete somebody else's sign-up. Attempts are counted because
-- a million guesses against six digits is a minute of traffic, not an attack
-- anybody needs skill to run.
CREATE TABLE IF NOT EXISTS identity_email_codes (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    surface      text NOT NULL CHECK (surface IN (
                     'own', 'ops', 'live', 'find', 'pro', 'admin', 'staff')),
    gip_uid      text NOT NULL CHECK (btrim(gip_uid) <> ''),
    email        citext NOT NULL,

    code_hash    bytea NOT NULL,
    attempts     int  NOT NULL DEFAULT 0 CHECK (attempts >= 0),

    sent_at      timestamptz NOT NULL DEFAULT now(),
    expires_at   timestamptz NOT NULL,
    consumed_at  timestamptz,

    CONSTRAINT identity_email_codes_window CHECK (expires_at > sent_at)
);

COMMENT ON TABLE identity_email_codes IS
    '#282. A one-time code sent to a manager''s email, stored as a hash. Consumed once, expires either way.';

-- The lookup the confirm path makes: newest unconsumed code for this sign-in.
CREATE INDEX IF NOT EXISTS identity_email_codes_pending_idx
    ON identity_email_codes (surface, gip_uid, sent_at DESC)
    WHERE consumed_at IS NULL;

REVOKE ALL ON identity_email_codes FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON identity_email_codes TO dwellm8_identity;

-- ---------------------------------------------------------------------------
-- what a property manager must be able to show
-- ---------------------------------------------------------------------------

-- Managing somebody else's property for a fee is regulated work in India, and
-- the details are not decoration: they are what a manager is asked for by an
-- owner, a tenant's employer, a bank and a tax officer.
--
--   RERA agent registration  s.9 of the Real Estate (Regulation and
--       Development) Act 2016 — anybody facilitating a sale or letting for
--       another person registers with the state authority. Registration is
--       per state, so a firm working Karnataka and Maharashtra holds two, and
--       it expires: the validity window is the point of the row.
--   PAN     mandatory for the firm; masked here, never stored whole (ADR-0013).
--   TAN     required to deduct TDS. A manager paying rent above the s.194-I
--       threshold on an owner's behalf deducts, and cannot without one.
--   GSTIN   management fees are a supply of service; above the threshold the
--       fee carries GST, and the number belongs on the invoice.
--   CIN / LLPIN  the registrar's identifier where the firm is a body corporate.
--
-- One row per organisation. State registrations hang off it, because that is
-- the part that is many and that expires.
CREATE TABLE IF NOT EXISTS manager_profiles (
    tenant_id      uuid PRIMARY KEY REFERENCES organisations(id),

    -- The name on the registration, which is often not the trading name.
    legal_name     text NOT NULL CHECK (btrim(legal_name) <> ''),
    trade_name     text,
    constitution   text NOT NULL DEFAULT 'proprietorship' CHECK (constitution IN
                       ('individual', 'proprietorship', 'partnership', 'llp',
                        'company', 'trust', 'society')),

    -- Masked like every other identifier of its class. ADR-0013 §2.
    pan_masked     text CHECK (pan_masked IS NULL OR pan_masked ~ '^X+[0-9A-Z]{4}$'),
    tan            text CHECK (tan IS NULL OR tan ~ '^[A-Z]{4}[0-9]{5}[A-Z]$'),
    gstin          text CHECK (gstin IS NULL OR
                       gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z][Z][0-9A-Z]$'),
    -- CIN is 21 characters, LLPIN 7. One column, because a firm is one or the
    -- other and never both.
    registrar_id   text CHECK (registrar_id IS NULL OR
                       registrar_id ~ '^([A-Z][0-9]{5}[A-Z]{2}[0-9]{4}[A-Z]{3}[0-9]{6}|[A-Z]{3}-[0-9]{4})$'),

    -- The registered office. Correspondence under the Act goes here, so it is
    -- the address that must be real rather than the one on the website.
    address_line1  text NOT NULL CHECK (btrim(address_line1) <> ''),
    address_line2  text,
    locality       text,
    city           text NOT NULL CHECK (btrim(city) <> ''),
    state_code     text NOT NULL CHECK (state_code ~ '^[A-Z]{2}$'),
    pin_code       text NOT NULL CHECK (pin_code ~ '^[1-9][0-9]{5}$'),

    contact_email  citext NOT NULL,
    contact_phone  text NOT NULL CHECK (contact_phone ~ '^\+[1-9][0-9]{7,14}$'),

    -- Whether the firm may take a mandate yet. A profile with no live RERA
    -- registration is a draft, and internal/identity/domain owns the transition.
    state          text NOT NULL DEFAULT 'draft' CHECK (state IN ('draft', 'submitted', 'active', 'lapsed')),

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    -- A body corporate has a registrar identifier; a sole manager does not.
    CONSTRAINT manager_profiles_body_corporate_is_registered CHECK (
        constitution NOT IN ('llp', 'company') OR registrar_id IS NOT NULL)
);

COMMENT ON TABLE manager_profiles IS
    '#282. The statutory identity of a managing firm — RERA, PAN, TAN, GSTIN, registered office. What an owner, a tenant''s employer and a tax officer each ask for.';

ALTER TABLE manager_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE manager_profiles FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_profiles_tenant_isolation ON manager_profiles;
CREATE POLICY manager_profiles_tenant_isolation ON manager_profiles
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A resident has no business reading their landlord's tax registrations.
DROP POLICY IF EXISTS manager_profiles_resident_denied ON manager_profiles;
CREATE POLICY manager_profiles_resident_denied ON manager_profiles AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS manager_profiles_no_delete ON manager_profiles;
CREATE POLICY manager_profiles_no_delete ON manager_profiles AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON manager_profiles TO dwellm8_identity;
GRANT SELECT ON manager_profiles TO dwellm8_property, dwellm8_lease, dwellm8_money;

-- One registration per state, and it expires.
--
-- Effective dated rather than overwritten: an owner disputing a fee two years
-- on is asking whether the firm was registered *then*, and a row that was
-- updated in place cannot answer.
CREATE TABLE IF NOT EXISTS manager_registrations (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),

    authority      text NOT NULL DEFAULT 'rera' CHECK (authority IN ('rera', 'shops_establishments', 'municipal', 'other')),
    state_code     text NOT NULL CHECK (state_code ~ '^[A-Z]{2}$'),
    -- No single format: each state authority issues its own, so the check is
    -- that it is present rather than that it matches somebody's regex.
    number         text NOT NULL CHECK (btrim(number) <> ''),

    valid_from     date NOT NULL,
    valid_to       date NOT NULL,
    validity       daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    -- The certificate itself, in documents. Nullable while it is being uploaded.
    document_id    uuid,

    verified_at    timestamptz,
    verified_by    uuid,

    created_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT manager_registrations_window CHECK (valid_to > valid_from)
);

COMMENT ON TABLE manager_registrations IS
    '#282. A RERA agent registration in one state, for one window. s.9 of the 2016 Act; a firm working two states holds two.';

-- The same authority cannot register the same firm twice in one state for
-- overlapping dates — that is a typo, and it would show as two live licences.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'manager_registrations_no_overlap') THEN
        ALTER TABLE manager_registrations ADD CONSTRAINT manager_registrations_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, authority WITH =, state_code WITH =, validity WITH &&);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS manager_registrations_live_idx
    ON manager_registrations (tenant_id, state_code, valid_to DESC);

ALTER TABLE manager_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE manager_registrations FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_registrations_tenant_isolation ON manager_registrations;
CREATE POLICY manager_registrations_tenant_isolation ON manager_registrations
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS manager_registrations_resident_denied ON manager_registrations;
CREATE POLICY manager_registrations_resident_denied ON manager_registrations AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- A lapsed registration is history, not a mistake.
DROP POLICY IF EXISTS manager_registrations_no_delete ON manager_registrations;
CREATE POLICY manager_registrations_no_delete ON manager_registrations AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON manager_registrations TO dwellm8_identity;
GRANT SELECT ON manager_registrations TO dwellm8_property, dwellm8_lease, dwellm8_money;

-- ---------------------------------------------------------------------------
-- the paperwork behind the profile
-- ---------------------------------------------------------------------------

-- documents is property-scoped and this is not: an incorporation certificate
-- belongs to the firm, not to a flat, and the firm holds it before it holds a
-- property at all.
--
-- Which kinds are *required* is a matter of constitution — a proprietor uploads
-- their own PAN, a company uploads the company's PAN plus the board resolution
-- naming whoever signs — and that matrix is domain logic in
-- internal/identity/domain/registration, not a constraint here. The check below
-- is only that a kind is one we know how to ask for.
CREATE TABLE IF NOT EXISTS manager_documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    kind          text NOT NULL CHECK (kind IN (
                      -- everyone
                      'pan_card', 'address_proof', 'bank_proof', 'photograph',
                      'signatory_id', 'rera_certificate',
                      -- registered businesses
                      'gst_certificate', 'tan_allotment',
                      'shops_establishments', 'udyam_registration',
                      -- partnership and LLP
                      'partnership_deed', 'llp_agreement', 'incorporation_certificate',
                      -- company
                      'moa_aoa', 'board_resolution',
                      -- trust and society
                      'trust_deed', 'registration_certificate',
                      -- optional but asked for by owners
                      'professional_indemnity', 'authority_letter')),

    -- Whose document, where the kind can be either the firm's or a person's:
    -- a company uploads the company PAN and each director's PAN under the same
    -- kind, and the party is what tells them apart.
    subject_party_id uuid,

    object_path   text NOT NULL UNIQUE CHECK (btrim(object_path) <> ''),
    filename      text NOT NULL CHECK (btrim(filename) <> ''),
    content_type  text NOT NULL CHECK (btrim(content_type) <> ''),

    -- Documents expire — a RERA certificate, a shops licence, an indemnity.
    expires_on    date,

    state         text NOT NULL DEFAULT 'uploaded' CHECK (state IN
                      ('uploaded', 'accepted', 'rejected', 'expired')),
    -- Why it was refused, in the words the manager is shown.
    reason        text,

    uploaded_by   text NOT NULL CHECK (btrim(uploaded_by) <> ''),
    created_at    timestamptz NOT NULL DEFAULT now(),
    reviewed_at   timestamptz,

    CONSTRAINT manager_documents_reason_shape CHECK (
        state <> 'rejected' OR (reason IS NOT NULL AND btrim(reason) <> ''))
);

COMMENT ON TABLE manager_documents IS
    '#282. Firm-level paperwork — PAN, RERA certificate, deed, resolution. Not documents: that table is property-scoped and this is held before any property exists.';

-- The newest live document of a kind is what the checklist reads.
CREATE INDEX IF NOT EXISTS manager_documents_kind_idx
    ON manager_documents (tenant_id, kind, created_at DESC);

ALTER TABLE manager_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE manager_documents FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS manager_documents_tenant_isolation ON manager_documents;
CREATE POLICY manager_documents_tenant_isolation ON manager_documents
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS manager_documents_resident_denied ON manager_documents;
CREATE POLICY manager_documents_resident_denied ON manager_documents AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS manager_documents_no_delete ON manager_documents;
CREATE POLICY manager_documents_no_delete ON manager_documents AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON manager_documents TO dwellm8_identity;
GRANT SELECT ON manager_documents TO dwellm8_property, dwellm8_money;
