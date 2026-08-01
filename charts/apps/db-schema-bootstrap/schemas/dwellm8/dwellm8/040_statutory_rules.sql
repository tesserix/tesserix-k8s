-- ===========================================================================
-- statutory rules — rates, slabs and thresholds (ADR-0023)
-- ===========================================================================

-- Every statutory parameter this product computes with is a row here, effective
-- dated per ADR-0008 and scoped to a jurisdiction. Not a constant in a service:
-- GST rates move with a Council notification, TDS thresholds with a Budget, and
-- deposit caps with a state amendment, and a hardcoded one is wrong silently.
--
-- Reference data, like the chart of accounts above and for the same reasons: no
-- tenant_id, no row-level security, and no runtime writer. A tenant does not get
-- a private idea of the TDS rate, and a request cannot invent one — INSERT,
-- UPDATE and DELETE are revoked from dwellm8_app below, so this file is the only
-- author and a rate change is a reviewed commit.
--
-- The governance columns are the ones docs/india-property-compliance.md §1.1
-- specifies, and two of them interact: an unverified row may never carry
-- enforcement = 'block', because a cap enforced from a blog post is worse than no
-- cap — it is wrong with authority. That is a CHECK here rather than a review
-- rule.

CREATE TABLE IF NOT EXISTS statutory_rules (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- What kind of number this is. A bounded list, because a rule type nobody
    -- has written a resolver for is a rule nothing reads.
    rule_type     text NOT NULL CHECK (rule_type IN (
                      'gst_rate', 'gst_exemption_amount', 'gst_registration_threshold',
                      'tds_rate', 'tds_threshold',
                      -- Surcharge and cess sit above the section rate and only on a
                      -- payment to a non-resident, so the effective rate is not the
                      -- rate any table of sections shows. ADR-0025 §3.
                      'tds_surcharge_rate', 'tds_cess_rate',
                      'deposit_cap_months', 'advance_cap_months',
                      'stamp_duty_rate', 'stamp_duty_cap_amount',
                      'registration_fee_rate', 'registration_term_trigger_months')),

    -- 'IN' is the central rule, held once. A state code is that state's override.
    -- A national rule is not replicated per state: resolution falls back from the
    -- state to 'IN' and says which it used, so twenty-eight copies of the same
    -- number cannot drift apart.
    jurisdiction  text NOT NULL CHECK (jurisdiction ~ '^(IN|[A-Z]{2})$'),

    -- The discriminator within a type: the section for TDS, the supply for GST,
    -- the instrument for stamp duty. Lower case and dotted, so it reads the same
    -- in a query, a log line and a Go constant.
    rule_key      text NOT NULL CHECK (rule_key ~ '^[a-z0-9_]+(\.[a-z0-9_]+)*$'),

    -- Which column carries the value. Four shapes rather than one polymorphic
    -- column: a rate and an amount are not interchangeable, and a schema that
    -- stores both as numeric is one cast away from charging 18 paise of GST.
    value_kind    text NOT NULL CHECK (value_kind IN ('rate', 'amount', 'count', 'slabs')),
    -- Basis points, per ADR-0007's argument about share_bps: 18% is 1800, and a
    -- percentage in floating point is a percentage that does not add up.
    rate_bps      int CHECK (rate_bps IS NULL OR (rate_bps >= 0 AND rate_bps <= 1000000)),
    amount_minor  bigint CHECK (amount_minor IS NULL OR
                      (amount_minor >= 0 AND amount_minor <= 9007199254740991)),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    -- A dimensionless count: months of deposit, months of term. Not money and not
    -- a rate, and conflating it with either is how a two-month cap becomes ₹2.
    count_value   int CHECK (count_value IS NULL OR count_value >= 0),

    -- ADR-0008: half-open, dates not timestamps, and the successor's valid_from
    -- is the predecessor's valid_to exactly.
    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    retired_at    timestamptz,
    corrects      uuid REFERENCES statutory_rules(id),

    -- Governance. india-property-compliance.md §1.1: an Act, section, notification
    -- or circular — a URL is not a citation, so the URL is a separate, nullable
    -- convenience.
    statute_ref   text NOT NULL CHECK (btrim(statute_ref) <> ''),
    source_url    text,
    verification_status text NOT NULL DEFAULT 'unverified' CHECK (verification_status IN (
                      'verified', 'needs_bare_act_check', 'unverified', 'conflicting')),
    verified_by   text,
    verified_on   date,
    -- The team accountable for the row, and the date it must be looked at again.
    -- Both NOT NULL: a rule with no owner is a rule nobody reviews, and the review
    -- job below is the only thing standing between a Budget and a wrong invoice.
    owner         text NOT NULL CHECK (btrim(owner) <> ''),
    review_due    date NOT NULL,
    -- What the product does with the row. ADR-0023 §4.
    enforcement   text NOT NULL DEFAULT 'record_only'
                  CHECK (enforcement IN ('block', 'warn', 'record_only')),
    note          text,

    created_at    timestamptz NOT NULL DEFAULT now(),

    -- statutory_rules_value_shape and statutory_rules_unverified_cannot_block are
    -- not here: they are load-bearing, so they live in the migrations block at the
    -- foot of this file, which reaches a database that already has the table.
    --
    -- "Verified" names a human and a date, or it is a word somebody typed.
    CONSTRAINT statutory_rules_verification_shape CHECK (
        verification_status <> 'verified'
        OR (btrim(coalesce(verified_by, '')) <> '' AND verified_on IS NOT NULL)),
    CONSTRAINT statutory_rules_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT statutory_rules_correction_shape CHECK (corrects IS NULL OR corrects <> id),
    -- A row that is due for review before it takes effect is a row somebody
    -- back-dated and forgot.
    CONSTRAINT statutory_rules_review_after_effect CHECK (review_due >= valid_from)
);

COMMENT ON TABLE statutory_rules IS
    'ADR-0023. Statutory rates, slabs and thresholds, effective-dated and jurisdiction-scoped. Reference data: no tenant, no runtime writer, and a rate change is a new row.';
COMMENT ON COLUMN statutory_rules.jurisdiction IS
    'IN for the central rule, held once; a state code overrides it. Resolution falls back state → IN and records which it used.';
COMMENT ON COLUMN statutory_rules.enforcement IS
    'block | warn | record_only. An unverified row may never block: a cap enforced from a blog post is wrong with authority.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'statutory_rules_no_overlap') THEN
        -- One rule in force at a time, per type per jurisdiction per key. This is
        -- what makes an as-of resolution single-valued, and it is a constraint
        -- rather than a trigger for ADR-0008's reason: a trigger reads the table it
        -- protects, so two people landing a Budget change concurrently would both
        -- pass.
        ALTER TABLE statutory_rules ADD CONSTRAINT statutory_rules_no_overlap
            EXCLUDE USING gist (rule_type WITH =, jurisdiction WITH =, rule_key WITH =,
                                validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

-- The seed's conflict target, and the reason a replay cannot silently change a
-- number: the natural key includes valid_from, so an amended rate is a new row or
-- it is nothing.
CREATE UNIQUE INDEX IF NOT EXISTS statutory_rules_natural_key
    ON statutory_rules (rule_type, jurisdiction, rule_key, valid_from)
    WHERE retired_at IS NULL;

-- The as-of query: type, jurisdiction, key, containing a date.
CREATE INDEX IF NOT EXISTS statutory_rules_asof_idx
    ON statutory_rules USING gist (rule_type, jurisdiction, rule_key, validity)
    WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS statutory_rules_review_idx
    ON statutory_rules (review_due) WHERE retired_at IS NULL;

-- A progressive scale: stamp duty by consideration, a fee capped at a ceiling.
-- A child table rather than JSON, so every money bound is a bigint of minor units
-- that assertion 8 can see, and so a band is addressable by a query.
CREATE TABLE IF NOT EXISTS statutory_rule_slabs (
    rule_id       uuid NOT NULL REFERENCES statutory_rules(id) ON DELETE CASCADE,
    seq           int  NOT NULL CHECK (seq >= 0),
    -- Half-open in the same sense as validity: [lower, upper), upper NULL meaning
    -- the top band. The same convention as dates, for the same reason — nobody
    -- computes "one paisa below the next band".
    lower_minor   bigint NOT NULL CHECK (lower_minor >= 0),
    upper_minor   bigint,
    rate_bps      int CHECK (rate_bps IS NULL OR (rate_bps >= 0 AND rate_bps <= 1000000)),
    flat_minor    bigint CHECK (flat_minor IS NULL OR flat_minor >= 0),
    PRIMARY KEY (rule_id, seq),
    CONSTRAINT statutory_rule_slabs_band CHECK (upper_minor IS NULL OR upper_minor > lower_minor),
    -- A band with neither a rate nor a flat amount charges nothing and reads like
    -- an exemption somebody meant to write.
    CONSTRAINT statutory_rule_slabs_has_a_value CHECK (rate_bps IS NOT NULL OR flat_minor IS NOT NULL)
);

COMMENT ON TABLE statutory_rule_slabs IS
    'ADR-0023 §3. The bands of a slabs-kind rule, half-open on [lower, upper) with a NULL upper for the top band.';

-- The shape of a slabs rule, checked at commit because the bands are written
-- after the header. Two failures, and the second is the one that would not be
-- noticed: a scale with a hole in it resolves to no band for an amount that falls
-- in the hole, months after somebody added a band and mistyped a bound.
CREATE OR REPLACE FUNCTION statutory_rule_slab_shape() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    bands int;
    prev  bigint;
    band  record;
BEGIN
    SELECT count(*) INTO bands FROM statutory_rule_slabs WHERE rule_id = NEW.id;

    IF NEW.value_kind <> 'slabs' THEN
        IF bands > 0 THEN
            RAISE EXCEPTION 'statutory rule % is a % and carries % slab band(s): only a slabs rule has bands',
                NEW.id, NEW.value_kind, bands USING ERRCODE = 'check_violation';
        END IF;
        RETURN NULL;
    END IF;

    IF bands = 0 THEN
        RAISE EXCEPTION 'statutory rule % is a slabs rule with no bands: it resolves to nothing for every amount',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;

    prev := 0;
    FOR band IN SELECT lower_minor, upper_minor FROM statutory_rule_slabs
                 WHERE rule_id = NEW.id ORDER BY lower_minor
    LOOP
        IF band.lower_minor <> prev THEN
            RAISE EXCEPTION 'statutory rule % has a gap or an overlap at %: the bands must cover [0, ) without one',
                NEW.id, band.lower_minor USING ERRCODE = 'check_violation';
        END IF;
        IF band.upper_minor IS NULL THEN
            prev := NULL;
            EXIT;
        END IF;
        prev := band.upper_minor;
    END LOOP;

    IF prev IS NOT NULL THEN
        RAISE EXCEPTION 'statutory rule % has no top band: an amount above % resolves to nothing',
            NEW.id, prev USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION statutory_rule_slab_shape() IS
    'ADR-0023 §3. A slabs rule covers [0, ) with no gap and a top band, checked at commit because the bands follow the header.';

DROP TRIGGER IF EXISTS statutory_rules_slabs_shape ON statutory_rules;
CREATE CONSTRAINT TRIGGER statutory_rules_slabs_shape
    AFTER INSERT OR UPDATE ON statutory_rules
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION statutory_rule_slab_shape();

-- What is due for review, derived. ADR-0023 §5: a stored "overdue" flag needs a
-- job to maintain it, and a rule that should be flagged and is not is exactly the
-- silence this whole table exists to break. Same argument as lease_expiring.
--
-- security_invoker, as assertion 10 requires of every view here.
CREATE OR REPLACE VIEW statutory_rules_review_due
    WITH (security_invoker = true) AS
    SELECT r.id,
           r.rule_type,
           r.jurisdiction,
           r.rule_key,
           r.owner,
           r.review_due,
           r.verification_status,
           r.enforcement,
           (current_date - r.review_due)     AS days_overdue,
           r.valid_from,
           r.valid_to,
           r.statute_ref
      FROM statutory_rules r
     WHERE r.retired_at IS NULL
       -- Only rules that still apply. A superseded row's review date is history.
       AND (r.valid_to IS NULL OR r.valid_to > current_date)
       AND r.review_due <= current_date + 30;

COMMENT ON VIEW statutory_rules_review_due IS
    'ADR-0023 §5. Live rules at or within 30 days of their review date, with days_overdue negative while the review is still ahead.';

-- The seed. Every row cites a statute, names an owner and carries a review date,
-- and none of them is authoritative until a practising CA has signed it off —
-- which is what verification_status says out loud.
--
-- ON CONFLICT updates the governance columns only. A replay may correct a
-- citation, an owner or a review date; it may never change a number, because a
-- number that changed is a new row with a new valid_from and a computation from
-- last March must still reproduce. A seeded value that is simply wrong is fixed
-- the way ADR-0008 fixes a wrong row: a correction that retires it.
INSERT INTO statutory_rules (
    rule_type, jurisdiction, rule_key, value_kind, rate_bps, amount_minor, count_value,
    valid_from, valid_to, statute_ref, verification_status, owner, review_due,
    enforcement, note) VALUES

  -- GST. The residential exemption and the reverse charge that narrowed it.
  ('gst_rate', 'IN', 'gst.residential_let_to_unregistered', 'rate', 0, NULL, NULL,
   DATE '2022-07-18', NULL,
   'Notification 12/2017-Central Tax (Rate), entry 12, as amended by 04/2022-CT(R)',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Renting a residential dwelling for use as a residence, to an unregistered person'),
  ('gst_rate', 'IN', 'gst.residential_let_to_registered_rcm', 'rate', 1800, NULL, NULL,
   DATE '2022-07-18', NULL,
   'Notification 05/2022-Central Tax (Rate), w.e.f. 18 July 2022',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Reverse charge on the registered recipient. The tax is the recipient''s to pay, which is why the document differs'),
  ('gst_rate', 'IN', 'gst.property_management_service_fee', 'rate', 1800, NULL, NULL,
   DATE '2017-07-01', NULL,
   'Notification 11/2017-Central Tax (Rate), SAC 9972',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Dwellm8''s own fee, and a managing agent''s'),
  ('gst_exemption_amount', 'IN', 'gst.rwa_maintenance_per_member_month', 'amount', NULL, 750000, NULL,
   DATE '2018-01-25', NULL,
   'Notification 12/2017-Central Tax (Rate), entry 77(c), as amended by 02/2018-CT(R)',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Per member per month. A member owning two flats is the classic implementation error — see india-compliance.md §4'),
  ('gst_registration_threshold', 'IN', 'gst.aggregate_turnover_services', 'amount', NULL, 200000000, NULL,
   DATE '2017-07-01', NULL,
   'Section 22, CGST Act 2017',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Twenty lakh of aggregate turnover in services'),
  -- And the special-category states, which is the case the jurisdiction column
  -- exists for: one central row, four overrides, no copies of the other twenty-four.
  ('gst_registration_threshold', 'MN', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'MZ', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'NL', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('gst_registration_threshold', 'TR', 'gst.aggregate_turnover_services', 'amount', NULL, 100000000, NULL,
   DATE '2017-07-01', NULL, 'Section 22(1) proviso, CGST Act 2017 — special category state',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),

  -- TDS. Two of these are pairs, and the pairs are the point: the old row stays
  -- exactly as it was, so a recomputation of an old deduction still reproduces.
  --
  -- There is no section 195 rate here and that absence is deliberate (ADR-0024 §5):
  -- the rate on a payment to a non-resident is the Act's or a treaty's, read with
  -- that landlord's tax residency certificate, and there is no single number to
  -- hold. The matrix still selects section 195 and still says the tenant carries it;
  -- what it will not do is compute a deduction against a number nobody chose.
  ('tds_rate', 'IN', 'tds.194i_land_and_building', 'rate', 1000, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-I(b), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'History before 1 April 2020 is not modelled: nothing in this product computes a period earlier than that'),
  ('tds_threshold', 'IN', 'tds.194i_annual', 'amount', NULL, 24000000, NULL,
   DATE '2020-04-01', DATE '2025-04-01',
   'Section 194-I proviso, Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Two lakh forty thousand a year, until the Finance Act 2025 raised it'),
  ('tds_threshold', 'IN', 'tds.194i_annual', 'amount', NULL, 60000000, NULL,
   DATE '2025-04-01', NULL,
   'Section 194-I proviso, as amended by the Finance Act 2025',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Six lakh a year, w.e.f. 1 April 2025'),
  ('tds_rate', 'IN', 'tds.194ib_individual_huf', 'rate', 500, NULL, NULL,
   DATE '2020-04-01', DATE '2024-10-01',
   'Section 194-IB(1), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Five per cent, until the Finance (No. 2) Act 2024 cut it'),
  ('tds_rate', 'IN', 'tds.194ib_individual_huf', 'rate', 200, NULL, NULL,
   DATE '2024-10-01', NULL,
   'Section 194-IB(1), as amended by the Finance (No. 2) Act 2024, w.e.f. 1 October 2024',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('tds_threshold', 'IN', 'tds.194ib_monthly', 'amount', NULL, 5000000, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IB(1), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Fifty thousand a month. Individual and HUF deductors not liable to tax audit'),
  -- The two statutory floors that raise a rate for something true of the payee
  -- rather than of the payment. ADR-0025 §2.
  --
  -- §206AB is the effective-dating case that could not be invented: it was
  -- inserted in 2021 and *omitted* by the Finance (No. 2) Act 2024 with effect
  -- from 1 October 2024. The row is bounded rather than deleted, so a deduction
  -- recomputed for August 2024 still sees the floor that applied to it.
  ('tds_rate', 'IN', 'tds.206aa_no_pan_floor', 'rate', 2000, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 206AA(1)(iii), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Twenty per cent, or the rate in force if higher. Rule 37BC exempts a non-resident who furnishes TRC, TIN and contact details'),
  ('tds_rate', 'IN', 'tds.206ab_non_filer_floor', 'rate', 500, NULL, NULL,
   DATE '2021-07-01', DATE '2024-10-01',
   'Section 206AB(1)(iii), Income-tax Act 1961, omitted by the Finance (No. 2) Act 2024 w.e.f. 1 October 2024',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Five per cent, or twice the rate in force if higher. The section no longer exists; the row is bounded so August 2024 still resolves it'),

  -- Surcharge and cess. Only on a payment to a non-resident: for a resident,
  -- TDS other than on salary is deducted at the section rate flat.
  ('tds_cess_rate', 'IN', 'tds.cess.health_and_education', 'rate', 400, NULL, NULL,
   DATE '2018-04-01', NULL,
   'Finance Act 2018, health and education cess at 4%',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'On tax plus surcharge, and only for a non-resident payee'),

  ('tds_rate', 'IN', 'tds.194ia_immovable_transfer', 'rate', 100, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IA, Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'record_only',
   'Sale consideration, not rent. Here because india-property-compliance.md §7 puts conveyancing in scope'),
  ('tds_threshold', 'IN', 'tds.194ia_consideration', 'amount', NULL, 500000000, NULL,
   DATE '2020-04-01', NULL,
   'Section 194-IA(2), Income-tax Act 1961',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'record_only',
   'Fifty lakh'),

  -- Registration, and the deposit caps, which are the state-scoped case in full.
  ('registration_term_trigger_months', 'IN', 'registration.lease_term_trigger', 'count', NULL, NULL, 12,
   DATE '2020-04-01', NULL,
   'Section 17(1)(d), Registration Act 1908',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'A term of twelve months or more attracts compulsory registration. States vary — see e-stamping-by-state.md'),
  -- Deliberately no 'IN' row for the deposit cap. The Model Tenancy Act is a model
  -- adopted state by state, not central law, so a national row would assert a cap
  -- that binds nobody — and resolution failing loudly for an unlisted state is the
  -- correct answer, not a fallback to two months.
  ('deposit_cap_months', 'MH', 'deposit.residential', 'count', NULL, NULL, 2,
   DATE '2020-04-01', NULL,
   'Maharashtra Rent Control Act 1999, s.56',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('deposit_cap_months', 'MH', 'deposit.non_residential', 'count', NULL, NULL, 6,
   DATE '2020-04-01', NULL,
   'Maharashtra Rent Control Act 1999, s.56',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL),
  ('deposit_cap_months', 'KA', 'deposit.residential', 'count', NULL, NULL, 10,
   DATE '2020-04-01', DATE '2026-01-01',
   'Karnataka Rent Act 2001',
   'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
   'Bengaluru''s ten months, lawful and normal in practice — see india-compliance.md §2'),
  ('deposit_cap_months', 'KA', 'deposit.residential', 'count', NULL, NULL, 2,
   DATE '2026-01-01', NULL,
   'Karnataka Rent (Amendment) Act 2025',
   'unverified', 'compliance', DATE '2026-10-31', 'record_only',
   'Secondary sources only. Unverified, so it may not block — the CHECK enforces that, not a review'),
  ('deposit_cap_months', 'TN', 'deposit.residential', 'count', NULL, NULL, 3,
   DATE '2020-04-01', NULL,
   'Tamil Nadu Regulation of Rights and Responsibilities of Landlords and Tenants Act 2017',
   'conflicting', 'compliance', DATE '2026-10-31', 'record_only',
   'Sources disagree between one month and three. Resolve against the bare act before this gates anything'),

  -- Stamp duty on a lease, per e-stamping-by-state.md §state matrix (#210). The
  -- statuses are the honest ones from that document: two states carry the
  -- flat-vs-ad-valorem conflict, the rest are secondary-source figures. None may
  -- block — the unverified-cannot-block CHECK holds that, not this comment. The
  -- computation over these rates (MH's consideration formula and friends) is
  -- #60's expression engine, out of scope here.
  ('stamp_duty_rate', 'MH', 'lease.leave_licence', 'rate', 25, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Maharashtra Stamp Act 1958, Sch. I Art. 36A',
   'unverified', 'compliance', DATE '2026-09-30', 'record_only',
   '0.25% of a defined consideration; the formula (rent + non-refundable deposit + 10%/yr of refundable) is the unverified part'),
  ('stamp_duty_rate', 'KA', 'lease.rent_agreement', 'rate', 100, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Karnataka Stamp Act 1957, Sch. Art. 30',
   'conflicting', 'compliance', DATE '2026-09-30', 'record_only',
   'Statutory ~1% of average annual rent vs the flat-Rs.200 market practice for 11-month agreements — resolve against the Schedule before launch'),
  ('stamp_duty_rate', 'DL', 'lease.rent_agreement', 'rate', 200, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Indian Stamp Act 1899, Sch. I-A Art. 35 (NCT of Delhi)',
   'conflicting', 'compliance', DATE '2026-09-30', 'record_only',
   '2% of average annual rent for terms to five years vs the flat-Rs.100 market practice — the same flat-vs-ad-valorem split as Karnataka'),
  ('stamp_duty_rate', 'TG', 'lease.rent_agreement', 'rate', 40, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Indian Stamp Act 1899 as applied in Telangana, Sch. I-A',
   'unverified', 'compliance', DATE '2026-09-30', 'record_only',
   '~0.4% of rent plus advance'),
  ('stamp_duty_rate', 'GJ', 'lease.rent_agreement', 'rate', 100, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Gujarat Stamp Act 1958, Sch. I',
   'unverified', 'compliance', DATE '2026-09-30', 'record_only',
   '~1% of rent times months plus deposit'),
  ('stamp_duty_rate', 'TN', 'lease.rent_agreement', 'rate', 100, NULL, NULL,
   DATE '2020-04-01', NULL,
   'Indian Stamp Act 1899 as applied in Tamil Nadu, Sch. I Art. 35',
   'unverified', 'compliance', DATE '2026-09-30', 'record_only',
   '~1% of average annual rent per year of term; the registration fee is a separate row when #60 needs it')

ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
DO UPDATE SET statute_ref = EXCLUDED.statute_ref,
              source_url = EXCLUDED.source_url,
              verification_status = EXCLUDED.verification_status,
              verified_by = EXCLUDED.verified_by,
              verified_on = EXCLUDED.verified_on,
              owner = EXCLUDED.owner,
              review_due = EXCLUDED.review_due,
              enforcement = EXCLUDED.enforcement,
              note = EXCLUDED.note;

-- The surcharge scales, which are the first slabs rules in the registry.
--
-- Written separately because the bands are children: the header goes in with
-- value_kind = 'slabs' and the deferred shape trigger checks at commit that the
-- bands cover [0, ) with a top band. The bottom band is nil — a surcharge scale
-- begins with a threshold below which there is no surcharge, and that band is a
-- zero rate rather than a missing row, so a payment under fifty lakh resolves to
-- "nil" instead of to nothing.
--
-- Two scales because the payee's own form decides them: a non-resident individual
-- and a foreign company are on different ladders. ADR-0025 §3.
DO $$
DECLARE
    individual uuid;
    company    uuid;
BEGIN
    INSERT INTO statutory_rules (
        rule_type, jurisdiction, rule_key, value_kind,
        valid_from, valid_to, statute_ref, verification_status, owner, review_due,
        enforcement, note) VALUES
      ('tds_surcharge_rate', 'IN', 'tds.surcharge.non_resident_individual', 'slabs',
       DATE '2023-04-01', NULL,
       'Finance Act, First Schedule, Part II — rates for deduction at source from a non-resident',
       'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn',
       'Whether the 37% band survives section 115BAC for a non-resident is exactly the kind of question this row may not answer for itself')
    ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
    DO UPDATE SET note = EXCLUDED.note
    RETURNING id INTO individual;

    INSERT INTO statutory_rules (
        rule_type, jurisdiction, rule_key, value_kind,
        valid_from, valid_to, statute_ref, verification_status, owner, review_due,
        enforcement, note) VALUES
      ('tds_surcharge_rate', 'IN', 'tds.surcharge.foreign_company', 'slabs',
       DATE '2023-04-01', NULL,
       'Finance Act, First Schedule, Part II — rates for deduction at source from a foreign company',
       'needs_bare_act_check', 'compliance', DATE '2026-10-31', 'warn', NULL)
    ON CONFLICT (rule_type, jurisdiction, rule_key, valid_from) WHERE retired_at IS NULL
    DO UPDATE SET note = EXCLUDED.note
    RETURNING id INTO company;

    -- Fifty lakh, one crore, two crore, five crore, in paise.
    INSERT INTO statutory_rule_slabs (rule_id, seq, lower_minor, upper_minor, rate_bps) VALUES
      (individual, 0,          0,   500000000,    0),
      (individual, 1,  500000000,  1000000000, 1000),
      (individual, 2, 1000000000,  2000000000, 1500),
      (individual, 3, 2000000000,  5000000000, 2500),
      (individual, 4, 5000000000,        NULL, 3700),
      (company,    0,          0,  1000000000,    0),
      (company,    1, 1000000000, 10000000000,  200),
      (company,    2, 10000000000,       NULL,  500)
    ON CONFLICT (rule_id, seq) DO UPDATE
        SET lower_minor = EXCLUDED.lower_minor,
            upper_minor = EXCLUDED.upper_minor,
            rate_bps    = EXCLUDED.rate_bps;
END
$$;

-- Reference data, so every module reads it: the lease builder needs the deposit
-- cap, money needs the GST rate and the TDS threshold, and notify needs neither
-- but reads the review view.
GRANT SELECT ON statutory_rules, statutory_rule_slabs, statutory_rules_review_due
    TO dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
       dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

