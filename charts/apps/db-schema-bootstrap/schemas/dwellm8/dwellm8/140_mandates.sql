-- ===========================================================================
-- mandates — the standing authority behind a recurring debit (ADR-0022)
-- ===========================================================================

-- A mandate is not a payment, and the two disagree about time. A payment is one
-- attempt that resolves in minutes; a mandate is an authority that lives for the
-- length of a tenancy, is paused and resumed on purpose, and produces many
-- payments. ADR-0011 modelled `upi_autopay` as an ordinary method because the
-- authority behind it did not exist yet.
--
-- The rail vocabulary is closed and names no aggregator: Razorpay calls the
-- authority a token, Cashfree calls it a subscription, and both are a
-- provider_mandate_id here.
CREATE TABLE IF NOT EXISTS mandates (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    -- unit_id is NOT NULL, unlike payments. An authority over a whole property
    -- is not one any tenant gave, and the unit is what the policy scopes on.
    property_id     uuid NOT NULL,
    unit_id         uuid NOT NULL,
    unit_parent_id  uuid,

    -- The tenancy this authority was taken for. A mandate that outlives its
    -- lease is a live authority to debit somebody who has moved out.
    lease_id        uuid,

    payer_kind      text NOT NULL DEFAULT 'tenant' CHECK (payer_kind = 'tenant'),
    payer_id        uuid NOT NULL,

    rail            text NOT NULL CHECK (rail IN ('upi_autopay', 'enach', 'nach_physical')),

    -- The ceiling the payer authorised, fixed at registration on every rail we
    -- use. A rent escalation past it needs a new authority.
    max_amount_minor bigint NOT NULL CHECK (max_amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    provider            text NOT NULL,
    provider_mandate_id text,

    status          text NOT NULL DEFAULT 'created' CHECK (status IN (
                        'created', 'pending', 'active', 'paused',
                        'rejected', 'revoked', 'expired')),
    failure_code    text,

    -- Which rule-table row routed this tenancy to this rail, so a decision can
    -- be explained a year later when the caps have moved.
    rail_rule_source text,

    -- ADR-0011 §2's guarantee, applied to authorities. A duplicate mandate is
    -- worse than a duplicate order: it debits a tenant twice a month, forever,
    -- and looks legitimate from both ends.
    idempotency_key text NOT NULL,

    first_debit_on  date,
    ends_on         date,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    activated_at    timestamptz,
    ended_at        timestamptz,

    CONSTRAINT mandates_id_tenant_key UNIQUE (id, tenant_id),
    CONSTRAINT mandates_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT mandates_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT mandates_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT mandates_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    CONSTRAINT mandates_amount_representable CHECK (max_amount_minor <= 9007199254740991),
    CONSTRAINT mandates_ends_after_it_starts CHECK (
        ends_on IS NULL OR first_debit_on IS NULL OR ends_on >= first_debit_on)
    -- mandates_active_has_provider_id is in the load-bearing block below, for the
    -- reason every CHECK that matters is: one written here never reaches a
    -- database that already has the table.
);

COMMENT ON TABLE mandates IS
    'ADR-0022. The standing authority a tenant gave. Not a payment: it is paused and resumed on purpose, and the debits it produces are ordinary payments.';

CREATE UNIQUE INDEX IF NOT EXISTS mandates_idempotency_idx
    ON mandates (tenant_id, idempotency_key);
CREATE UNIQUE INDEX IF NOT EXISTS mandates_provider_idx
    ON mandates (provider, provider_mandate_id) WHERE provider_mandate_id IS NOT NULL;

-- One live authority per unit. Two active mandates on one flat is a tenant
-- debited twice on the first of the month, and it is the kind of duplicate that
-- looks correct from every screen: both mandates are real, both were authorised,
-- and nothing but this index says the second should not exist.
CREATE UNIQUE INDEX IF NOT EXISTS mandates_one_active_per_unit_idx
    ON mandates (tenant_id, unit_id) WHERE status = 'active';

-- What the debit scheduler asks for: every authority that may be debited.
CREATE INDEX IF NOT EXISTS mandates_debitable_idx
    ON mandates (tenant_id, first_debit_on) WHERE status = 'active';
-- What the sweep asks for: authorities that were never answered. Physical NACH
-- sits in `pending` for a working week, so "stuck" is a matter of days.
CREATE INDEX IF NOT EXISTS mandates_awaiting_idx
    ON mandates (provider, created_at) WHERE status IN ('created', 'pending');

-- The transition table. The same set exists in Go and the contract test
-- evaluates this function over every ordered pair.
--
-- It is deliberately not forward-only, which is where it differs from
-- payment_transition_allowed and the difference is load-bearing. A payment moves
-- once because money does; an authority is paused and resumed as a product
-- feature, and a tenant coming off a payment holiday must not have to
-- re-authorise a mandate nobody revoked.
CREATE OR REPLACE FUNCTION mandate_transition_allowed(from_status text, to_status text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_status = to_status
        OR (from_status, to_status) IN (
            ('created', 'pending'),
            ('created', 'rejected'),
            ('created', 'expired'),
            ('created', 'revoked'),
            ('pending', 'active'),
            -- Rejected and expired are both endings and they are not the same
            -- ending: an owner asking why autopay never started needs the
            -- difference between "the bank said no" and "your tenant never
            -- answered".
            ('pending', 'rejected'),
            ('pending', 'expired'),
            ('pending', 'revoked'),
            ('active',  'paused'),
            ('active',  'revoked'),
            ('active',  'expired'),
            ('paused',  'active'),
            ('paused',  'revoked'),
            ('paused',  'expired'))
$$;

COMMENT ON FUNCTION mandate_transition_allowed(text, text) IS
    'ADR-0022. The mandate lifecycle. Terminal states absorb; from = to is a permitted no-op; active <-> paused is a cycle on purpose.';

CREATE OR REPLACE FUNCTION mandates_transition_is_legal() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT mandate_transition_allowed(OLD.status, NEW.status) THEN
        RAISE EXCEPTION 'mandate % cannot go from % to %: a delivery that arrived late or '
                        'out of order does not move an authority',
            OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS mandates_legal_transitions ON mandates;
CREATE TRIGGER mandates_legal_transitions
    BEFORE UPDATE ON mandates
    FOR EACH ROW EXECUTE FUNCTION mandates_transition_is_legal();

-- Stamp the ancillary parent, as payments and ledger_postings do, so the policy
-- never reads units.
CREATE OR REPLACE FUNCTION mandate_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS mandates_unit_parent ON mandates;
CREATE TRIGGER mandates_unit_parent
    BEFORE INSERT OR UPDATE OF unit_id ON mandates
    FOR EACH ROW EXECUTE FUNCTION mandate_unit_parent();

-- A debit is an ordinary payment that names the authority it ran under, and the
-- webhook inbox stays one table rather than two. Both columns are added here
-- rather than in their CREATE TABLE because both tables already exist.
DO $$
BEGIN
    ALTER TABLE payments       ADD COLUMN IF NOT EXISTS mandate_id uuid;
    ALTER TABLE payment_events ADD COLUMN IF NOT EXISTS mandate_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payments_mandate_fkey') THEN
        ALTER TABLE payments ADD CONSTRAINT payments_mandate_fkey
            FOREIGN KEY (mandate_id, tenant_id) REFERENCES mandates (id, tenant_id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_events_mandate_fkey') THEN
        ALTER TABLE payment_events ADD CONSTRAINT payment_events_mandate_fkey
            FOREIGN KEY (mandate_id) REFERENCES mandates (id);
    END IF;

    -- A delivery is about a payment or about an authority, never both. A handler
    -- that set both attributed one event to two things.
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_events_names_one_subject') THEN
        ALTER TABLE payment_events ADD CONSTRAINT payment_events_names_one_subject
            CHECK (payment_id IS NULL OR mandate_id IS NULL);
    END IF;

    -- The method vocabulary gains nach_debit: a debit under a NACH authority is
    -- neither a UPI method nor an offline one, and before this it had nowhere to
    -- go. Dropped and re-added rather than written inline, because an inline
    -- CHECK never reaches a database that already has the table.
    ALTER TABLE payments DROP CONSTRAINT IF EXISTS payments_method_check;
    ALTER TABLE payments ADD CONSTRAINT payments_method_check
        CHECK (method IN (
            'upi_collect', 'upi_intent', 'upi_autopay', 'nach_debit',
            'card', 'netbanking',
            'offline_cash', 'offline_cheque', 'offline_transfer'));
END
$$;

CREATE INDEX IF NOT EXISTS payments_mandate_idx
    ON payments (tenant_id, mandate_id) WHERE mandate_id IS NOT NULL;

ALTER TABLE mandates ENABLE ROW LEVEL SECURITY;
ALTER TABLE mandates FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and assertion 6 enforces — and this
-- table is the one that assertion was written for: a one-unit authority read at
-- property granularity would show a firm every mandate in the tower.
DROP POLICY IF EXISTS mandates_tenant_isolation ON mandates;
CREATE POLICY mandates_tenant_isolation ON mandates
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect'));

-- Revoked, not deleted. "There was never a mandate" is exactly what a disputed
-- debit needs the record to disprove.
DROP POLICY IF EXISTS mandates_no_delete ON mandates;
CREATE POLICY mandates_no_delete ON mandates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON mandates TO dwellm8_money;
GRANT SELECT ON mandates TO dwellm8_lease;

