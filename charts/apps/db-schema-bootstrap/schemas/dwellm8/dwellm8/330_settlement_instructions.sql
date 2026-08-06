-- ===========================================================================
-- settlement instructions — how one collection is divided (#270)
-- ===========================================================================
-- Three parties claim on the same rupee and one of them is the government.
-- The division is computed on the ledger, once, when the payment is captured,
-- and written here so the payout run, the owner statement and the settlement
-- reconciliation all read the same numbers rather than three recomputations.
--
-- ADR-0031 for the platform's leg, ADR-0024 for the deduction. The legs are
-- stored rather than derived because a rate that changes next April must not
-- restate what was settled last March.
CREATE TABLE IF NOT EXISTS settlement_instructions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    payment_id    uuid NOT NULL REFERENCES payments(id),
    lease_id      uuid REFERENCES leases(id),
    currency      text NOT NULL DEFAULT 'INR' CHECK (currency ~ '^[A-Z]{3}$'),
    gross_minor       bigint NOT NULL CHECK (gross_minor > 0),
    platform_minor    bigint NOT NULL DEFAULT 0 CHECK (platform_minor >= 0),
    management_minor  bigint NOT NULL DEFAULT 0 CHECK (management_minor >= 0),
    tds_minor         bigint NOT NULL DEFAULT 0 CHECK (tds_minor >= 0),
    owner_minor       bigint NOT NULL CHECK (owner_minor >= 0),
    fee_rule_id   text,
    -- Where the owner's leg has got to. instructed means a transfer was sent to
    -- the provider; settled means their settlement report agreed.
    state         text NOT NULL DEFAULT 'pending'
                       CHECK (state IN ('pending', 'instructed', 'settled', 'failed')),
    provider      text,
    transfer_ref  text,
    -- The date the schedule says the money should land, so a payout that has
    -- not arrived is visible before anybody complains.
    expected_on   date,
    settled_on    date,
    reason        text,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    -- The invariant reconciliation runs on: every paisa the tenant paid is
    -- accounted to somebody. ADR-0031 §4.
    CONSTRAINT settlement_instructions_legs_make_the_whole CHECK (
        platform_minor + management_minor + tds_minor + owner_minor = gross_minor),
    CONSTRAINT settlement_instructions_settled_is_referenced CHECK (
        state <> 'settled' OR (transfer_ref IS NOT NULL AND settled_on IS NOT NULL)),
    CONSTRAINT settlement_instructions_reason_shape CHECK (
        state = 'failed' OR reason IS NULL OR btrim(reason) <> '')
);

COMMENT ON TABLE settlement_instructions IS
    '#270. One collection divided between owner, manager, platform and the deduction. Computed at capture, read by the payout run and the reconciliation.';

-- One division per collection: a second row would be a second answer to who
-- gets what, and the payout run would pay both.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_instructions_one_per_payment
    ON settlement_instructions (payment_id);

CREATE INDEX IF NOT EXISTS settlement_instructions_due_idx
    ON settlement_instructions (tenant_id, state, expected_on)
    WHERE state IN ('pending', 'instructed');

ALTER TABLE settlement_instructions ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_instructions FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS settlement_instructions_tenant_isolation ON settlement_instructions;
CREATE POLICY settlement_instructions_tenant_isolation ON settlement_instructions
    USING      (tenant_id = current_tenant_id()
                OR is_platform_session()
                OR is_delegated(tenant_id, NULL, 'money.payout'))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- ADR-0029. What the manager and the platform keep is not the renter's
-- business; the renter's receipt is the payment, which they already read.
DROP POLICY IF EXISTS settlement_instructions_resident_denied ON settlement_instructions;
CREATE POLICY settlement_instructions_resident_denied ON settlement_instructions AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS settlement_instructions_no_delete ON settlement_instructions;
CREATE POLICY settlement_instructions_no_delete ON settlement_instructions AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON settlement_instructions TO dwellm8_money;
GRANT SELECT ON settlement_instructions TO dwellm8_property;

-- The schedule the provider settles on, per merchant account: T+1, T+2, or a
-- manager who releases each payout by hand. Kept beside the account because it
-- is the provider's promise, not the tenancy's.
ALTER TABLE merchant_accounts
    ADD COLUMN IF NOT EXISTS settlement_days smallint NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS settlement_manual boolean NOT NULL DEFAULT false;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'merchant_accounts_schedule_shape') THEN
        ALTER TABLE merchant_accounts ADD CONSTRAINT merchant_accounts_schedule_shape
            CHECK (settlement_days BETWEEN 0 AND 30);
    END IF;
END
$$;
