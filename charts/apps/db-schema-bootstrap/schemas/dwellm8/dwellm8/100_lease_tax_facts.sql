-- ===========================================================================
-- lease tax facts — the two facts that decide the TDS section (ADR-0024)
-- ===========================================================================

-- What kind of payer the tenant is, and whether the landlord is a resident. Those
-- two answers select section 194-I, 194-IB or 195, and with them the rate, the
-- threshold, the periodicity, the forms and who is liable when it is missed.
--
-- A table rather than two columns on leases, because residency changes. A landlord
-- who moves abroad in October was a resident in April, and both are true of the same
-- tenancy in the same financial year: April's rent was deducted at ten per cent
-- under 194-I and deposited and certified that way, and overwriting a column would
-- restate a deduction that was correct. ADR-0008's shape, for ADR-0008's reason.
--
-- No acknowledgement is required to *record* a fact: a draft lease may know the
-- landlord is an NRI before the tenant has been shown what that costs them. It is
-- required to *start the tenancy*, which is the trigger below.
CREATE TABLE IF NOT EXISTS lease_tax_facts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL,

    -- Narrower than "individual or company": the line the Act draws is whether the
    -- payer is an individual or HUF *not* liable to audit under section 44AB, because
    -- that class alone deducts under 194-IB. The same four values exist in Go and the
    -- store contract test fails the build if they diverge.
    deductor_class     text NOT NULL CHECK (deductor_class IN (
                           'individual_no_audit', 'individual_audited', 'business', 'government')),
    landlord_residency text NOT NULL CHECK (landlord_residency IN ('resident', 'non_resident')),

    -- Residency is asserted rather than proved, so the assertion has an author. When
    -- the assessing officer asks, "the tenant declared it on this date" is an answer
    -- and "the system had it" is not.
    source        text NOT NULL CHECK (btrim(source) <> ''),

    -- The section 195 acknowledgement: the deductor was shown that tax runs from the
    -- first rupee and that the liability for missing it is theirs, and accepted it.
    acknowledged_on date,
    acknowledged_by text,

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES lease_tax_facts(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT lease_tax_facts_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT lease_tax_facts_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- An acknowledgement dated by nobody is not an acknowledgement, and a name with no
    -- date cannot be shown to have preceded the tenancy.
    CONSTRAINT lease_tax_facts_acknowledgement_shape CHECK (
        (acknowledged_on IS NULL) = (acknowledged_by IS NULL)),
    CONSTRAINT lease_tax_facts_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE lease_tax_facts IS
    'ADR-0024. Deductor class and landlord residency over the life of a tenancy — the two facts that select the TDS section. Effective dated: a residency that changes leaves the earlier months as they were deducted.';

-- One set of facts true at a time, per lease. An EXCLUDE rather than a trigger for
-- the reason property_ownership gives: a trigger reads the table it is protecting
-- and is racy exactly when two writers revise the same tenancy.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lease_tax_facts_no_overlap') THEN
        ALTER TABLE lease_tax_facts ADD CONSTRAINT lease_tax_facts_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, lease_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS lease_tax_facts_asof_idx
    ON lease_tax_facts (tenant_id, lease_id, valid_from DESC)
    WHERE retired_at IS NULL;

-- The story's failure scenario, in the database: a tenancy does not start until its
-- tax path is known, and a section 195 tenancy does not start until the deductor has
-- accepted the obligation.
--
-- On the transition into a tenancy rather than on every write, because a draft is a
-- document being written and may legitimately be incomplete. The moment rent can be
-- paid under it, a payment made under facts nobody recorded is a deduction nobody
-- made — and by the time the payout run finds it, nine months of interest and
-- penalty have accrued to a tenant who was never asked.
--
-- Deferred to commit, because the facts and the lease are written together and the
-- facts carry a foreign key to the lease: an immediate check would force the two
-- into an order the caller should not have to know about. What it asserts is that no
-- transaction *ends* with a tenancy whose tax path is unknown.
CREATE OR REPLACE FUNCTION leases_tax_path_is_known() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    f record;
BEGIN
    IF NEW.state <> 'active' OR (TG_OP = 'UPDATE' AND OLD.state = 'active') THEN
        RETURN NULL;
    END IF;

    SELECT * INTO f
      FROM lease_tax_facts
     WHERE lease_id = NEW.id
       AND retired_at IS NULL
       AND validity @> NEW.valid_from;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'lease % cannot start on %: nothing says what the deductor and the '
                        'landlord are, so no TDS section governs its first payment',
                        NEW.id, NEW.valid_from
            USING ERRCODE = 'check_violation';
    END IF;

    IF f.landlord_residency = 'non_resident' AND f.acknowledged_on IS NULL THEN
        RAISE EXCEPTION 'lease % is a section 195 tenancy: tax is deducted from the first rupee '
                        'and the deductor carries the liability, and the tenancy cannot start '
                        'until that is acknowledged', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION leases_tax_path_is_known() IS
    'ADR-0024. A tenancy does not start with an unknown TDS path, and a section 195 tenancy does not start unacknowledged. Deferred to commit: the facts and the lease are written together.';

DROP TRIGGER IF EXISTS leases_tax_path_known ON leases;
CREATE CONSTRAINT TRIGGER leases_tax_path_known
    AFTER INSERT OR UPDATE ON leases
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION leases_tax_path_is_known();

ALTER TABLE lease_tax_facts ENABLE ROW LEVEL SECURITY;
ALTER TABLE lease_tax_facts FORCE  ROW LEVEL SECURITY;

-- The parent lease's policy governs, as with lease_parties: one definition of who may
-- see a tenancy rather than three that drift apart.
DROP POLICY IF EXISTS lease_tax_facts_tenant_isolation ON lease_tax_facts;
CREATE POLICY lease_tax_facts_tenant_isolation ON lease_tax_facts
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.id = lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. What the tenant declared, and when, is the whole
-- defence when a deduction is questioned years later.
DROP POLICY IF EXISTS lease_tax_facts_no_delete ON lease_tax_facts;
CREATE POLICY lease_tax_facts_no_delete ON lease_tax_facts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON lease_tax_facts TO dwellm8_lease;
-- Money reads the path to deduct against it, and writes none of it: the section is
-- the lease's fact, not the payout's.
GRANT SELECT ON lease_tax_facts TO dwellm8_money, dwellm8_notify;

-- ---------------------------------------------------------------------------
-- identity — who signed in, and what they may act as (ADR-0027)
-- ---------------------------------------------------------------------------
--
-- A Google Identity Platform user, and the person they are here.
--
-- One GIP tenant per app surface, so the same phone number in Own and in Live is
-- two separate user records with no way to reach each other — that isolation is
-- Google's rather than ours. A uid is therefore unique only *within* a pool, and
-- the key here is the pair: (surface, gip_uid). A unique index on gip_uid alone
-- would collide two different people the first time Google reused an id across
-- tenants.
--
-- Dwellm8 staff authenticate at the project level with no tenant at all, and
-- carry surface = 'staff'. That is the product-owner exception, and it is the
-- absence of a tenant claim rather than a boolean anybody can set.
CREATE TABLE IF NOT EXISTS identity_principals (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- Which pool they signed into. 'staff' is the project level.
    surface       text NOT NULL CHECK (surface IN (
                      'own', 'ops', 'live', 'find', 'pro', 'admin', 'staff')),
    gip_uid       text NOT NULL CHECK (btrim(gip_uid) <> ''),

    -- The person. Not an organisation: one person may be a tenant of one
    -- organisation and an owner in another, and the membership table below is
    -- what says which.
    party_id      uuid NOT NULL DEFAULT gen_random_uuid(),

    -- The verified identifier, kept because it is how support finds somebody and
    -- how a tenancy is matched to a sign-in. Phone is the one Indian rental runs
    -- on. Never a password, and never an Aadhaar number — ADR-0013 §2.
    phone         text CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$'),
    email         citext,
    sign_in_provider text CHECK (sign_in_provider IN ('phone', 'google.com', 'apple.com')),

    first_seen_at timestamptz NOT NULL DEFAULT now(),
    last_seen_at  timestamptz NOT NULL DEFAULT now(),
    -- Disabling is a timestamp rather than a delete: the sign-ins, the audit rows
    -- and the tenancies all point here.
    disabled_at   timestamptz,

    CONSTRAINT identity_principals_pool_uid UNIQUE (surface, gip_uid)
);

COMMENT ON TABLE identity_principals IS
    'ADR-0027. A GIP user in one surface pool, and the person they are. Unique on (surface, gip_uid): a uid is unique within a pool, not across pools.';

-- One renter, one party id, however many landlords. ADR-0029 §2.
--
-- A tenancy is created by the landlord, who types their tenant's mobile number
-- before that person has ever opened the app — so the Live principal exists
-- before the sign-in does, keyed by the number, and the first sign-in claims it.
-- Without this index the second landlord to enter the same number would mint a
-- second party id, and the renter would sign in to find one of their two flats.
--
-- Disabled rows are included deliberately: a suspended principal keeps its
-- number reserved, so a support decision cannot be walked around by adding the
-- person to a new lease.
CREATE UNIQUE INDEX IF NOT EXISTS identity_principals_live_phone_idx
    ON identity_principals (phone) WHERE surface = 'live' AND phone IS NOT NULL;

-- No tenant_id, and that is the point: a principal exists before they belong to
-- any organisation — somebody signing into Find is nobody's tenant yet. So it is
-- not tenant-scoped data, and it is not readable by the request role at all.
-- Only the identity module may see it, which is a grant rather than a policy.
REVOKE ALL ON identity_principals FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON identity_principals TO dwellm8_identity;

-- What a person may act as.
--
-- This is the row that turns a verified sign-in into an organisation, and it is
-- the only thing that does. A token says who somebody is; this says what they
-- may be. Conflating the two would put the tenancy boundary in a claim whose
-- contents the client controls.
CREATE TABLE IF NOT EXISTS organisation_members (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    party_id      uuid NOT NULL,

    -- What they are in this organisation. Coarse on purpose: fine-grained
    -- permission is ADR-0005's delegation grants and OpenFGA, and a role column
    -- that tried to express both would express neither.
    role          text NOT NULL CHECK (role IN ('owner', 'manager', 'staff', 'tenant', 'vendor')),

    -- Effective dated, like every other membership here: somebody leaves a firm,
    -- and the question a year later is what they could see while they were there.
    valid_from    date NOT NULL DEFAULT current_date,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT organisation_members_window CHECK (valid_to IS NULL OR valid_to > valid_from)
);

COMMENT ON TABLE organisation_members IS
    'ADR-0027. What a person may act as in an organisation. Effective dated: the question after somebody leaves is what they could see while they were there.';

-- One live membership per person per organisation per role.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'organisation_members_no_overlap') THEN
        ALTER TABLE organisation_members ADD CONSTRAINT organisation_members_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, party_id WITH =, role WITH =, validity WITH &&);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS organisation_members_party_idx
    ON organisation_members (party_id, valid_from DESC);

ALTER TABLE organisation_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE organisation_members FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS organisation_members_tenant_isolation ON organisation_members;
CREATE POLICY organisation_members_tenant_isolation ON organisation_members
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A revoked membership is closed, never deleted: losing it loses the record of
-- what somebody could reach and when.
DROP POLICY IF EXISTS organisation_members_no_delete ON organisation_members;
CREATE POLICY organisation_members_no_delete ON organisation_members AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON organisation_members TO dwellm8_identity;
GRANT SELECT ON organisation_members
    TO dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
       dwellm8_community, dwellm8_discovery, dwellm8_notify;

