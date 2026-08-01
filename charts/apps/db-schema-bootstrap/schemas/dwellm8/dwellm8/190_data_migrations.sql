-- ===========================================================================
-- data migrations
-- ===========================================================================

-- Statements that touch rows rather than definitions.
--
-- A data migration in this file has a problem that cost a debugging session and
-- is invisible in review: **it cannot see any row**. The bootstrap connects as
-- the table owner, FORCE row level security applies to the owner (ADR-0003 §2 is
-- entirely about that), and the job sets no app.tenant_id because it is not a
-- request. So every policy evaluates to false and an UPDATE here matches nothing.
-- It does not error. It reports UPDATE 0 and the file carries on.
--
-- Measured: replaying ADR-0009 onto a database that already held a grant scope,
-- the backfill silently touched zero rows and the CHECK constraint two statements
-- later failed on the row the backfill was supposed to have fixed — "check
-- constraint delegation_grant_scopes_property_shape ... is violated by some row".
--
-- So each migration opens the smallest possible window: NO FORCE, the statement,
-- FORCE again, inside one DO block and therefore one transaction. If anything
-- raises, the transaction rolls back and FORCE is restored with it; the ALTER
-- takes an ACCESS EXCLUSIVE lock, so no other session can read the table
-- unforced. The alternative — granting the owner membership of dwellm8_platform —
-- would exempt the API too, because it connects as the same role.
--
-- Assertion 1 at the foot of this file is what catches a window left open.

-- ADR-0009. Resolve grant scopes written before scope_property_id existed.
-- A property scope resolves to itself. A unit scope cannot be resolved — no
-- units existed to point at, so any such row named a unit that was never real,
-- which is what ADR-0005 recorded as the gap this ADR closes.
DO $$
DECLARE
    unresolved int;
BEGIN
    ALTER TABLE delegation_grant_scopes NO FORCE ROW LEVEL SECURITY;

    UPDATE delegation_grant_scopes
       SET scope_property_id = scope_id
     WHERE scope_kind = 'property' AND scope_property_id IS NULL;

    SELECT count(*) INTO unresolved
      FROM delegation_grant_scopes
     WHERE scope_kind <> 'portfolio' AND scope_property_id IS NULL;

    ALTER TABLE delegation_grant_scopes FORCE ROW LEVEL SECURITY;

    IF unresolved > 0 THEN
        -- Do not add the constraint over rows that violate it; that fails the
        -- whole bootstrap and takes every unrelated change down with it. Say
        -- what is wrong instead, and leave the rest of the file to run.
        RAISE WARNING '% grant scope row(s) could not be resolved to a property — '
                      'the shape constraint is not being added. These are unit scopes '
                      'written before ADR-0009, and they grant nothing.', unresolved;
    ELSIF NOT EXISTS (SELECT 1 FROM pg_constraint
                       WHERE conname = 'delegation_grant_scopes_property_shape') THEN
        -- ADD CONSTRAINT IF NOT EXISTS does not exist, and a bare ADD CONSTRAINT
        -- fails the replay on the second run.
        ALTER TABLE delegation_grant_scopes ADD CONSTRAINT delegation_grant_scopes_property_shape
            CHECK ((scope_kind = 'portfolio') = (scope_property_id IS NULL));
    END IF;
END
$$;

-- ADR-0012. Widen journal_entries_kind for the two settlement kinds.
--
-- This is a definition, not data, and it needs no row-level security window. What
-- it does need is to exist at all: the CHECK is written inside CREATE TABLE IF NOT
-- EXISTS, which does not revisit a table that is already there. Adding a kind to
-- that clause alone reaches every fresh database — including CI — and no existing
-- one, so the first entry of the new kind would have failed in production against
-- a schema whose tests were green.
--
-- Dropped and re-added rather than altered, because a CHECK cannot be altered, and
-- unconditionally rather than IF NOT EXISTS, because the point is to replace an
-- older definition with a wider one.
DO $$
BEGIN
    ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entries_kind;
    ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_kind CHECK (entry_kind IN (
        'invoice', 'late_fee', 'payment', 'payment_with_tds', 'settlement',
        'settlement_with_fee', 'clearing_write_off',
        'deposit_collection', 'deposit_refund', 'payout', 'platform_fee',
        'gst_remittance', 'refund', 'write_off', 'reversal'));
END
$$;

-- ADR-0015. The platform organisation, which ADR-0002 §1 has assumed since it was
-- written and nothing ever created.
--
-- Found while wiring the durable-operations tables: every platform-level fact in
-- ADR-0002 carries "the platform organisation", workflow_runs.tenant_id has a
-- foreign key to organisations, and there was no such row. The first platform-level
-- event would have failed that key in production, having passed every test that
-- never wrote one.
--
-- It is here, in the scoped window, because the section above this one explains
-- exactly why: the bootstrap connects as the table owner, FORCE row level security
-- applies to the owner, and no app.tenant_id is set, so every policy evaluates
-- false. Measured — as an inline INSERT beside the table definitions it fails the
-- whole bootstrap:
--
--   ERROR:  new row violates row-level security policy for table "organisations"
--
-- Which is the same cause as the silent UPDATE 0 described above and the opposite
-- symptom. The loud one is the better failure, and it is only loud because an
-- INSERT is judged by WITH CHECK rather than filtered by USING.
--
-- The uuid is the one internal/money/domain already uses as the platform *party*
-- on ledger postings. One number for one actor: two magic uuids that both mean
-- "us" is a thing every reader has to look up.
DO $$
BEGIN
    ALTER TABLE organisations NO FORCE ROW LEVEL SECURITY;

    INSERT INTO organisations (id, slug, name, kind, state)
    VALUES ('00000000-0000-0000-0000-0000000000d8', 'dwellm8-platform', 'Dwellm8', 'platform', 'active')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE organisations FORCE ROW LEVEL SECURITY;
END
$$;

-- ADR-0015. Widen journal_entries_reversal_reason_check for `workflow_compensated`.
--
-- Same reason and same shape as the entry_kind migration above: the inline clause
-- in CREATE TABLE IF NOT EXISTS never reaches a database that already exists, so
-- without this the first compensating reversal would be refused in production by a
-- constraint every test had seen the wider version of.
--
-- The reason is its own rather than operator_error because nobody made an error: the
-- entry was correct when it was posted and a later step of the same operation
-- failed. ADR-0015 §4.
DO $$
BEGIN
    ALTER TABLE journal_entries DROP CONSTRAINT IF EXISTS journal_entries_reversal_reason_check;
    ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_reversal_reason_check
        CHECK (reversal_reason IS NULL OR reversal_reason IN (
            'duplicate', 'wrong_amount', 'wrong_account', 'wrong_party',
            'wrong_period', 'provider_chargeback', 'operator_error',
            'settlement_mismatch', 'workflow_compensated'));
END
$$;

-- ADR-0010 §7. journal_entries.lease_id — the tenancy an entry bills.
--
-- Added here rather than in the CREATE TABLE for the reason the block below exists:
-- CREATE TABLE IF NOT EXISTS never revisits a table that already exists, and
-- journal_entries has existed since ADR-0006. ADD COLUMN IF NOT EXISTS does exist, so
-- unlike a CHECK this one can be written once.
--
-- Nullable: most entries have no tenancy. The rule that remains is one-directional —
-- a lease charge names its lease — which is what keeps ADR-0010 §7's trigger enforcing.
--
-- The converse was withdrawn by the ADR-0006 §5 amendment: it forbade a payment
-- (source_kind 'payment') from naming the lease it paid, so a per-lease position summed
-- the invoices and none of the receipts.
DO $$
BEGIN
    ALTER TABLE journal_entries ADD COLUMN IF NOT EXISTS lease_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'journal_entries_lease_fkey') THEN
        ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_lease_fkey
            FOREIGN KEY (lease_id, tenant_id) REFERENCES leases (id, tenant_id);
    END IF;

    -- The source_kind vocabulary stays open — ADR-0006 deliberately left it free text so
    -- any module can name its own cause — but 'lease_charge' now means something the
    -- database checks.
    --
    -- Compared by definition, not by name: an older database has the stricter rule
    -- under this same name, so IF NOT EXISTS alone would skip it forever. `<>` appears
    -- in the implication and in no earlier version.
    IF EXISTS (SELECT 1 FROM pg_constraint
                WHERE conname = 'journal_entries_lease_charge_shape'
                  AND pg_get_constraintdef(oid) NOT LIKE '%<>%') THEN
        ALTER TABLE journal_entries DROP CONSTRAINT journal_entries_lease_charge_shape;
        RAISE NOTICE 'relaxed journal_entries_lease_charge_shape: lease_id now names the '
                     'tenancy an entry concerns, not only the tenancy it bills';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'journal_entries_lease_charge_shape') THEN
        ALTER TABLE journal_entries ADD CONSTRAINT journal_entries_lease_charge_shape
            CHECK (source_kind <> 'lease_charge' OR lease_id IS NOT NULL);
    END IF;
END
$$;

-- "What has this tenancy been billed" — the retrospective-termination trigger's own
-- query, and the owner's statement for a lease.
CREATE INDEX IF NOT EXISTS journal_entries_lease_idx
    ON journal_entries (tenant_id, lease_id, occurred_on) WHERE lease_id IS NOT NULL;

-- payments.lease_id — the tenancy a collection pays. Issue #42.
--
-- Nullable: a deposit or an ad-hoc collection has no tenancy. Where it is set, the
-- entry the capture posts inherits it, which is what puts receipts into a lease
-- position alongside the charges. Added by migration for the usual reason, and after
-- leases because a foreign key cannot precede its target.
DO $$
BEGIN
    ALTER TABLE payments ADD COLUMN IF NOT EXISTS lease_id uuid;

    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payments_lease_fkey') THEN
        ALTER TABLE payments ADD CONSTRAINT payments_lease_fkey
            FOREIGN KEY (lease_id, tenant_id) REFERENCES leases (id, tenant_id);
    END IF;
END
$$;

-- "What has this tenancy paid" — the other half of the lease statement.
CREATE INDEX IF NOT EXISTS payments_lease_idx
    ON payments (tenant_id, lease_id) WHERE lease_id IS NOT NULL;


-- ADR-0031: who the platform fee comes out of, recorded on the payment.
--
-- On the payment rather than derived at capture, because the fee is posted when
-- the money arrives and the arrangement that decided the bearer may have changed
-- since the order was created. The rate is resolved the same way — as of the
-- payment's own date — so a fee and the split that collected it cannot disagree.
--
-- Nullable: a collection with no bearer charges no fee, and says so in the log
-- rather than silently earning nothing.
ALTER TABLE payments ADD COLUMN IF NOT EXISTS fee_bearer_party_id uuid;
