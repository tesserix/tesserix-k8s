-- ===========================================================================
-- the platform fee (ADR-0031, dwellm8#234)
-- ===========================================================================

-- What Dwellm8 charges, as data rather than as a constant.
--
-- The rate is 2.99% and the product owner changes it by writing a row: no
-- deployment, and the rate that priced a payment last March is still answerable
-- in September.
--
-- Reference data, on ADR-0023's pattern and with its governance columns. No
-- row-level security and no tenant_id, which is deliberate: this is the rule
-- rather than the data, one price for the platform, and the privilege is the
-- boundary. An organisation that could INSERT here would write itself a zero
-- rate effective last April — the same argument assertion 18 makes about
-- statutory rates, which is why this table is on its list.
--
-- Per-organisation negotiated pricing is not this. It needs a tenant-scoped
-- table with row-level security and a different set of questions about who may
-- agree a discount; dwellm8#234 leaves it out.
CREATE TABLE IF NOT EXISTS platform_fee_rules (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    rate_bps      int NOT NULL CHECK (rate_bps BETWEEN 0 AND 10000),
    tax_rate_bps  int NOT NULL DEFAULT 1800 CHECK (tax_rate_bps BETWEEN 0 AND 10000),
    -- Whether rate_bps already contains the tax. Worth about fifteen per cent of
    -- revenue, so it is a stored decision with a date on it.
    tax_inclusive boolean NOT NULL DEFAULT false,

    min_fee_minor bigint NOT NULL DEFAULT 0 CHECK (min_fee_minor >= 0),
    max_fee_minor bigint CHECK (max_fee_minor IS NULL OR max_fee_minor >= min_fee_minor),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    -- ADR-0023's governance columns. A price nobody owns is a price nobody reviews.
    owner         text NOT NULL CHECK (btrim(owner) <> ''),
    review_by     date NOT NULL,
    source        text NOT NULL CHECK (btrim(source) <> ''),

    retired_at    timestamptz,
    corrects      uuid REFERENCES platform_fee_rules(id),
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT platform_fee_rules_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT platform_fee_rules_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE platform_fee_rules IS
    'ADR-0031. What Dwellm8 charges per collection, effective-dated. Reference data: read at runtime, written by this file.';

-- One price at a time. Without this a rate change that forgot to close the
-- previous row leaves two live answers and the resolver picks one.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'platform_fee_rules_no_overlap') THEN
        ALTER TABLE platform_fee_rules ADD CONSTRAINT platform_fee_rules_no_overlap
            EXCLUDE USING gist (validity WITH &&) WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS platform_fee_rules_asof_idx
    ON platform_fee_rules USING gist (validity) WHERE retired_at IS NULL;

-- The default, seeded so a collection always has a price. A fixed id so a replay
-- updates this row rather than writing a second live one the exclusion
-- constraint would then refuse.
INSERT INTO platform_fee_rules (id, rate_bps, tax_rate_bps, tax_inclusive,
                                valid_from, owner, review_by, source)
VALUES ('f0000000-0000-0000-0000-000000000001', 299, 1800, false,
        date '2026-01-01', 'Product', date '2027-01-01',
        'dwellm8#234 — 2.99% of the collection, GST charged on top')
ON CONFLICT (id) DO UPDATE
    SET rate_bps      = EXCLUDED.rate_bps,
        tax_rate_bps  = EXCLUDED.tax_rate_bps,
        tax_inclusive = EXCLUDED.tax_inclusive,
        owner         = EXCLUDED.owner,
        review_by     = EXCLUDED.review_by,
        source        = EXCLUDED.source;

GRANT SELECT ON platform_fee_rules TO dwellm8_money, dwellm8_lease, dwellm8_identity,
    dwellm8_property, dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;
