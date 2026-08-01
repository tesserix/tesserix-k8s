-- ===========================================================================
-- payments — the provider-facing side of collection (ADR-0011)
-- ===========================================================================

-- A payment is the canonical record of an attempt to collect money. It is not
-- the ledger: the ledger records what is true about the money, and this records
-- what a provider has been asked to do and what it has said back.
--
-- The two are joined by entry_id, and only when the payment reaches a state that
-- justifies a posting. Everything before that — an order created, an attempt
-- made, an authorisation held — is real and is not money yet.
CREATE TABLE IF NOT EXISTS payments (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    -- Where the money is (ADR-0009). property_id is NOT NULL here, unlike
    -- ledger_postings: every collection is against something a tenant occupies,
    -- and there is no organisation-level collection the way there is an
    -- organisation-level GST remittance. That lets the delegated branch of the
    -- policy be unconditional.
    property_id     uuid NOT NULL,
    unit_id         uuid,
    unit_parent_id  uuid,

    payer_kind      text NOT NULL DEFAULT 'tenant' CHECK (payer_kind IN ('tenant', 'owner')),
    payer_id        uuid NOT NULL,

    amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The canonical method vocabulary. Offline is a first-class method, not an
    -- absence of one: when the provider is down the tenant still pays, and the
    -- alternative to recording it is a caretaker's notebook.
    method          text NOT NULL CHECK (method IN (
                        'upi_collect', 'upi_intent', 'upi_autopay',
                        'card', 'netbanking',
                        'offline_cash', 'offline_cheque', 'offline_transfer')),

    -- 'razorpay', or 'offline' for something recorded by a human. The adapter
    -- name, never a provider-specific column.
    provider        text NOT NULL,
    provider_order_id   text,
    provider_payment_id text,

    status          text NOT NULL DEFAULT 'created' CHECK (status IN (
                        'created', 'attempted', 'authorised', 'captured',
                        'settled', 'failed', 'expired', 'cancelled')),
    failure_code    text,

    -- ADR-0011 §2. The caller's key, unique per organisation. This index is the
    -- whole of the idempotency guarantee: three retries of the same request
    -- produce one row because the second and third lose a race against a unique
    -- constraint, not because a handler remembered to check.
    idempotency_key text NOT NULL,

    -- The ledger entry this payment caused, once it caused one. NULL until then.
    entry_id        uuid,

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    authorised_at   timestamptz,
    captured_at     timestamptz,
    settled_at      timestamptz,

    CONSTRAINT payments_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT payments_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT payments_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT payments_entry_fkey FOREIGN KEY (entry_id, tenant_id)
        REFERENCES journal_entries (id, tenant_id),
    CONSTRAINT payments_amount_representable CHECK (amount_minor <= 9007199254740991),
    -- payments_captured_has_entry — a captured payment that posted nothing is money
    -- the ledger does not know about — is added in the "load-bearing rules" block
    -- below rather than here. Not a style choice: a CHECK in this position never
    -- reaches a database that already has the table, and this is one of the rules
    -- assertion 13 refuses to boot without.
    CONSTRAINT payments_amount_positive CHECK (amount_minor > 0)
);

COMMENT ON TABLE payments IS
    'ADR-0011. What a provider was asked to do and what it said back. The ledger is what is true about the money; this is not the ledger.';

CREATE UNIQUE INDEX IF NOT EXISTS payments_idempotency_idx
    ON payments (tenant_id, idempotency_key);
-- The provider's own id, once it has issued one. Unique across the provider so
-- a webhook naming a payment can find exactly one row, or none.
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_payment_idx
    ON payments (provider, provider_payment_id) WHERE provider_payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_order_idx
    ON payments (provider, provider_order_id) WHERE provider_order_id IS NOT NULL;
-- "What is outstanding on this unit", and "what has not reached a terminal
-- state", which is the reconciliation sweep's question.
CREATE INDEX IF NOT EXISTS payments_unit_idx
    ON payments (tenant_id, unit_id, status) WHERE unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS payments_open_idx
    ON payments (tenant_id, created_at)
    WHERE status IN ('created', 'attempted', 'authorised');

-- The transition table, ADR-0011 §3. The same set exists in Go, and the contract
-- test evaluates this function over every ordered pair of statuses and fails if
-- the two disagree — a state machine that exists twice is a state machine that
-- will differ once.
--
-- from = to is allowed and is the point: a webhook delivered five times applies
-- once and is a no-op four times, with no branch anywhere that has to count
-- deliveries.
CREATE OR REPLACE FUNCTION payment_transition_allowed(from_status text, to_status text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_status = to_status
        OR (from_status, to_status) IN (
            ('created',    'attempted'),
            ('created',    'failed'),
            ('created',    'expired'),
            ('created',    'cancelled'),
            ('attempted',  'authorised'),
            ('attempted',  'captured'),
            ('attempted',  'failed'),
            ('attempted',  'expired'),
            -- An authorisation that is never captured is released, not failed by
            -- the passage of time; both endings exist because the provider
            -- reports them differently and an owner asking "why did this not
            -- collect" needs the difference.
            ('authorised', 'captured'),
            ('authorised', 'failed'),
            ('authorised', 'cancelled'),
            ('captured',   'settled'))
$$;

COMMENT ON FUNCTION payment_transition_allowed(text, text) IS
    'ADR-0011 §3. The payment state machine. Terminal states absorb, and from = to is a permitted no-op so a redelivered webhook needs no special case.';

-- Enforced in the database, not only in Go, because the failure it prevents is
-- one that arrives out of order from outside the system: a `captured` webhook
-- delivered after the `settled` one that followed it. Application code that
-- writes the state it was told would walk the payment backwards and re-open a
-- collection that had already closed.
CREATE OR REPLACE FUNCTION payments_transition_is_forward() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT payment_transition_allowed(OLD.status, NEW.status) THEN
        RAISE EXCEPTION 'payment % cannot go from % to %: a delivery that arrived late, out of order, '
                        'or skipping a state does not move a payment',
            OLD.id, OLD.status, NEW.status USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_forward_only ON payments;
CREATE TRIGGER payments_forward_only
    BEFORE UPDATE ON payments
    FOR EACH ROW EXECUTE FUNCTION payments_transition_is_forward();

-- Stamp the ancillary parent, exactly as ledger_postings does, so the policy
-- never reads units. SECURITY INVOKER for the same fail-closed reason.
CREATE OR REPLACE FUNCTION payment_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.unit_id IS NULL THEN
        NEW.unit_parent_id := NULL;
        RETURN NEW;
    END IF;
    SELECT u.parent_unit_id INTO NEW.unit_parent_id
      FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS payments_unit_parent ON payments;
CREATE TRIGGER payments_unit_parent
    BEFORE INSERT OR UPDATE OF unit_id ON payments
    FOR EACH ROW EXECUTE FUNCTION payment_unit_parent();

-- The webhook inbox. ADR-0011 §4.
--
-- Every delivery lands here first and is decided afterwards. The unique index on
-- (provider, provider_event_id) is the deduplication — the fifth delivery of an
-- event conflicts and is discarded without the handler needing to be careful.
--
-- tenant_id is NULLABLE, which is deliberate and is the "unknown payment is
-- parked, not dropped" rule made structural. A webhook for a payment this system
-- has never heard of has no organisation to attribute it to, and the choices are
-- to guess, to drop it, or to keep it where only a platform session can see it.
-- Guessing is a cross-tenant write; dropping loses money that a provider
-- believes it has collected.
CREATE TABLE IF NOT EXISTS payment_events (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id          uuid REFERENCES organisations(id),
    provider           text NOT NULL,
    provider_event_id  text NOT NULL,
    event_type         text NOT NULL,

    -- Recorded, never assumed. An unverified delivery is still stored — it is
    -- evidence of something, possibly of an attack — and is never acted on.
    signature_verified boolean NOT NULL DEFAULT false,
    payload            jsonb NOT NULL,

    payment_id         uuid REFERENCES payments(id),
    park_reason        text CHECK (park_reason IN (
                           'unknown_payment', 'signature_invalid',
                           'stale_transition', 'unsupported_event')),

    received_at        timestamptz NOT NULL DEFAULT now(),
    processed_at       timestamptz,

    -- A parked event is one that was not applied, and an applied event is one
    -- that was not parked. Both being set means the handler did two things.
    CONSTRAINT payment_events_parked_or_processed CHECK (
        park_reason IS NULL OR processed_at IS NULL),
    -- Nothing unverified may ever be attributed to a payment.
    CONSTRAINT payment_events_unverified_is_parked CHECK (
        signature_verified OR payment_id IS NULL)
);

COMMENT ON TABLE payment_events IS
    'ADR-0011 §4. Every webhook delivery, deduplicated on the provider event id. Advisory: nothing here moves money on its own.';
COMMENT ON COLUMN payment_events.tenant_id IS
    'NULL for a webhook naming a payment this system does not know. Parked where only a platform session can see it, rather than guessed at or dropped.';

CREATE UNIQUE INDEX IF NOT EXISTS payment_events_provider_event_idx
    ON payment_events (provider, provider_event_id);
-- The reconciliation sweep's question: what arrived and was never applied.
CREATE INDEX IF NOT EXISTS payment_events_parked_idx
    ON payment_events (provider, received_at) WHERE park_reason IS NOT NULL;
CREATE INDEX IF NOT EXISTS payment_events_payment_idx
    ON payment_events (payment_id) WHERE payment_id IS NOT NULL;

ALTER TABLE payments       ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments       FORCE  ROW LEVEL SECURITY;
ALTER TABLE payment_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE payment_events FORCE  ROW LEVEL SECURITY;

-- Unit granularity, as ADR-0009 §4 requires and as assertion 6 enforces. A firm
-- collecting rent on two flats must not see the collections of the tower.
DROP POLICY IF EXISTS payments_tenant_isolation ON payments;
CREATE POLICY payments_tenant_isolation ON payments
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect'));

-- A payment is mutable — it has a lifecycle, unlike a posting — but it may not
-- be deleted. A collection that was attempted and abandoned is the record an
-- owner asks about when a tenant says they paid.
DROP POLICY IF EXISTS payments_no_delete ON payments;
CREATE POLICY payments_no_delete ON payments AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The inbox is a platform-owned table, and the NULL tenant_id above is why: a
-- parked event belongs to no organisation, so no organisation's session can
-- reach it. Reading a verified, attributed event is allowed to the organisation
-- it concerns; writing is the platform's alone, because the webhook handler runs
-- before it knows whose money this is.
DROP POLICY IF EXISTS payment_events_tenant_isolation ON payment_events;
CREATE POLICY payment_events_tenant_isolation ON payment_events
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS payment_events_no_delete ON payment_events;
CREATE POLICY payment_events_no_delete ON payment_events AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON payments TO dwellm8_money;
GRANT SELECT ON payments TO dwellm8_lease, dwellm8_identity, dwellm8_property;
GRANT SELECT, INSERT, UPDATE ON payment_events TO dwellm8_money;

