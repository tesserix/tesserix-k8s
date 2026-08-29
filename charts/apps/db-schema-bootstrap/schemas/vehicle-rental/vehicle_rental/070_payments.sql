-- ===========================================================================
-- 070 payments
-- ===========================================================================

CREATE TABLE IF NOT EXISTS payments.payment_order (
    id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id         uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id        uuid REFERENCES booking.booking(id) ON DELETE RESTRICT,
    provider          text NOT NULL,
    provider_order_id text,
    amount_paise      bigint NOT NULL CHECK (amount_paise >= 0),
    currency          char(3) NOT NULL DEFAULT 'INR',
    state             text NOT NULL DEFAULT 'created'
                      CHECK (state IN ('created','attempted','paid','failed','expired')),
    idempotency_key   text NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, idempotency_key)
);

CREATE TABLE IF NOT EXISTS payments.payment (
    id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id           uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    order_id            uuid NOT NULL REFERENCES payments.payment_order(id) ON DELETE RESTRICT,
    provider            text NOT NULL,
    provider_payment_id text NOT NULL,
    method              text,
    amount_paise        bigint NOT NULL CHECK (amount_paise >= 0),
    fee_paise           bigint NOT NULL DEFAULT 0,
    currency            char(3) NOT NULL DEFAULT 'INR',
    state               text NOT NULL DEFAULT 'pending'
                        CHECK (state IN ('pending','captured','failed','refunded','partially_refunded')),
    captured_at         timestamptz,
    -- The idempotency anchor for webhook replay. A PSP will deliver the same
    -- event more than once, and this is what makes that harmless.
    UNIQUE (provider, provider_payment_id)
);

CREATE TABLE IF NOT EXISTS payments.refund (
    id                 uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id          uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    payment_id         uuid NOT NULL REFERENCES payments.payment(id) ON DELETE RESTRICT,
    amount_paise       bigint NOT NULL CHECK (amount_paise > 0),
    reason             text,
    state              text NOT NULL DEFAULT 'pending'
                       CHECK (state IN ('pending','processed','failed')),
    provider_refund_id text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    UNIQUE (provider_refund_id)
);

CREATE TABLE IF NOT EXISTS payments.deposit (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id      uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    booking_id     uuid NOT NULL REFERENCES booking.booking(id) ON DELETE RESTRICT,
    method         text NOT NULL CHECK (method IN ('card_hold','upi_mandate','cash','bank_transfer')),
    amount_paise   bigint NOT NULL CHECK (amount_paise >= 0),
    state          text NOT NULL DEFAULT 'held'
                   CHECK (state IN ('held','applied','released','forfeited')),
    applied_paise  bigint NOT NULL DEFAULT 0 CHECK (applied_paise >= 0),
    released_at    timestamptz,
    forfeit_reason text,
    CHECK (applied_paise <= amount_paise)
);

-- Per-tenant fee history, with an effective date. identity.tenant.fee_bps is a
-- cache of the current row; this is where the number came from.
CREATE TABLE IF NOT EXISTS payments.fee_schedule (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id      uuid REFERENCES identity.tenant(id) ON DELETE CASCADE,
    fee_bps        int NOT NULL CHECK (fee_bps BETWEEN 0 AND 10000),
    effective_from timestamptz NOT NULL DEFAULT now(),
    created_by     uuid,
    created_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payments.payout (
    id                 uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id          uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    period             tstzrange NOT NULL,
    gross_paise        bigint NOT NULL DEFAULT 0,
    platform_fee_paise bigint NOT NULL DEFAULT 0,
    psp_fee_paise      bigint NOT NULL DEFAULT 0,
    adjustments_paise  bigint NOT NULL DEFAULT 0,
    net_paise          bigint NOT NULL DEFAULT 0,
    state              text NOT NULL DEFAULT 'pending'
                       CHECK (state IN ('pending','processing','settled','failed')),
    provider_payout_id text,
    settled_at         timestamptz,
    UNIQUE (tenant_id, period)
);

CREATE TABLE IF NOT EXISTS payments.invoice (
    id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id  uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    kind       text NOT NULL CHECK (kind IN ('rental','platform_fee','credit_note')),
    number     text NOT NULL,
    party      jsonb NOT NULL,
    lines      jsonb NOT NULL,
    totals     jsonb NOT NULL,
    gst        jsonb NOT NULL DEFAULT '{}'::jsonb,
    object_key text,
    issued_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, kind, number)
);

-- Partitioned monthly, like audit. Immutable once written: 900 revokes UPDATE
-- and DELETE from every application role.
CREATE TABLE IF NOT EXISTS payments.ledger_entry (
    id           uuid NOT NULL DEFAULT uuid_generate_v7(),
    tenant_id    uuid NOT NULL,
    booking_id   uuid,
    account      text NOT NULL,
    direction    text NOT NULL CHECK (direction IN ('debit','credit')),
    amount_paise bigint NOT NULL CHECK (amount_paise > 0),
    currency     char(3) NOT NULL DEFAULT 'INR',
    reference    text,
    at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (id, at)
) PARTITION BY RANGE (at);

DO $$
DECLARE
    m date := date_trunc('month', now())::date;
    i int;
BEGIN
    FOR i IN -1..12 LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS payments.ledger_entry_%s PARTITION OF payments.ledger_entry
               FOR VALUES FROM (%L) TO (%L)',
            to_char(m + (i || ' month')::interval, 'YYYY_MM'),
            (m + (i || ' month')::interval)::date,
            (m + ((i + 1) || ' month')::interval)::date);
    END LOOP;
END
$$;

CREATE INDEX IF NOT EXISTS ledger_entry_tenant_at_idx
    ON payments.ledger_entry (tenant_id, at DESC);

-- The 8-year statutory retention set, with no PII columns. It exists so a DPDP
-- erasure request can remove a customer's identity without destroying the
-- ledger. That separation has to be in the schema from day one; retrofitting it
-- means rewriting every financial row.
CREATE TABLE IF NOT EXISTS financial_archive.record (
    id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id     uuid NOT NULL,
    fiscal_year   int NOT NULL,
    kind          text NOT NULL,
    booking_ref   text,
    amount_paise  bigint NOT NULL,
    tax_paise     bigint NOT NULL DEFAULT 0,
    currency      char(3) NOT NULL DEFAULT 'INR',
    occurred_at   timestamptz NOT NULL,
    payload       jsonb NOT NULL
);

CREATE INDEX IF NOT EXISTS financial_archive_tenant_year_idx
    ON financial_archive.record (tenant_id, fiscal_year);
