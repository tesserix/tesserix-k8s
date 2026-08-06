-- ===========================================================================
-- the manager's own merchant account (#269)
-- ===========================================================================

-- Dwellm8 never pools client money: rent is collected into the manager's own
-- account with their own aggregator, under their own agreement, and the
-- platform's fee is retained at capture as a split (ADR-0031). This is where
-- that account lives.
--
-- Provider-agnostic on purpose. Cashfree calls it a merchant, Razorpay a
-- linked account and Stripe a connected account; all three verify a bank
-- account before they will settle to it, so the columns are the union that
-- survives translation and internal/money/domain/merchant owns the states.
--
-- The bank account number is never stored — a mask for humans and the
-- provider's own reference for the transfer, the posture payout_accounts
-- already takes (ADR-0013).

CREATE TABLE IF NOT EXISTS merchant_accounts (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),

    provider       text NOT NULL CHECK (btrim(provider) <> ''),
    -- The provider's id for the account. Absent until they have created it,
    -- which is why an unconnected row is a legitimate state rather than no row.
    merchant_ref   text,

    country        text NOT NULL DEFAULT 'IN' CHECK (country ~ '^[A-Z]{2}$'),
    business_name  text NOT NULL CHECK (btrim(business_name) <> ''),
    business_type  text NOT NULL DEFAULT 'individual' CHECK (business_type IN
                       ('individual', 'proprietorship', 'partnership', 'llp', 'company', 'trust')),

    state          text NOT NULL DEFAULT 'unconnected' CHECK (state IN
                       ('unconnected', 'submitted', 'verified', 'suspended')),
    -- The provider's own words when it refuses or suspends, so the manager is
    -- told what to fix rather than that something went wrong.
    reason         text,

    settlement_holder   text,
    settlement_masked   text,
    settlement_ifsc     text,
    settlement_currency text NOT NULL DEFAULT 'INR' CHECK (settlement_currency ~ '^[A-Z]{3}$'),
    settlement_swift    text,

    -- PAN and GSTIN are the business's own identifiers, masked like every other
    -- one (ADR-0013 §2). The unmasked PAN reaches the provider and is not kept.
    tax_id_masked  text CHECK (tax_id_masked IS NULL OR tax_id_masked ~ '^X+[0-9A-Z]{4}$'),
    gstin          text CHECK (gstin IS NULL OR
                       gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z][Z][0-9A-Z]$'),

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    verified_at    timestamptz,

    -- A full account number does not fit in the only column that could hold one.
    CONSTRAINT merchant_accounts_account_is_a_mask CHECK (
        settlement_masked IS NULL
        OR (settlement_masked !~ '^[0-9]+$' AND length(settlement_masked) BETWEEN 6 AND 24)),
    -- An Indian settlement account needs an IFSC; an international one has none.
    CONSTRAINT merchant_accounts_indian_shape CHECK (
        country <> 'IN' OR settlement_ifsc IS NULL OR settlement_ifsc ~ '^[A-Z]{4}0[A-Z0-9]{6}$'),
    -- Money cannot be collected into an account that names neither a provider
    -- record nor somewhere to settle, so verified must have both.
    CONSTRAINT merchant_accounts_verified_is_settleable CHECK (
        state <> 'verified'
        OR (merchant_ref IS NOT NULL AND settlement_masked IS NOT NULL AND verified_at IS NOT NULL)),
    CONSTRAINT merchant_accounts_reason_shape CHECK (
        state IN ('suspended', 'unconnected') OR reason IS NULL OR btrim(reason) <> '')
);

COMMENT ON TABLE merchant_accounts IS
    '#269. The manager''s own account with an aggregator. Rent settles here, not into a platform account; the number is masked and the provider holds the real one.';

-- One account per manager per provider. A manager on two aggregators is
-- ordinary — Cashfree for UPI and Stripe for an NRI paying from abroad.
CREATE UNIQUE INDEX IF NOT EXISTS merchant_accounts_one_per_provider
    ON merchant_accounts (tenant_id, provider);

CREATE INDEX IF NOT EXISTS merchant_accounts_state_idx
    ON merchant_accounts (tenant_id, state);

ALTER TABLE merchant_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE merchant_accounts FORCE  ROW LEVEL SECURITY;

-- Organisation-scoped, and reachable under a mandate carrying money.payout for
-- the same reason payout_accounts is: a managing firm connects the account it
-- collects into on the owner's behalf.
DROP POLICY IF EXISTS merchant_accounts_tenant_isolation ON merchant_accounts;
CREATE POLICY merchant_accounts_tenant_isolation ON merchant_accounts
    USING      (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, NULL, 'money.payout'))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, NULL, 'money.payout'));

DROP POLICY IF EXISTS merchant_accounts_resident_denied ON merchant_accounts;
CREATE POLICY merchant_accounts_resident_denied ON merchant_accounts AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- An account is disconnected by suspending it, never by deleting the row that
-- says where March's rent went.
DROP POLICY IF EXISTS merchant_accounts_no_delete ON merchant_accounts;
CREATE POLICY merchant_accounts_no_delete ON merchant_accounts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON merchant_accounts TO dwellm8_money;
GRANT SELECT ON merchant_accounts TO dwellm8_property;
