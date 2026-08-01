-- ===========================================================================
-- payout accounts — the impersonated-owner control (threat-model §4, #227)
-- ===========================================================================
-- The account a payout goes to, as effective-dated rows: a change closes the
-- current row and opens a new one, so the previous account survives to be
-- notified and to answer "where was March's rent sent". The full number is
-- never stored (ADR-0013's posture) — a mask for humans, a keyed fingerprint
-- for identity, and the provider's beneficiary reference for the transfer.
CREATE TABLE IF NOT EXISTS payout_accounts (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id            uuid NOT NULL REFERENCES organisations(id),
    owner_party_id       uuid NOT NULL,
    masked_account       text NOT NULL,
    ifsc                 text NOT NULL,
    -- HMAC under a key the database never sees, not a bare hash: account
    -- numbers are enumerable enough that a hash column is a lookup table.
    account_fp           text NOT NULL,
    provider_beneficiary_id text,
    valid_from           timestamptz NOT NULL DEFAULT now(),
    valid_to             timestamptz,
    changed_by_party_id  uuid,
    changed_via_grant_id uuid REFERENCES delegation_grants(id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT payout_accounts_interval CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS payout_accounts_one_current
    ON payout_accounts (tenant_id, owner_party_id) WHERE valid_to IS NULL;
CREATE INDEX IF NOT EXISTS payout_accounts_fp_idx
    ON payout_accounts (tenant_id, owner_party_id, account_fp);

ALTER TABLE payout_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE payout_accounts FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS payout_accounts_tenant_isolation ON payout_accounts;
-- NULL property: an owner's payout account is organisation-scoped, so a
-- mandate carrying money.payout reaches it portfolio-wide by design.
CREATE POLICY payout_accounts_tenant_isolation ON payout_accounts
    USING      (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, NULL, 'money.payout'))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, NULL, 'money.payout'));
DROP POLICY IF EXISTS payout_accounts_no_delete ON payout_accounts;
CREATE POLICY payout_accounts_no_delete ON payout_accounts AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON payout_accounts TO dwellm8_money;

-- The control itself. An account may receive a payout only when every row of
-- its fingerprint has been on file longer than the cool-off — 72 hours, long
-- enough for the old-channel notifications to be seen and acted on, short
-- enough that a real owner's change costs one payout cycle at worst. First
-- appearance decides: switching back to the long-standing account pays at
-- once, and an attacker's account gains nothing by being re-entered (#227's
-- changed-back edge). Not SECURITY DEFINER — it reads under the caller's own
-- row-level security like is_delegated(), and for the same reason.
CREATE OR REPLACE FUNCTION payout_account_payable(p_owner uuid, p_at timestamptz DEFAULT now())
RETURNS uuid LANGUAGE sql STABLE AS $fn$
    SELECT cur.id
      FROM payout_accounts cur
     WHERE cur.owner_party_id = p_owner
       AND cur.valid_to IS NULL
       AND (SELECT min(first.valid_from)
              FROM payout_accounts first
             WHERE first.tenant_id = cur.tenant_id
               AND first.owner_party_id = cur.owner_party_id
               AND first.account_fp = cur.account_fp)
           <= p_at - interval '72 hours'
$fn$;
COMMENT ON FUNCTION payout_account_payable(uuid, timestamptz) IS
    'The id of the owner''s current payout account if it is outside its cool-off, else NULL — a NULL is a held payout, and the payout run must surface it, not skip it (#227)';
GRANT EXECUTE ON FUNCTION payout_account_payable(uuid, timestamptz) TO dwellm8_money;

-- A full account number does not fit in the only column that could hold one.
ALTER TABLE payout_accounts DROP CONSTRAINT IF EXISTS payout_accounts_account_is_a_mask;
ALTER TABLE payout_accounts ADD CONSTRAINT payout_accounts_account_is_a_mask
    CHECK (masked_account !~ '^[0-9]+$' AND length(masked_account) BETWEEN 6 AND 24);

-- The load-bearing rules.
--
-- Every CHECK an ADR argues for at length lives here rather than inside its
-- CREATE TABLE, and this block is the third and last entry in this file's longest-
-- running trap: **a CHECK written inside CREATE TABLE IF NOT EXISTS is skipped
-- entirely on a database that already has the table.** The file replays, exits 0,
-- reports nothing, and the constraint is simply absent — present in CI, where every
-- database is fresh, and missing in the one place it matters.
--
-- Measured, on a database where one had been dropped by hand:
--
--   $ psql -v ON_ERROR_STOP=1 -f dwellm8.sql      # exit 0, no output
--   $ SELECT count(*) FROM pg_constraint
--       WHERE conname = 'workflow_runs_compensated_means_reversible';
--     0
--
-- The two vocabulary migrations above (journal_entries_kind, and the reversal
-- reasons) were the first two times it bit, and both were fixed one at a time. This
-- block is the structural version: one definition per rule, in a position that
-- reaches every database, and assertion 13 fails the bootstrap if any of them is
-- absent afterwards. Duplicating them — inline *and* here — was the obvious fix and
-- is worse: two definitions of one rule drift, and the one that runs is the one
-- nobody reads.
--
-- ADD CONSTRAINT has no IF NOT EXISTS, hence the guard on each.
--
-- And it validates the rows already there, which is the second thing this block has
-- to handle. A constraint that went missing let data in that violates it, so adding
-- it back fails — and failing here would take every unrelated statement below down
-- with it, on every bootstrap, forever. ADR-0009's backfill hit the same wall and
-- set the precedent: count the offending rows and RAISE WARNING rather than
-- aborting. Measured:
--
--   ERROR:  check constraint "workflow_runs_compensated_means_reversible" of
--           relation "workflow_runs" is violated by some row
--
-- Assertion 13 still fails and still names the constraint, which is the outcome
-- wanted: loud and specific, without holding the rest of the schema hostage to rows
-- somebody has to look at.
--
-- `WHERE NOT (expr)` is the right test rather than `WHERE expr IS NOT TRUE`: a CHECK
-- is satisfied by NULL, and so is this.
--
-- And the count needs the row-level security window, which is this file's oldest
-- trap biting the guard written for its second-oldest. The first version counted
-- without one: the bootstrap connects as the owner, FORCE row level security applies
-- to the owner, and no app.tenant_id is set — so the count came back 0 from a table
-- with a violating row in it, the block decided the table was clean, and the ALTER
-- failed anyway because DDL validates every row regardless of any policy. The
-- symptom was the error this block exists to avoid, produced by the check meant to
-- avoid it.
DO $$
DECLARE
    r record;
    bad bigint;
BEGIN
    FOR r IN
        SELECT * FROM (VALUES
            -- ADR-0011 §3. Money the provider has and the ledger does not know
            -- about is the exact shape of the defect that subsystem prevents.
            ('payments', 'payments_captured_has_entry',
             $c$status NOT IN ('captured', 'settled') OR entry_id IS NOT NULL$c$),

            -- ADR-0012 §2. A file we parsed wrong must not be able to look like a
            -- file we disagree with.
            ('settlement_batches', 'settlement_batches_adds_up',
             $c$net_minor = gross_minor - refund_minor - fee_minor - tax_minor$c$),

            -- ADR-0012 §5. A line that did not reconcile cannot have caused an
            -- entry, whatever the code believed.
            ('settlement_lines', 'settlement_lines_only_matched_lines_post',
             $c$entry_id IS NULL OR match_class IN ('exact', 'fee_adjusted')$c$),

            -- ADR-0012 §8. A comparison over no lines looks perfectly clean.
            ('reconciliation_runs', 'reconciliation_runs_reconciled_saw_the_file',
             $c$state NOT IN ('reconciled', 'drift') OR file_present$c$),

            -- ADR-0015 §4. Recording a compensation after money has left says the
            -- world was put back, and every report downstream believes it.
            ('workflow_runs', 'workflow_runs_compensated_means_reversible',
             $c$state <> 'compensated' OR NOT past_no_return$c$),

            -- ADR-0013 §2. A full identifier does not fit in the only column that could
            -- hold one. Per kind, because the mask of a PAN is a different shape from the
            -- mask of an Aadhaar and a single loose pattern would accept both a mask and
            -- the thing it was made from. The patterns come from internal/platform/pii and
            -- the store contract test compares them.
            ('kyc_verifications', 'kyc_verifications_reference_is_a_mask',
             $c$CASE kind
                WHEN 'aadhaar'         THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'pan'             THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'bank_account'    THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'passport'        THEN masked_reference ~ '^X+[0-9A-Z]{3}$'
                WHEN 'driving_licence' THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'voter_id'        THEN masked_reference ~ '^X+[0-9A-Z]{4}$'
                WHEN 'ifsc'            THEN masked_reference ~ '^[A-Z]{4}0[A-Z0-9]{6}$'
                WHEN 'gstin'           THEN masked_reference ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z][Z][0-9A-Z]$'
                WHEN 'upi_vpa'         THEN masked_reference ~ '^[a-zA-Z0-9.\-_]{2,256}@[a-zA-Z]{2,64}$'
                END$c$),

            -- ADR-0013 §5. A support read with no grant behind it is the thing an audit
            -- exists to catch.
            ('kyc_access_log', 'kyc_access_log_support_needs_a_grant',
             $c$actor_kind <> 'support' OR support_grant_id IS NOT NULL$c$),

            -- ADR-0022 §2. An active authority nobody can ask the provider about is
            -- one that cannot be confirmed, paused or revoked — it can only be
            -- debited, which is the wrong half to keep.
            ('mandates', 'mandates_active_has_provider_id',
             $c$status <> 'active' OR provider_mandate_id IS NOT NULL$c$),

            -- ADR-0022 §4. The inbox rule extended to authorities: nothing
            -- unverified may ever be attributed to one.
            ('payment_events', 'payment_events_unverified_names_no_mandate',
             $c$signature_verified OR mandate_id IS NULL$c$),

            -- ADR-0023 §3. The value matches the kind that names it. A rate read as
            -- an amount is 18 paise of GST, and nothing about the invoice looks wrong.
            ('statutory_rules', 'statutory_rules_value_shape',
             $c$(value_kind = 'rate'   AND rate_bps     IS NOT NULL AND amount_minor IS NULL AND count_value IS NULL)
             OR (value_kind = 'amount' AND amount_minor IS NOT NULL AND rate_bps     IS NULL AND count_value IS NULL)
             OR (value_kind = 'count'  AND count_value  IS NOT NULL AND rate_bps     IS NULL AND amount_minor IS NULL)
             OR (value_kind = 'slabs'  AND rate_bps IS NULL AND amount_minor IS NULL AND count_value IS NULL)$c$),

            -- ADR-0023 §4. A cap enforced from a blog post is worse than no cap,
            -- because it is wrong with authority.
            ('statutory_rules', 'statutory_rules_unverified_cannot_block',
             $c$enforcement <> 'block' OR verification_status = 'verified'$c$)
        ) AS t(tbl, name, expr)
    LOOP
        CONTINUE WHEN EXISTS (SELECT 1 FROM pg_constraint WHERE conname = r.name);

        -- The scoped window, as in every other data-touching statement in this
        -- section. One transaction, so a failure restores FORCE with the rollback.
        EXECUTE format('ALTER TABLE %I NO FORCE ROW LEVEL SECURITY', r.tbl);
        EXECUTE format('SELECT count(*) FROM %I WHERE NOT (%s)', r.tbl, r.expr) INTO bad;
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', r.tbl);
        IF bad > 0 THEN
            RAISE WARNING '% row(s) in % violate %, so it is not being added. Those rows were '
                          'written while the rule was absent and need a decision, not a migration; '
                          'assertion 13 will fail until they are dealt with.', bad, r.tbl, r.name;
        ELSE
            EXECUTE format('ALTER TABLE %I ADD CONSTRAINT %I CHECK (%s)', r.tbl, r.name, r.expr);
            RAISE NOTICE 'added missing constraint %.%', r.tbl, r.name;
        END IF;
    END LOOP;
END
$$;

