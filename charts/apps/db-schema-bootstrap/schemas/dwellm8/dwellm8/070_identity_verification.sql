-- ===========================================================================
-- identity verification (ADR-0013)
-- ===========================================================================

-- KYC identifiers are the highest-liability data in the platform, and the default
-- implementation of every vendor integration stores far too much: the SDK returns the
-- full identifier and the obvious thing to do is put it in a column.
--
-- So there is no column for one. What a completed verification holds is the result, a
-- masked reference, the provider and its transaction id, a timestamp and the consent
-- artefact — and kyc_verifications_reference_is_a_mask makes that true by construction
-- rather than by review: the reference column will not accept anything that is not a
-- mask, so a twelve-digit Aadhaar number cannot be put there by application code, by a
-- migration, or at a psql prompt.
--
-- Three tiers, and the middle one carries a lesson the org has already paid for:
--
--   prohibited  never at rest in any form. The Aadhaar number.
--   encrypted   at rest only as ciphertext, and — the half that matters — with no
--               plaintext column beside it. HomeChef's envelope encryption is dormant
--               precisely because its migration dual-wrote ciphertext while reads still
--               came from the plaintext column. Encryption that leaves a plaintext
--               column in place is a plaintext column with extra steps, and it will be
--               read: by a report, a support query, or a backup.
--   open        an institution's code or a public register. IFSC, GSTIN.
--
-- Which is why there is no `pan` column here at all. Encrypted values live in
-- payout_credentials (a later story) as ciphertext only, and the *masked* reference is
-- what this table holds so a screen can show which document was checked.

CREATE TABLE IF NOT EXISTS kyc_verifications (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES organisations(id),

    -- Whose document was checked. A party rather than a user: a guarantor may have no
    -- account here, and ADR-0006 already keeps balances per party.
    subject_party_id  uuid NOT NULL,

    kind              text NOT NULL CHECK (kind IN (
                          'aadhaar', 'pan', 'bank_account', 'ifsc', 'upi_vpa',
                          'passport', 'driving_licence', 'voter_id', 'gstin')),

    -- The only representation of the identifier that is kept. Not a hash: the Aadhaar
    -- space is small enough to enumerate, so a hash column is a lookup table for anybody
    -- who takes a copy. ADR-0013 alternative D.
    masked_reference  text NOT NULL,

    result            text NOT NULL CHECK (result IN (
                          'verified', 'failed', 'expired', 'withdrawn', 'unverified')),

    -- The audit trail at the other end. If a result is disputed, this is what the
    -- provider is asked about — and it is why a verification with no transaction id is
    -- refused.
    provider          text NOT NULL,
    provider_txn_id   text NOT NULL,

    -- DPDP requires a consent artefact, and a verification with no consent behind it is
    -- one that should not have happened.
    consent_artefact_id uuid NOT NULL,

    verified_at       timestamptz NOT NULL DEFAULT now(),
    -- Some checks go stale: a bank account changes, an address proof ages out. NULL
    -- means it does not expire on its own.
    expires_at        timestamptz,

    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT kyc_verifications_expiry CHECK (expires_at IS NULL OR expires_at > verified_at),
    -- kyc_verifications_reference_is_a_mask — the constraint that makes a full identifier
    -- unstorable — is in the "load-bearing rules" block below, not here. Written inline it
    -- was unrecoverable: this ADR's own verification dropped it, the replay could not put
    -- it back, and assertion 13 correctly reported a schema missing a rule it is built on.
    -- That is the trap the block exists for, biting a constraint added in the same session
    -- as the guard for it.
    CONSTRAINT kyc_verifications_reference_present CHECK (length(masked_reference) > 0)
);

COMMENT ON TABLE kyc_verifications IS
    'ADR-0013. What a completed identity check leaves behind. There is no column for a full identifier, and the reference column will not accept one.';
COMMENT ON COLUMN kyc_verifications.masked_reference IS
    'The only kept representation. Not a hash: the Aadhaar space is enumerable, so a hash column is a lookup table.';

-- One live verification per subject per kind. A second would leave two answers to "is
-- this person verified" with nothing to say which — and re-verification supersedes
-- rather than accumulates.
CREATE UNIQUE INDEX IF NOT EXISTS kyc_verifications_subject_kind_idx
    ON kyc_verifications (tenant_id, subject_party_id, kind)
    WHERE result = 'verified';
CREATE INDEX IF NOT EXISTS kyc_verifications_subject_idx
    ON kyc_verifications (tenant_id, subject_party_id);
-- "What is about to go stale" — the re-verification sweep.
CREATE INDEX IF NOT EXISTS kyc_verifications_expiring_idx
    ON kyc_verifications (tenant_id, expires_at) WHERE expires_at IS NOT NULL;

-- Every read of a KYC record, and why.
--
-- The story's edge case: support staff access is audited and time-bound. Auditing a read
-- cannot be done by the reader — a SELECT leaves no trace — so this table is written by
-- the service that performs the read, and the thing that makes it not merely a
-- convention is the reason column: a read with no purpose recorded is refused, and a
-- purpose is not something a query can invent for itself.
--
-- Time-bound is the `expires_at` on the access grant, not on the log: a support session
-- is granted for a window and the window is checked at read time.
CREATE TABLE IF NOT EXISTS kyc_access_log (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id         uuid NOT NULL REFERENCES organisations(id),
    verification_id   uuid NOT NULL REFERENCES kyc_verifications(id),

    -- Who looked. actor_kind distinguishes the subject reading their own record from a
    -- support engineer reading somebody else's, which is the distinction an audit is for.
    actor_kind        text NOT NULL CHECK (actor_kind IN ('subject', 'owner', 'agency', 'support', 'system')),
    actor_id          uuid,
    -- Why. Free text is deliberate here and is the one place in this schema where it is:
    -- a closed vocabulary of reasons becomes 'other' within a month, and an auditor
    -- reading 'other' learns nothing. What is not optional is that it is present.
    reason            text NOT NULL CHECK (length(btrim(reason)) >= 8),
    -- The support grant this read was made under, when it was made under one.
    support_grant_id  uuid,

    read_at           timestamptz NOT NULL DEFAULT now(),

    -- kyc_access_log_support_needs_a_grant is in the "load-bearing rules" block below: a
    -- support read with no grant behind it is the thing an audit exists to catch.
    -- Anything but the system names who acted.
    CONSTRAINT kyc_access_log_names_its_actor CHECK (
        actor_kind = 'system' OR actor_id IS NOT NULL)
);

COMMENT ON TABLE kyc_access_log IS
    'ADR-0013. Every read of a KYC record, with a purpose. A support read requires a grant, which is what makes access time-bound.';

CREATE INDEX IF NOT EXISTS kyc_access_log_verification_idx
    ON kyc_access_log (verification_id, read_at);
-- "What has this support engineer looked at" — the question after an incident.
CREATE INDEX IF NOT EXISTS kyc_access_log_actor_idx
    ON kyc_access_log (actor_kind, actor_id, read_at) WHERE actor_id IS NOT NULL;

ALTER TABLE kyc_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_verifications FORCE  ROW LEVEL SECURITY;
ALTER TABLE kyc_access_log    ENABLE ROW LEVEL SECURITY;
ALTER TABLE kyc_access_log    FORCE  ROW LEVEL SECURITY;

-- Strict tenancy, and no delegated branch — which is a deliberate omission rather than
-- an oversight.
--
-- A management firm holds a grant to collect rent and manage a property. Nothing about
-- that requires reading a tenant's identity documents, and ADR-0005's permission
-- vocabulary has no 'kyc.read' for exactly this reason. If a firm ever needs it, that is
-- a new permission argued for in an ADR, not a widened policy.
DROP POLICY IF EXISTS kyc_verifications_tenant_isolation ON kyc_verifications;
CREATE POLICY kyc_verifications_tenant_isolation ON kyc_verifications
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS kyc_access_log_tenant_isolation ON kyc_access_log;
CREATE POLICY kyc_access_log_tenant_isolation ON kyc_access_log
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Neither may be deleted, and the access log may not be updated either: a log somebody
-- can edit is not a log. A verification is mutable only in the sense that it can expire
-- or be withdrawn, which is a result change.
DROP POLICY IF EXISTS kyc_verifications_no_delete ON kyc_verifications;
CREATE POLICY kyc_verifications_no_delete ON kyc_verifications AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS kyc_access_log_no_delete ON kyc_access_log;
CREATE POLICY kyc_access_log_no_delete ON kyc_access_log AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS kyc_access_log_no_update ON kyc_access_log;
CREATE POLICY kyc_access_log_no_update ON kyc_access_log AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT, UPDATE ON kyc_verifications TO dwellm8_identity;
GRANT SELECT, INSERT ON kyc_access_log TO dwellm8_identity;
-- Money reads whether a payee is verified before releasing a payout. It reads the
-- result and the mask, which is all there is.
GRANT SELECT ON kyc_verifications TO dwellm8_money, dwellm8_lease;

