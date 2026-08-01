-- ===========================================================================
-- section 197 certificates — a rate the Assessing Officer set for one landlord
-- ===========================================================================

-- A lower or nil deduction certificate under section 197: the Assessing Officer
-- has determined that this landlord's tax on this income is less than the section
-- rate would deduct, and issued a certificate saying so.
--
-- **Beside the registry, not in it.** statutory_rules holds what the law says for
-- everyone and has no runtime writer on purpose (ADR-0023 §2); this is a fact
-- about one landlord, produced by an officer, entered by a user, and scoped to an
-- organisation. Putting it in the registry would mean handing back the INSERT that
-- ADR-0023 revoked, which is the exact defect assertion 18 exists to catch.
--
-- It is also the only thing that makes a section 195 deduction computable, since
-- the registry deliberately holds no section 195 rate (ADR-0024 §5). ADR-0025 §1.
CREATE TABLE IF NOT EXISTS tds_certificates (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    -- The landlord the certificate is for. A bare uuid like every other party
    -- reference here: a payee is a person or a company who may hold no account.
    party_id      uuid NOT NULL,

    -- A certificate is issued for a section. One that names 194-I does not lower
    -- a 195 deduction, and applying it to both is how a nil certificate for rent
    -- ends up applied to a capital payment.
    section       text NOT NULL CHECK (section IN ('194i', '194ib', '195')),

    certificate_number text NOT NULL CHECK (btrim(certificate_number) <> ''),
    -- Zero is a nil-deduction certificate, which is a real and common outcome —
    -- and the reason this is a rate rather than a nullable "lower rate".
    rate_bps      int NOT NULL CHECK (rate_bps >= 0 AND rate_bps <= 1000000),

    -- A certificate always expires: it is issued for a period, usually to the end
    -- of the financial year. valid_to is NOT NULL for that reason, unlike every
    -- other effective-dated table here — an open-ended certificate would keep
    -- lowering a deduction for years after the officer's determination lapsed.
    valid_from    date NOT NULL,
    valid_to      date NOT NULL,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    issued_on     date NOT NULL,
    -- Which officer or circle issued it. Free text because the format is not ours.
    issued_by     text,

    retired_at    timestamptz,
    corrects      uuid REFERENCES tds_certificates(id),

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    CONSTRAINT tds_certificates_window CHECK (valid_to > valid_from),
    -- A certificate cannot apply before it was issued. The other direction is
    -- legitimate: an officer issues in June for a period beginning in April.
    CONSTRAINT tds_certificates_issued_before_expiry CHECK (issued_on < valid_to),
    CONSTRAINT tds_certificates_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE tds_certificates IS
    'ADR-0025. Section 197 lower/nil deduction certificates: a rate an Assessing Officer set for one landlord, for one section, for a bounded period. Tenant data, deliberately not in statutory_rules.';

-- One live certificate per landlord per section per day. Two would mean two rates
-- for the same deduction and whichever sorted first would win.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tds_certificates_no_overlap') THEN
        ALTER TABLE tds_certificates ADD CONSTRAINT tds_certificates_no_overlap
            EXCLUDE USING gist (tenant_id WITH =, party_id WITH =, section WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS tds_certificates_asof_idx
    ON tds_certificates (tenant_id, party_id, section, valid_from DESC)
    WHERE retired_at IS NULL;

ALTER TABLE tds_certificates ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_certificates FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tds_certificates_tenant_isolation ON tds_certificates;
CREATE POLICY tds_certificates_tenant_isolation ON tds_certificates
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A certificate is the authority for having deducted
-- less than the section says, and it is the first document produced when that is
-- questioned.
DROP POLICY IF EXISTS tds_certificates_no_delete ON tds_certificates;
CREATE POLICY tds_certificates_no_delete ON tds_certificates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON tds_certificates TO dwellm8_lease;
GRANT SELECT ON tds_certificates TO dwellm8_money, dwellm8_notify;

