-- ===========================================================================
-- ledger — chart of accounts and postings
-- ===========================================================================

-- ADR-0006. Every rupee this product touches is a posting against a fixed
-- chart of accounts. No service stores a balance; a balance is a sum.
--
--   ledger_accounts        the chart. One list, platform-wide, not per tenant.
--   posting_templates      which accounts each money event touches, and on
--   posting_template_lines which side. Data, so the rule is inspectable.
--   journal_entries        one money event. Immutable once written.
--   ledger_postings        its lines. Immutable, and must sum to zero.
--
-- The engine that applies a template is out of scope here (issue #7 says so):
-- this file lands the accounts, the shape, the immutability and the balance
-- rule. internal/money/domain in the API repository computes the amounts, and
-- the deferred constraint below is what stops it being believed.

-- The chart of accounts. Deliberately not tenant-scoped: a landlord with a
-- private idea of what "deposit_liability" means is a landlord whose statements
-- cannot be compared, consolidated or audited. Tenants get their own postings,
-- never their own accounts.
--
-- normal_side is generated rather than entered. An asset with a credit normal
-- balance is not a preference, it is a typo, and every report that assumes the
-- sign would be silently backwards.
CREATE TABLE IF NOT EXISTS ledger_accounts (
    code            text PRIMARY KEY,
    name            text NOT NULL,
    account_type    text NOT NULL CHECK (account_type IN ('asset', 'liability', 'income', 'expense')),
    normal_side     text NOT NULL GENERATED ALWAYS AS
                    (CASE WHEN account_type IN ('asset', 'expense') THEN 'debit' ELSE 'credit' END) STORED,
    -- Whose balance this account is kept per. A receivable is meaningless
    -- without the tenant it is owed by; rent_income is not per anybody.
    party_kind      text NOT NULL DEFAULT 'none'
                    CHECK (party_kind IN ('none', 'tenant', 'owner', 'vendor', 'platform', 'statutory')),
    description     text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE ledger_accounts IS
    'ADR-0006. The chart of accounts, platform-wide. Not tenant-scoped, so statements are comparable.';

-- The list from issue #7, plus tenant_advance — see ADR-0006 §2 for why the
-- issue's thirteen became fourteen. ON CONFLICT DO UPDATE so a correction to a
-- name or a description reaches an existing database on the next replay; the
-- code is the identity and never changes.
INSERT INTO ledger_accounts (code, name, account_type, party_kind, description) VALUES
  ('tenant_receivable',       'Tenant receivable',        'asset',     'tenant',
   'What a tenant owes: rent, late fees and recoveries invoiced but not yet paid'),
  ('tenant_advance',          'Tenant advance',           'liability', 'tenant',
   'Money held from a tenant against a charge that does not exist yet — rent paid early, or an overpayment'),
  ('rent_income',             'Rent income',              'income',    'owner',
   'Rent earned for a period, recognised when the charge is raised rather than when it is paid'),
  ('late_fee_income',         'Late fee income',          'income',    'owner',
   'Late payment charges earned under the lease'),
  ('deposit_liability',       'Security deposit held',    'liability', 'tenant',
   'A deposit is the tenant''s money held by the owner. It is never income and never a receipt'),
  ('owner_payable',           'Owner payable',            'liability', 'owner',
   'Collected money owed onward to the owner, net of fees and outgoings, until it is disbursed'),
  ('platform_fee_income',     'Platform fee income',      'income',    'platform',
   'Dwellm8''s own fee on a collection or a payout'),
  ('gst_output',              'GST payable',              'liability', 'statutory',
   'GST charged on a taxable supply and owed to the government until remitted'),
  ('tds_receivable',          'TDS receivable',           'asset',     'statutory',
   'Tax the payer deducted at source and paid to the government on the payee''s behalf — creditable, not lost'),
  ('gateway_clearing',        'Gateway clearing',         'asset',     'platform',
   'Money the provider has taken from the payer and not yet settled to a bank account'),
  ('gateway_fee',             'Gateway fee',              'expense',   'platform',
   'What an aggregator kept out of a settlement. An expense of ours, never a smaller collection: the payer paid the gross'),
  ('gst_input',               'GST input credit',         'asset',     'statutory',
   'GST charged to us on a fee, creditable against our own output liability. A receivable from the government, not a cost'),
  ('bank',                    'Bank',                     'asset',     'platform',
   'Settled money in a real bank account'),
  ('society_dues_receivable', 'Society dues receivable',  'asset',     'tenant',
   'Maintenance and other dues a society has raised against a member and not yet collected'),
  ('sinking_fund',            'Sinking fund',             'liability', 'none',
   'A society''s corpus, held for future capital works. Not income, and not spendable as income'),
  ('write_off',               'Write-off',                'expense',   'none',
   'A receivable a decision has abandoned. An expense with a reason, never a deleted invoice')
ON CONFLICT (code) DO UPDATE
   SET name = EXCLUDED.name,
       account_type = EXCLUDED.account_type,
       party_kind = EXCLUDED.party_kind,
       description = EXCLUDED.description;

-- What each money event posts. Data rather than code, so the rule is
-- inspectable in the database a dispute is being argued against — and so the Go
-- catalogue can be checked against it instead of being trusted.
--
-- Versioned by event kind: a posting rule that changes must not rewrite the rule
-- last year's entries were made under. Nothing selects a version yet; entries
-- record which one they used.
CREATE TABLE IF NOT EXISTS posting_templates (
    event_kind      text NOT NULL,
    version         int  NOT NULL DEFAULT 1 CHECK (version > 0),
    description     text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (event_kind, version)
);

-- amount_role names which of the event's amounts a line takes: 'gross' is what
-- changes hands, 'net' the part that is income, 'tax' the GST on it, 'tds' the
-- statutory deduction, 'principal' the part of a payment that settles a debt and
-- 'advance' the part that does not. The arithmetic that turns an event into
-- amounts lives in Go (ADR-0006 §4); this says where each result lands.
CREATE TABLE IF NOT EXISTS posting_template_lines (
    event_kind      text NOT NULL,
    version         int  NOT NULL,
    seq             int  NOT NULL,
    account_code    text NOT NULL REFERENCES ledger_accounts(code),
    side            text NOT NULL CHECK (side IN ('debit', 'credit')),
    amount_role     text NOT NULL CHECK (amount_role IN
                        ('gross', 'net', 'tax', 'tds', 'advance', 'principal', 'fee')),
    -- A line that only applies when its amount is non-zero: no GST line on an
    -- exempt supply, no TDS line when the tenant is an individual below the
    -- threshold. Absence is not the same as zero, and an entry full of zero
    -- postings is noise in every statement.
    optional        boolean NOT NULL DEFAULT false,
    PRIMARY KEY (event_kind, version, seq),
    FOREIGN KEY (event_kind, version) REFERENCES posting_templates (event_kind, version) ON DELETE CASCADE
);

-- Replace rather than merge: a template is a whole rule, and a leftover line
-- from a previous shape is a posting nobody intended. DELETE then INSERT inside
-- one transaction — these tables carry no tenant data and no row-level security,
-- so unlike the migrations section this can simply run.
DO $$
BEGIN
    INSERT INTO posting_templates (event_kind, version, description) VALUES
      ('invoice',            1, 'A charge is raised: the tenant owes it, and it is income now, not when it is paid'),
      ('late_fee',           1, 'A late payment charge under the lease'),
      ('payment',            1, 'The payer''s money reaches the provider, settling a receivable and possibly leaving an advance'),
      ('payment_with_tds',   1, 'A payer who deducts tax at source pays the net and the deduction is receivable from the government'),
      ('settlement',         1, 'The provider settles collected money to a real bank account'),
      ('settlement_with_fee', 1, 'The provider settles and keeps its charge: clearing is credited the gross, the bank is debited the net'),
      ('clearing_write_off', 1, 'A clearing balance reconciliation could not account for, abandoned by a decision'),
      ('deposit_collection', 1, 'A security deposit is collected. It is a liability from the moment it arrives'),
      ('deposit_refund',     1, 'A deposit is returned, in whole or in part'),
      ('payout',             1, 'Money owed to the owner leaves the bank account'),
      ('platform_fee',       1, 'Dwellm8''s fee is charged against what the owner is owed'),
      ('gst_remittance',     1, 'GST collected is paid to the government'),
      ('refund',             1, 'Money is returned to the payer'),
      ('write_off',          1, 'A receivable is abandoned, with a reason'),
      ('reversal',           1, 'Every line of an earlier entry, on the opposite side. The only correction there is')
    ON CONFLICT (event_kind, version) DO UPDATE SET description = EXCLUDED.description;

    DELETE FROM posting_template_lines WHERE version = 1;

    INSERT INTO posting_template_lines (event_kind, version, seq, account_code, side, amount_role, optional) VALUES
      -- A charge: owed in full, income net of the tax collected on behalf of the
      -- government. The tax line is optional because rent to a residential
      -- tenant is exempt, and a zero GST posting on every invoice in the country
      -- would be the commonest row in the table.
      ('invoice',            1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('invoice',            1, 2, 'rent_income',             'credit', 'net',     false),
      ('invoice',            1, 3, 'gst_output',              'credit', 'tax',     true),

      ('late_fee',           1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('late_fee',           1, 2, 'late_fee_income',         'credit', 'net',     false),

      -- Money in. It lands in clearing, not in the bank: the provider has it,
      -- and pretending otherwise is how a reconciliation stops closing.
      -- Anything beyond what was owed becomes an advance rather than a negative
      -- receivable.
      ('payment',            1, 1, 'gateway_clearing',        'debit',  'gross',   false),
      ('payment',            1, 2, 'tenant_receivable',       'credit', 'principal', true),
      ('payment',            1, 3, 'tenant_advance',          'credit', 'advance', true),

      ('payment_with_tds',   1, 1, 'gateway_clearing',        'debit',  'net',     false),
      ('payment_with_tds',   1, 2, 'tds_receivable',          'debit',  'tds',     false),
      ('payment_with_tds',   1, 3, 'tenant_receivable',       'credit', 'gross',   false),

      ('settlement',         1, 1, 'bank',                    'debit',  'gross',   false),
      ('settlement',         1, 2, 'gateway_clearing',        'credit', 'gross',   false),

      -- The same event when the provider kept its charge. Clearing is credited
      -- the gross, because the gross is what clearing was debited when the
      -- payment was captured. Netting the fee against it balances just as well
      -- and leaves a permanent residue in the one account reconciliation is
      -- measured against — ADR-0012 §4.
      ('settlement_with_fee', 1, 1, 'bank',                   'debit',  'net',     false),
      ('settlement_with_fee', 1, 2, 'gateway_fee',            'debit',  'fee',     false),
      ('settlement_with_fee', 1, 3, 'gst_input',              'debit',  'tax',     true),
      ('settlement_with_fee', 1, 4, 'gateway_clearing',       'credit', 'gross',   false),

      ('clearing_write_off', 1, 1, 'write_off',               'debit',  'gross',   false),
      ('clearing_write_off', 1, 2, 'gateway_clearing',        'credit', 'gross',   false),

      ('deposit_collection', 1, 1, 'gateway_clearing',        'debit',  'gross',   false),
      ('deposit_collection', 1, 2, 'deposit_liability',       'credit', 'gross',   false),

      ('deposit_refund',     1, 1, 'deposit_liability',       'debit',  'gross',   false),
      ('deposit_refund',     1, 2, 'bank',                    'credit', 'gross',   false),

      ('payout',             1, 1, 'owner_payable',           'debit',  'gross',   false),
      ('payout',             1, 2, 'bank',                    'credit', 'gross',   false),

      ('platform_fee',       1, 1, 'owner_payable',           'debit',  'gross',   false),
      ('platform_fee',       1, 2, 'platform_fee_income',     'credit', 'net',     false),
      ('platform_fee',       1, 3, 'gst_output',              'credit', 'tax',     true),

      ('gst_remittance',     1, 1, 'gst_output',              'debit',  'gross',   false),
      ('gst_remittance',     1, 2, 'bank',                    'credit', 'gross',   false),

      ('refund',             1, 1, 'tenant_receivable',       'debit',  'gross',   false),
      ('refund',             1, 2, 'bank',                    'credit', 'gross',   false),

      ('write_off',          1, 1, 'write_off',               'debit',  'gross',   false),
      ('write_off',          1, 2, 'tenant_receivable',       'credit', 'gross',   false);

    -- 'reversal' has no lines on purpose: it is not a rule about accounts, it is
    -- the original entry with every side flipped. Giving it lines would invite
    -- somebody to change them.
END
$$;

-- One money event. What happened, when, and what caused it.
--
-- occurred_on is the accounting date — the day the event belongs to, which is
-- the day a statement puts it on. posted_at is when the row was written. They
-- differ for anything backdated, and a period close (issue #190) needs both.
CREATE TABLE IF NOT EXISTS journal_entries (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    entry_kind      text NOT NULL,
    template_version int NOT NULL DEFAULT 1,
    occurred_on     date NOT NULL,
    posted_at       timestamptz NOT NULL DEFAULT now(),
    -- ADR-0007 §1: one currency, and it is recorded rather than assumed. A
    -- second currency needs an FX rate with a date and a source, a rule for
    -- which currency a balance is stated in, and a per-currency minor unit —
    -- none of which has a caller. Storing the column anyway is what makes that
    -- a schema change later rather than a rewrite of every stored number.
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- What caused this entry: an invoice, a provider payment, a payout batch.
    source_kind     text NOT NULL,
    source_id       text NOT NULL,
    -- The caller's natural key for this event. A webhook delivered twice, a
    -- retried workflow activity and a double-clicked button all arrive with the
    -- same key and produce one entry. ADR-0002's idempotent consumers, spelled
    -- as a unique index rather than as a hope.
    idempotency_key text NOT NULL,

    -- A reversal names what it reverses and why. The original is never touched:
    -- the link lives on the correcting row, so an immutable table stays
    -- immutable. ADR-0006 §3.
    reverses_entry_id uuid REFERENCES journal_entries(id),
    -- Kept in step with domain.ReversalReasons() by the store contract test. Like
    -- journal_entries_kind, this clause only reaches a fresh database, so a new
    -- reason also needs the migration at the foot of this file.
    reversal_reason   text CHECK (reversal_reason IS NULL OR reversal_reason IN (
                        'duplicate', 'wrong_amount', 'wrong_account', 'wrong_party',
                        'wrong_period', 'provider_chargeback', 'operator_error',
                        'settlement_mismatch', 'workflow_compensated')),

    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    -- Who acted, when it was a firm acting under a delegation. Same shape as
    -- audit_events: the entry lands in the owner's tenant, stamped with the firm.
    actor_org_id    uuid REFERENCES organisations(id),
    grant_id        uuid REFERENCES delegation_grants(id),

    -- Kept in step with domain.EventKind by the store contract test. Note that
    -- this clause only reaches a fresh database: CREATE TABLE IF NOT EXISTS does
    -- not revisit the constraint of a table that already exists, so a new kind
    -- also needs the migration at the foot of this file. That is how
    -- 'settlement_with_fee' would otherwise have been refused in production while
    -- passing every test against a clean one.
    CONSTRAINT journal_entries_kind CHECK (entry_kind IN (
        'invoice', 'late_fee', 'payment', 'payment_with_tds', 'settlement',
        'settlement_with_fee', 'clearing_write_off',
        'deposit_collection', 'deposit_refund', 'payout', 'platform_fee',
        'gst_remittance', 'refund', 'write_off', 'reversal')),
    -- A reversal reverses something and says why; nothing else does either.
    CONSTRAINT journal_entries_reversal_shape CHECK (
        (entry_kind = 'reversal') = (reverses_entry_id IS NOT NULL)
        AND (entry_kind = 'reversal') = (reversal_reason IS NOT NULL)),
    CONSTRAINT journal_entries_no_self_reversal CHECK (reverses_entry_id <> id),
    CONSTRAINT journal_entries_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE journal_entries IS
    'ADR-0006. Immutable. A mistake is corrected by a reversing entry with a reason code, never by an update.';
COMMENT ON COLUMN journal_entries.occurred_on IS
    'The accounting date. posted_at is when the row was written; they differ for anything backdated.';

CREATE UNIQUE INDEX IF NOT EXISTS journal_entries_idempotency
    ON journal_entries (tenant_id, idempotency_key);
-- An entry is reversed once. A second reversal doubles the correction and nets
-- to the wrong side of the original, which is a defect that looks like activity.
CREATE UNIQUE INDEX IF NOT EXISTS journal_entries_one_reversal
    ON journal_entries (reverses_entry_id) WHERE reverses_entry_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS journal_entries_tenant_date_idx
    ON journal_entries (tenant_id, occurred_on DESC);
CREATE INDEX IF NOT EXISTS journal_entries_source_idx
    ON journal_entries (tenant_id, source_kind, source_id);

-- The lines. This is the only table in the product that holds an amount.
--
-- amount_minor is a positive integer of paise and the side carries the
-- direction, so there is no such thing as a negative posting: a refund is a
-- debit, not a credit of minus. signed_minor is the generated arithmetic every
-- balance sums, which keeps the sign convention in one place rather than in
-- every query that ever asks what a tenant owes.
CREATE TABLE IF NOT EXISTS ledger_postings (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id        uuid NOT NULL,
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    -- Money attributes to a place. NULL means the posting is the organisation's
    -- own — a GST remittance, a platform fee invoice — and a delegated session
    -- never sees those: see the policy below, which fails closed rather than
    -- widening to the portfolio.
    property_id     uuid,
    unit_id         uuid,
    -- Denormalised from units, stamped on insert. It is the ancillary hop from
    -- ADR-0009 §4: a firm holding flat 1204 must see the charge raised against
    -- the parking slot allotted to it. is_delegated_unit() takes the parent as
    -- an argument precisely so a policy never reads units.
    unit_parent_id  uuid,

    account_code    text NOT NULL REFERENCES ledger_accounts(code),
    side            text NOT NULL CHECK (side IN ('debit', 'credit')),
    amount_minor    bigint NOT NULL CHECK (amount_minor > 0),
    currency        char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    signed_minor    bigint NOT NULL GENERATED ALWAYS AS
                    (CASE WHEN side = 'debit' THEN amount_minor ELSE -amount_minor END) STORED,

    -- Whose balance this line moves. A receivable without a tenant cannot be
    -- chased and a payable without an owner cannot be paid.
    party_kind      text NOT NULL DEFAULT 'none'
                    CHECK (party_kind IN ('none', 'tenant', 'owner', 'vendor', 'platform', 'statutory')),
    party_id        uuid,
    memo            text,
    created_at      timestamptz NOT NULL DEFAULT now(),

    -- Composite throughout, for ADR-0009 §3's reason: a plain reference would let
    -- a row carry one organisation's tenant_id and another's property.
    CONSTRAINT ledger_postings_entry_fkey FOREIGN KEY (entry_id, tenant_id)
        REFERENCES journal_entries (id, tenant_id),
    CONSTRAINT ledger_postings_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT ledger_postings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    -- ...and the unit is in that property, not merely in that organisation.
    CONSTRAINT ledger_postings_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT ledger_postings_unit_needs_property CHECK (unit_id IS NULL OR property_id IS NOT NULL),
    CONSTRAINT ledger_postings_party CHECK ((party_kind = 'none') = (party_id IS NULL))
);

COMMENT ON TABLE ledger_postings IS
    'ADR-0006. Immutable, positive amounts, direction in `side`. Every balance in the product is a sum over this table.';
COMMENT ON COLUMN ledger_postings.signed_minor IS
    'The sign convention, once: debits positive. Balances sum this rather than re-deriving it per query.';
COMMENT ON COLUMN ledger_postings.amount_minor IS
    'ADR-0007. Paise as a positive integer, never a decimal and never a float. Bounded at 2^53-1 so the value survives a JSON round trip exactly.';

-- ADR-0007 §5. The ceiling is 2^53-1 paise, not the bigint range.
--
-- Money leaves this database as a JSON number, and JSON numbers are float64 to
-- every browser; beyond 2^53 an amount stored correctly here arrives at the
-- client as a different number with no error anywhere in between. Go refuses
-- such an amount before writing it, and this refuses it again for anything that
-- did not come through Go — psql, a fixture, a future import job.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ledger_postings_amount_representable') THEN
        -- ADD CONSTRAINT IF NOT EXISTS does not exist, and a bare ADD
        -- CONSTRAINT fails the replay on the second run.
        ALTER TABLE ledger_postings ADD CONSTRAINT ledger_postings_amount_representable
            CHECK (amount_minor <= 9007199254740991);
    END IF;
END
$$;

-- The three questions asked of this table, in the order they are asked.
CREATE INDEX IF NOT EXISTS ledger_postings_entry_idx
    ON ledger_postings (entry_id);
-- "What does this party owe, or what are they owed" — the statement query.
CREATE INDEX IF NOT EXISTS ledger_postings_party_idx
    ON ledger_postings (tenant_id, account_code, party_kind, party_id);
-- "What has happened on this unit" — the unit ledger behind a lease screen.
CREATE INDEX IF NOT EXISTS ledger_postings_unit_idx
    ON ledger_postings (tenant_id, unit_id, account_code) WHERE unit_id IS NOT NULL;

-- Double entry, enforced at commit rather than at insert.
--
-- It has to be deferred: the postings of an entry are written one statement at a
-- time, and an entry is unbalanced between the first line and the last. A NOT
-- DEFERRABLE trigger would reject every entry ever written.
--
-- The consequence is worth stating because it surprised this implementation:
-- the violation surfaces from COMMIT, not from the INSERT that caused it. Code
-- that checks the error of each Exec and ignores the error of Commit will
-- believe an unbalanced entry was written. Measured: the INSERT reports success
-- and `tx.Commit` returns 'journal entry ... does not balance: debits 2500000,
-- credits 2000000'.
CREATE OR REPLACE FUNCTION ledger_entry_balances() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    debits  bigint;
    credits bigint;
    lines   int;
BEGIN
    SELECT coalesce(sum(amount_minor) FILTER (WHERE side = 'debit'), 0),
           coalesce(sum(amount_minor) FILTER (WHERE side = 'credit'), 0),
           count(*)
      INTO debits, credits, lines
      FROM ledger_postings
     WHERE entry_id = NEW.entry_id;

    -- Zero lines means the entry's postings were rolled back around this
    -- trigger, which is not this trigger's business.
    IF lines = 0 THEN
        RETURN NULL;
    END IF;
    IF lines < 2 THEN
        RAISE EXCEPTION 'journal entry % has % posting(s): an entry with one line is a balance nobody can explain',
            NEW.entry_id, lines USING ERRCODE = 'check_violation';
    END IF;
    IF debits <> credits THEN
        RAISE EXCEPTION 'journal entry % does not balance: debits %, credits %',
            NEW.entry_id, debits, credits USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

COMMENT ON FUNCTION ledger_entry_balances() IS
    'ADR-0006 §3. Debits equal credits, per entry, checked at commit because an entry is unbalanced while it is being written.';

DROP TRIGGER IF EXISTS ledger_postings_balance ON ledger_postings;
CREATE CONSTRAINT TRIGGER ledger_postings_balance
    AFTER INSERT ON ledger_postings
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_balances();

-- The other half of the same rule, from the other end. The trigger above cannot
-- fire for an entry that has no postings at all, and an entry with no lines is a
-- money event that moved no money — a header in every statement and a total in
-- none.
CREATE OR REPLACE FUNCTION ledger_entry_has_postings() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ledger_postings WHERE entry_id = NEW.id) THEN
        RAISE EXCEPTION 'journal entry % has no postings: an entry that moves nothing is a header nobody can total',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS journal_entries_have_postings ON journal_entries;
CREATE CONSTRAINT TRIGGER journal_entries_have_postings
    AFTER INSERT ON journal_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION ledger_entry_has_postings();

-- Stamp the ancillary parent, so the policy never reads units.
--
-- SECURITY INVOKER, like delegation_scope_target(): the lookup runs under the
-- writer's own row-level security. A writer who cannot see the unit gets a NULL
-- parent and loses the ancillary hop, which fails closed — the row is harder to
-- reach, never easier. SECURITY DEFINER would be worse than useless here: the
-- function's owner is the table owner, which FORCE row level security applies to
-- and which sets no app.tenant_id, so it would see nothing at all.
CREATE OR REPLACE FUNCTION ledger_posting_unit_parent() RETURNS trigger
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

DROP TRIGGER IF EXISTS ledger_postings_unit_parent ON ledger_postings;
CREATE TRIGGER ledger_postings_unit_parent
    BEFORE INSERT ON ledger_postings
    FOR EACH ROW EXECUTE FUNCTION ledger_posting_unit_parent();

-- Balances, derived. There is no stored "amount due" anywhere in this schema and
-- this view is why one is never needed.
--
-- security_invoker is load-bearing and is the reason this schema requires
-- PostgreSQL 15 or later. Without it a view executes with its owner's
-- privileges, so current_user inside the view is dwellm8 — every policy would be
-- evaluated for the wrong role, is_platform_session() would be false even for a
-- platform session, and the delegated branch would be judged against a role that
-- holds no grant. The view would not leak, it would silently under-report, which
-- is the harder failure to notice. Prod and CI are 16.
CREATE OR REPLACE VIEW ledger_balances
    WITH (security_invoker = true) AS
    SELECT p.tenant_id,
           p.property_id,
           p.unit_id,
           p.account_code,
           a.account_type,
           p.party_kind,
           p.party_id,
           p.currency,
           sum(p.signed_minor)                                    AS balance_minor,
           sum(p.amount_minor) FILTER (WHERE p.side = 'debit')    AS debit_minor,
           sum(p.amount_minor) FILTER (WHERE p.side = 'credit')   AS credit_minor,
           count(*)                                               AS posting_count,
           max(p.created_at)                                      AS last_posted_at
      FROM ledger_postings p
      JOIN ledger_accounts a ON a.code = p.account_code
     GROUP BY p.tenant_id, p.property_id, p.unit_id, p.account_code,
              a.account_type, p.party_kind, p.party_id, p.currency;

COMMENT ON VIEW ledger_balances IS
    'ADR-0006 §5. Every balance in the product, derived. security_invoker is required: without it the view runs as its owner and RLS is evaluated for the wrong role.';

ALTER TABLE journal_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE journal_entries FORCE  ROW LEVEL SECURITY;
ALTER TABLE ledger_postings ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_postings FORCE  ROW LEVEL SECURITY;

-- The entry header carries no property, so its delegated branch is grant-level:
-- a firm with money.read sees the entries of the owner that granted it. The
-- lines are where the scoping bites, and a firm that can see a header whose
-- lines are all invisible learns that something happened and nothing else.
DROP POLICY IF EXISTS journal_entries_tenant_isolation ON journal_entries;
CREATE POLICY journal_entries_tenant_isolation ON journal_entries
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, NULL, 'money.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (grant_id = current_grant_id()
               AND actor_org_id = current_tenant_id()
               AND is_delegated(tenant_id, NULL, 'money.collect')));

-- Unit granularity, and closed for a posting with no property.
--
-- property_id is nullable here — a GST remittance belongs to the organisation,
-- not to a building — and a NULL passed to is_delegated_unit() matches only a
-- portfolio scope, which would hand a firm the owner's statutory position. So
-- the delegated branch requires a property outright. A firm sees the money of
-- the units it manages and nothing about the organisation that owns them.
DROP POLICY IF EXISTS ledger_postings_tenant_isolation ON ledger_postings;
CREATE POLICY ledger_postings_tenant_isolation ON ledger_postings
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (property_id IS NOT NULL
               AND is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.read')))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (property_id IS NOT NULL
               AND is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'money.collect')));

-- Immutability, as policy. The privileges are revoked further down as well:
-- an UPDATE that the privilege allows and the policy refuses is a bug report;
-- an UPDATE that both allow is a ledger nobody can trust.
--
-- RESTRICTIVE, so these AND with the policy above instead of ORing with it.
DROP POLICY IF EXISTS journal_entries_no_update ON journal_entries;
CREATE POLICY journal_entries_no_update ON journal_entries AS RESTRICTIVE FOR UPDATE USING (false);
DROP POLICY IF EXISTS journal_entries_no_delete ON journal_entries;
CREATE POLICY journal_entries_no_delete ON journal_entries AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS ledger_postings_no_update ON ledger_postings;
CREATE POLICY ledger_postings_no_update ON ledger_postings AS RESTRICTIVE FOR UPDATE USING (false);
DROP POLICY IF EXISTS ledger_postings_no_delete ON ledger_postings;
CREATE POLICY ledger_postings_no_delete ON ledger_postings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The chart and the templates are reference data: every module reads them,
-- nothing writes them at runtime, and they carry no tenant data — which is why
-- they have no row-level security and are named in the isolation harness's
-- exempt list with that reason.
GRANT SELECT ON ledger_accounts, posting_templates, posting_template_lines
    TO dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
       dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

-- Money writes the ledger. Everything else reads it, because a lease screen
-- shows a balance and a maintenance job shows what a repair cost.
GRANT SELECT, INSERT ON journal_entries, ledger_postings TO dwellm8_money;
GRANT SELECT ON journal_entries, ledger_postings TO dwellm8_identity, dwellm8_property,
    dwellm8_lease, dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT SELECT ON ledger_balances TO dwellm8_identity, dwellm8_property, dwellm8_lease,
    dwellm8_money, dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify;

