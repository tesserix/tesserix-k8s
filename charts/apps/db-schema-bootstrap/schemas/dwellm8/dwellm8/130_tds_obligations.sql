-- ===========================================================================
-- TDS obligations — what a deduction obliges, and whether it was done
-- ===========================================================================

-- One row per deduction per lease per period, and one child row per step: the
-- deduction itself, the deposit, the return and the certificate.
--
-- A tracker rather than a calculation. The amount is computed elsewhere and the
-- dates are statutory; what this table holds is whether each step happened and
-- what proves it — a challan identification number, an acknowledgement number, a
-- certificate number. "Deposited, trust me" is exactly the state it exists to
-- refuse, because the CIN is the only thing that links the payment to the
-- deduction when a notice arrives two years later.
--
-- Steps are rows rather than columns for the reason ADR-0008 gives generally:
-- §194-IB has no deposit step at all (Form 26QC is a challan-cum-statement), so
-- a `deposited_on` column would be permanently NULL on that path and permanently
-- ambiguous — never happened, or never applied.
CREATE TABLE IF NOT EXISTS tds_obligations (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL,

    section       text NOT NULL CHECK (section IN ('194i', '194ib', '195')),

    -- What the deduction is on, and when the rent it came from was paid or
    -- credited — every deadline below runs from that date.
    period_from   date NOT NULL,
    period_to     date NOT NULL,
    paid_on       date NOT NULL,

    -- ADR-0007: an integer of minor units.
    amount_minor  bigint NOT NULL CHECK (amount_minor > 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The rows the deduction was computed from, so what was deducted can be
    -- explained years later without recomputing it against today's registry.
    rate_bps      int NOT NULL CHECK (rate_bps >= 0),
    rate_rule_id  uuid REFERENCES statutory_rules(id),
    certificate_id uuid REFERENCES tds_certificates(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tds_obligations_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT tds_obligations_period CHECK (period_to > period_from),
    -- One deduction per lease per period per section. A second is either a
    -- duplicate or a correction, and a correction is a reversal plus a new row.
    CONSTRAINT tds_obligations_once UNIQUE (tenant_id, lease_id, section, period_from),
    -- So the steps can carry a composite key back to their obligation, which is
    -- what makes "the step and its obligation belong to the same organisation"
    -- structural rather than conventional.
    CONSTRAINT tds_obligations_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE tds_obligations IS
    'ADR-0024 and ADR-0025. One deduction, its statutory deadlines and the evidence that each step was done.';

CREATE TABLE IF NOT EXISTS tds_obligation_steps (
    obligation_id uuid NOT NULL REFERENCES tds_obligations(id) ON DELETE CASCADE,
    -- Denormalised from the parent, and assertion 12 is why: a table whose rows
    -- may belong to no organisation cannot be constrained by
    -- tenant_id = current_tenant_id(), so any organisation could write a row
    -- belonging to none. The composite foreign key below keeps the two in step.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    step          text NOT NULL CHECK (step IN ('deduct', 'deposit', 'report', 'certify')),

    due_by        date NOT NULL,
    artefact      text NOT NULL,

    -- Outstanding until both are present. A reference with no date, or a date
    -- with no reference, is a step somebody started recording and did not
    -- finish — and treating it as done is how an unfiled return looks filed.
    reference     text,
    done_on       date,

    PRIMARY KEY (obligation_id, step),
    CONSTRAINT tds_obligation_steps_obligation_fkey FOREIGN KEY (obligation_id, tenant_id)
        REFERENCES tds_obligations (id, tenant_id) ON DELETE CASCADE,
    CONSTRAINT tds_obligation_steps_evidence CHECK (
        (reference IS NULL) = (done_on IS NULL))
);

COMMENT ON TABLE tds_obligation_steps IS
    'The steps one deduction obliges. A step is done when it has both a reference and a date; a challan number with no date is not a deposit.';

CREATE INDEX IF NOT EXISTS tds_obligation_steps_outstanding_idx
    ON tds_obligation_steps (due_by)
    WHERE reference IS NULL;

ALTER TABLE tds_obligations      ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_obligations      FORCE  ROW LEVEL SECURITY;
ALTER TABLE tds_obligation_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tds_obligation_steps FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tds_obligations_tenant_isolation ON tds_obligations;
CREATE POLICY tds_obligations_tenant_isolation ON tds_obligations
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- The child carries no tenant of its own, so the parent's policy governs it —
-- one definition of who may see a deduction rather than two that drift.
DROP POLICY IF EXISTS tds_obligation_steps_tenant_isolation ON tds_obligation_steps;
CREATE POLICY tds_obligation_steps_tenant_isolation ON tds_obligation_steps
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS tds_obligation_steps_no_delete ON tds_obligation_steps;
CREATE POLICY tds_obligation_steps_no_delete ON tds_obligation_steps AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Nothing here may be deleted. What was deducted, when it was deposited and
-- which challan carried it is the answer to a notice, and a deleted row is a
-- deduction that cannot be proved.
DROP POLICY IF EXISTS tds_obligations_no_delete ON tds_obligations;
CREATE POLICY tds_obligations_no_delete ON tds_obligations AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON tds_obligations, tds_obligation_steps TO dwellm8_money;
GRANT SELECT ON tds_obligations, tds_obligation_steps TO dwellm8_lease, dwellm8_notify;

