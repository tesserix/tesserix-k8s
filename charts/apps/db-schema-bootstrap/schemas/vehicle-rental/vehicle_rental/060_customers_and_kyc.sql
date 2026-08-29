-- ===========================================================================
-- 060 customers and KYC
-- ===========================================================================

-- Customers are per tenant. A rider who uses two shops is two rows. That
-- duplicates data and is the right call: a shared customer identity across
-- competing tenants is a privacy problem and a data-ownership fight.
CREATE TABLE IF NOT EXISTS kyc.customer (
    id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id      uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    phone_e164     text NOT NULL CHECK (phone_e164 ~ '^\+[1-9][0-9]{7,14}$'),
    email          citext,
    name           text NOT NULL,
    dob            date,
    address        text,
    nationality    text,
    blacklisted_at timestamptz,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, phone_e164)
);

-- number_masked only. A raw Aadhaar number is never persisted — masking happens
-- at capture, before the row exists, and the CHECK below is the backstop that
-- makes "we masked it" verifiable rather than a claim in a code review.
--
-- object_key_encrypted points at a GCS object encrypted with a per-tenant data
-- key; the key itself is never in this database.
CREATE TABLE IF NOT EXISTS kyc.customer_document (
    id                   uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
    tenant_id            uuid NOT NULL REFERENCES identity.tenant(id) ON DELETE CASCADE,
    customer_id          uuid NOT NULL REFERENCES kyc.customer(id) ON DELETE CASCADE,
    kind                 text NOT NULL CHECK (kind IN ('licence','aadhaar','passport','pan','voter_id')),
    number_masked        text CHECK (number_masked IS NULL OR number_masked ~ '[X*]'),
    verification_ref     text,
    issued_by            text,
    valid_to             date,
    licence_class        text,
    object_key_encrypted text,
    verified_at          timestamptz,
    verified_source      text CHECK (verified_source IN ('manual','digilocker','vahan','psp')),
    created_at           timestamptz NOT NULL DEFAULT now()
);

-- booking.booking.customer_id had no foreign key at all, so a request could
-- name any customer id in the estate. Composite, for the reason given on
-- reservation_vehicle_fkey: FK checks do not see RLS.
DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'customer_tenant_id_id_key'
                     AND conrelid = 'kyc.customer'::regclass) THEN
        ALTER TABLE kyc.customer
            ADD CONSTRAINT customer_tenant_id_id_key UNIQUE (tenant_id, id);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_customer_fkey'
                     AND conrelid = 'booking.booking'::regclass) THEN
        ALTER TABLE booking.booking ADD CONSTRAINT booking_customer_fkey
            FOREIGN KEY (tenant_id, customer_id)
            REFERENCES kyc.customer (tenant_id, id) ON DELETE RESTRICT;
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS customer_tenant_created_idx
    ON kyc.customer (tenant_id, created_at DESC);
CREATE INDEX IF NOT EXISTS customer_document_customer_idx
    ON kyc.customer_document (tenant_id, customer_id);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'booking_customer_fkey') THEN
        ALTER TABLE booking.booking
            ADD CONSTRAINT booking_customer_fkey
            FOREIGN KEY (customer_id) REFERENCES kyc.customer(id) ON DELETE RESTRICT;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rider_customer_fkey') THEN
        ALTER TABLE booking.rider
            ADD CONSTRAINT rider_customer_fkey
            FOREIGN KEY (customer_id) REFERENCES kyc.customer(id) ON DELETE RESTRICT;
    END IF;
END
$$;
