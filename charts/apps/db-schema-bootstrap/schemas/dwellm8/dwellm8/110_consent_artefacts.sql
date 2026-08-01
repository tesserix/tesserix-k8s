-- ===========================================================================
-- consent artefacts — what was agreed to, and under which notice (ADR-0026)
-- ===========================================================================

-- The thing ADR-0013 was already pointing at. kyc_verifications has carried a
-- NOT NULL consent_artefact_id since it was written, referencing a table that
-- did not exist — so the column was a promise rather than a link.
--
-- An object rather than a boolean, because "the user agreed" is not evidence of
-- anything a year later when the notice has been reworded twice. DPDP §5
-- requires the notice to state the purpose and to be available in English or a
-- language in the Eighth Schedule; recording which version and which language
-- were actually shown is what makes either claim checkable.
CREATE TABLE IF NOT EXISTS consent_artefacts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    party_id      uuid NOT NULL,

    -- The purposes the product actually processes for. A free-text purpose is a
    -- purpose nobody can audit, and withdrawal has to be answerable per purpose.
    purpose       text NOT NULL CHECK (purpose IN (
                      'tenancy', 'kyc', 'payments', 'statutory', 'marketing', 'support')),

    -- Which wording was shown. Not a foreign key to a notices table yet: the
    -- notice content is versioned in the repository, and a version string is
    -- what ties this row to a commit.
    notice_version text NOT NULL CHECK (btrim(notice_version) <> ''),
    -- An ISO 639-1 code. English or an Eighth Schedule language, and which one
    -- was shown is the data principal's right rather than a preference.
    language      text NOT NULL CHECK (language ~ '^[a-z]{2}$'),

    given_at      timestamptz NOT NULL DEFAULT now(),
    withdrawn_at  timestamptz,

    -- How it was collected, so a disputed consent can be traced to a screen.
    channel       text CHECK (channel IN ('app', 'web', 'in_person', 'agent')),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT consent_artefacts_withdrawal CHECK (
        withdrawn_at IS NULL OR withdrawn_at >= given_at),
    -- So kyc_verifications can carry a composite key and a verification cannot
    -- cite another organisation's consent.
    CONSTRAINT consent_artefacts_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE consent_artefacts IS
    'ADR-0026. What was consented to, for which purpose, under which notice version and in which language. Withdrawal is a timestamp, never a delete.';

-- One live consent per person per purpose. A second would mean two answers to
-- "may we process this", and whichever sorted first would win.
CREATE UNIQUE INDEX IF NOT EXISTS consent_artefacts_one_live_idx
    ON consent_artefacts (tenant_id, party_id, purpose)
    WHERE withdrawn_at IS NULL;

-- The link ADR-0013 promised. NOT VALID, and deliberately: existing rows carry
-- ids that point nowhere, and validating against them would fail the bootstrap
-- on a database that is otherwise correct. New rows are checked from here on,
-- and the backfill is its own reviewed change.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'kyc_verifications_consent_fkey') THEN
        ALTER TABLE kyc_verifications ADD CONSTRAINT kyc_verifications_consent_fkey
            FOREIGN KEY (consent_artefact_id, tenant_id)
            REFERENCES consent_artefacts (id, tenant_id) NOT VALID;
    END IF;
END
$$;

ALTER TABLE consent_artefacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE consent_artefacts FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS consent_artefacts_tenant_isolation ON consent_artefacts;
CREATE POLICY consent_artefacts_tenant_isolation ON consent_artefacts
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A withdrawn consent is not a deleted one. The record that consent was given,
-- and then taken back, is the evidence in both directions.
DROP POLICY IF EXISTS consent_artefacts_no_delete ON consent_artefacts;
CREATE POLICY consent_artefacts_no_delete ON consent_artefacts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON consent_artefacts
    TO dwellm8_identity, dwellm8_lease, dwellm8_discovery;
GRANT SELECT ON consent_artefacts TO dwellm8_money, dwellm8_notify, dwellm8_community;

