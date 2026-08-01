-- ===========================================================================
-- settlement reconciliation (ADR-0012)
-- ===========================================================================

-- Three accounts of the same money, and therefore three comparisons.
--
--   settlement_batches    what the provider says it paid onward, and its totals
--   settlement_lines      the rows of that file, matched or not
--   settlement_drift      every disagreement, in whichever direction it was found
--   reconciliation_runs   one provider-day, and whether it can honestly be
--                         called reconciled
--
-- All four are platform-owned, and none of them is tenant-scoped in the ordinary
-- ADR-0003 sense. A settlement batch is not tenant data: it is one payout from
-- one aggregator account, spanning every organisation that collected that day. It
-- *resolves into* tenant data, one matched line at a time, and until a line is
-- matched it belongs to nobody at all.
--
-- ADR-0011 §5 introduced that exception for the webhook inbox as a one-off. Three
-- more tables of the same shape make it a pattern, and a pattern needs a guard:
-- assertion 12 at the foot of this file requires every table whose rows may
-- belong to no organisation to be writable only by a platform session.

CREATE TABLE IF NOT EXISTS settlement_batches (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider          text NOT NULL,
    provider_batch_id text NOT NULL,

    -- The bank reference the provider says it paid under. Not decorative: it is
    -- the only handle that connects this batch to a line on a bank statement, and
    -- a batch without one can be reconciled against our own records but never
    -- against the bank's.
    utr               text,
    settled_on        date NOT NULL,
    currency          char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    -- The provider's own totals. Checked against each other below before any
    -- line of the file is believed.
    gross_minor       bigint NOT NULL CHECK (gross_minor  >= 0),
    refund_minor      bigint NOT NULL DEFAULT 0 CHECK (refund_minor >= 0),
    fee_minor         bigint NOT NULL DEFAULT 0 CHECK (fee_minor    >= 0),
    tax_minor         bigint NOT NULL DEFAULT 0 CHECK (tax_minor    >= 0),
    net_minor         bigint NOT NULL CHECK (net_minor    >= 0),

    ingested_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT settlement_batches_amount_representable CHECK (
        gross_minor <= 9007199254740991),
    -- The first thing checked and the thing that stops everything if it fails. A
    -- file we parsed wrong — a column misread, rupees where paise were expected —
    -- fails here at ingestion rather than as five hundred inexplicable drift rows
    -- tomorrow. Stated in the database as well as in Go, because the failure it
    -- prevents is one where our own numbers are the ones that are wrong, and a
    -- guard that only exists in the code that got it wrong is not a guard.
    CONSTRAINT settlement_batches_currency_known CHECK (currency = 'INR')
);
-- settlement_batches_adds_up is in the "load-bearing rules" block below.

COMMENT ON TABLE settlement_batches IS
    'ADR-0012. One payout from one aggregator account. Platform-owned: a batch spans every organisation that collected that day.';

-- The deduplication. Re-ingesting the same file must be a no-op, and it is the
-- normal case: a retried job, a manually re-run day, a provider re-publishing a
-- corrected file under the same id.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_batches_provider_idx
    ON settlement_batches (provider, provider_batch_id);
CREATE INDEX IF NOT EXISTS settlement_batches_day_idx
    ON settlement_batches (provider, settled_on);

CREATE TABLE IF NOT EXISTS settlement_lines (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id            uuid NOT NULL REFERENCES settlement_batches(id),

    -- NULL until this line is matched to a payment, and that is the point. A line
    -- naming a payment this system never issued has no organisation to attribute
    -- it to; guessing one is a cross-tenant write and dropping the line loses
    -- money a provider believes it moved. ADR-0011 §5, second occurrence.
    tenant_id           uuid REFERENCES organisations(id),

    provider            text NOT NULL,
    -- The provider's own id for the row. A provider that supplies none forces the
    -- adapter to synthesise a stable one: without it a re-ingested file doubles
    -- every amount in it.
    provider_line_id    text NOT NULL,
    provider_payment_id text,

    line_kind           text NOT NULL CHECK (line_kind IN (
                            'payment', 'refund', 'chargeback', 'fee', 'adjustment')),
    direction           text NOT NULL CHECK (direction IN ('inward', 'outward')),

    -- The line's gross — what the payer paid, not what reached the bank. Matching
    -- is against the gross because the gross is what clearing is carrying.
    amount_minor        bigint NOT NULL CHECK (amount_minor > 0),
    fee_minor           bigint NOT NULL DEFAULT 0 CHECK (fee_minor >= 0),
    tax_minor           bigint NOT NULL DEFAULT 0 CHECK (tax_minor >= 0),

    payment_id          uuid REFERENCES payments(id),
    match_class         text CHECK (match_class IN (
                            'exact', 'fee_adjusted', 'partial',
                            'unknown_payment', 'duplicate', 'amount_drift')),
    -- Orthogonal to the class, and deliberately not a class of its own: a line
    -- can be both late and fee-adjusted, and a design where lateness is a class
    -- has to discard one of them. ADR-0012 §5.
    late                boolean NOT NULL DEFAULT false,

    -- The settlement entry this line caused, once it caused one.
    entry_id            uuid,

    settled_on          date NOT NULL,
    matched_at          timestamptz,

    CONSTRAINT settlement_lines_amount_representable CHECK (
        amount_minor <= 9007199254740991),
    -- A provider that kept the whole collection is a parsing error, not a
    -- settlement.
    CONSTRAINT settlement_lines_keeps_less_than_it_settles CHECK (
        fee_minor + tax_minor < amount_minor),
    -- A payment line says which payment. An adjustment against a payment is a fee
    -- or a refund under the wrong label, and treating it as an adjustment loses
    -- the payment it concerns.
    CONSTRAINT settlement_lines_names_its_payment CHECK (
        (line_kind = 'payment') <= (provider_payment_id IS NOT NULL)
        AND NOT (line_kind = 'adjustment' AND provider_payment_id IS NOT NULL)),
    -- A refund, a chargeback and a fee are always money leaving; only an
    -- adjustment may go either way. A refund that claims to be inward would
    -- inflate a settlement, and the file that says so is one we misread.
    CONSTRAINT settlement_lines_direction_matches_kind CHECK (
        line_kind = 'adjustment'
        OR (line_kind = 'payment') = (direction = 'inward')),
    -- Attribution and a match arrive together or not at all. A line with a
    -- payment and no organisation is invisible to the organisation whose money it
    -- is; one with an organisation and no payment is an attribution nothing
    -- supports.
    CONSTRAINT settlement_lines_attribution_shape CHECK (
        (payment_id IS NULL) = (tenant_id IS NULL)),
    -- settlement_lines_only_matched_lines_post is in the "load-bearing rules" block
    -- below: ADR-0012 §5's half of "two classes may post and four may not".
    CONSTRAINT settlement_lines_settled_on_known CHECK (settled_on IS NOT NULL)
);

COMMENT ON TABLE settlement_lines IS
    'ADR-0012. One row of a settlement file. tenant_id is NULL until the line is matched: an unmatched line belongs to no organisation.';
COMMENT ON COLUMN settlement_lines.tenant_id IS
    'NULL for a line naming a payment this system does not have. Kept where only a platform session can see it, rather than guessed at or dropped.';

-- Re-ingesting a file is a no-op because of this index, not because a handler
-- checked first. Same argument as ADR-0011 §2.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_lines_provider_line_idx
    ON settlement_lines (provider, provider_line_id);
-- "Has this payment been settled before" — the cross-run duplicate check, which
-- is the only way a genuine double settlement can be found: a re-sent file is
-- deduplicated by line id, and a provider settling the same payment twice sends
-- two different line ids.
CREATE INDEX IF NOT EXISTS settlement_lines_provider_payment_idx
    ON settlement_lines (provider, provider_payment_id)
    WHERE provider_payment_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS settlement_lines_batch_idx
    ON settlement_lines (batch_id, line_kind);
-- The sweep's question: which lines have not been classified at all.
CREATE INDEX IF NOT EXISTS settlement_lines_unmatched_idx
    ON settlement_lines (provider, settled_on) WHERE match_class IS NULL;

-- Every disagreement, in whichever direction it was found.
--
-- kind names which pair of accounts disagreed, because the fix is different for
-- each and one 'unreconciled' bucket loses that. missing_settlement is the
-- direction with no row in it — a payment captured here that no file has ever
-- mentioned — and it is the reason this table is written by a job with a clock
-- rather than derived from the file.
CREATE TABLE IF NOT EXISTS settlement_drift (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    -- NULL for a line naming a payment this system does not have, and for the
    -- clearing-balance check, which is platform-wide by nature.
    tenant_id           uuid REFERENCES organisations(id),
    provider            text NOT NULL,
    as_of_date          date NOT NULL,

    drift_kind          text NOT NULL CHECK (drift_kind IN (
                            'missing_settlement', 'unknown_line', 'amount_mismatch',
                            'duplicate_settlement', 'late_settlement', 'clearing_balance')),

    payment_id          uuid REFERENCES payments(id),
    line_id             uuid REFERENCES settlement_lines(id),
    provider_payment_id text,

    amount_minor        bigint NOT NULL CHECK (amount_minor > 0),
    -- When the money became wrong. The age is now() - this, and the bucket is
    -- derived from the age by the view below — never stored. A stored bucket is
    -- wrong the day after it is written, and the whole value of an ageing report
    -- is that yesterday's three-day-old item is four days old today.
    since               timestamptz NOT NULL,

    state               text NOT NULL DEFAULT 'open'
                        CHECK (state IN ('open', 'resolved', 'written_off')),
    -- The manual resolution workflow's audit trail. A resolution with no note and
    -- no actor is a row somebody closed, which is not the same as a row somebody
    -- explained.
    resolution_note     text,
    resolved_by         uuid,
    resolved_at         timestamptz,
    -- A write-off is money abandoned, so it posts. Same shape and same reason as
    -- payments_captured_has_entry: a clearing balance written off with no entry is
    -- a loss the ledger does not know about.
    entry_id            uuid,

    detected_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT settlement_drift_amount_representable CHECK (
        amount_minor <= 9007199254740991),
    CONSTRAINT settlement_drift_resolution_shape CHECK (
        (state = 'open') = (resolved_at IS NULL)
        AND (state = 'open') = (resolved_by IS NULL)
        AND (state = 'open') = (resolution_note IS NULL)),
    CONSTRAINT settlement_drift_write_off_posts CHECK (
        state <> 'written_off' OR entry_id IS NOT NULL),
    -- Late is not resolvable and must not sit in somebody's queue: the money
    -- arrived, and the row exists so the ageing report can show it was slow.
    CONSTRAINT settlement_drift_late_is_not_a_task CHECK (
        drift_kind <> 'late_settlement' OR state = 'open')
);

COMMENT ON TABLE settlement_drift IS
    'ADR-0012. Every way the three accounts of the money disagreed. Platform-owned: resolution spans organisations, because the clearing account does.';

-- One row per thing that is wrong, per run, and not five. A payment missing for
-- nine consecutive nights is one drift row that ages, not nine.
CREATE UNIQUE INDEX IF NOT EXISTS settlement_drift_open_payment_idx
    ON settlement_drift (provider, drift_kind, payment_id)
    WHERE state = 'open' AND payment_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS settlement_drift_open_line_idx
    ON settlement_drift (provider, drift_kind, line_id)
    WHERE state = 'open' AND line_id IS NOT NULL;
-- The ageing report, and the reconciled-is-earned trigger below.
CREATE INDEX IF NOT EXISTS settlement_drift_open_idx
    ON settlement_drift (provider, as_of_date, drift_kind) WHERE state = 'open';
CREATE INDEX IF NOT EXISTS settlement_drift_tenant_idx
    ON settlement_drift (tenant_id, state) WHERE tenant_id IS NOT NULL;

-- The ageing boundaries, as a function rather than as a CASE inside the view.
--
-- It is a function for the reason payment_transition_allowed() is: the rule exists
-- in Go as well, and a rule that exists twice needs a seam a test can evaluate.
-- Inline in the view, the only thing a contract test can compare is the view's
-- text — which catches a boundary that moved and cannot catch a boundary that was
-- rewritten to mean something different. Measured: with the boundaries inline, a
-- planted 3-day-to-2-day change was caught by a string search for '3 days' and not
-- by any comparison of what the two copies actually do.
--
-- Boundaries are compared as intervals, not as truncated days, and that asymmetry
-- is where Go and this disagreed first: an item three days and twenty-three hours
-- old is inside '3 days' by neither measure, but int(hours/24) said it was.
CREATE OR REPLACE FUNCTION settlement_age_bucket(age interval)
    RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT CASE
               WHEN age <  interval '1 day'   THEN 'same_day'
               WHEN age <= interval '3 days'  THEN '1_3_days'
               WHEN age <= interval '7 days'  THEN '4_7_days'
               WHEN age <= interval '30 days' THEN '8_30_days'
               ELSE 'over_30_days'
           END
$$;

COMMENT ON FUNCTION settlement_age_bucket(interval) IS
    'ADR-0012 §7. The ageing boundaries. Also in Go; the store contract test evaluates this function over a table of ages and fails on any disagreement.';

-- The ageing report. Derived, like every other balance in this schema.
--
-- security_invoker is as load-bearing here as it is on ledger_balances, and
-- assertion 10 no longer names either view: it now requires it of every view in
-- the schema, because a guard that covers the views its author had in mind decays
-- with the next one.
CREATE OR REPLACE VIEW settlement_drift_ageing
    WITH (security_invoker = true) AS
    SELECT d.provider,
           d.tenant_id,
           d.drift_kind,
           d.state,
           settlement_age_bucket(now() - d.since)  AS age_bucket,
           count(*)                                AS item_count,
           sum(d.amount_minor)                     AS amount_minor,
           min(d.since)                            AS oldest_since
      FROM settlement_drift d
     GROUP BY d.provider, d.tenant_id, d.drift_kind, d.state, 5;

COMMENT ON VIEW settlement_drift_ageing IS
    'ADR-0012 §7. Open drift by age. The bucket is derived from now(), never stored: a stored bucket is wrong the day after it is written.';

-- One provider-day, and whether it can honestly be called reconciled.
CREATE TABLE IF NOT EXISTS reconciliation_runs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    provider          text NOT NULL,
    as_of_date        date NOT NULL,

    -- 'reconciled' does not mean everything matched — a day with three missing
    -- payments still ran, and 'drift' is a finished state, not a failed one. What
    -- must never be reachable is 'reconciled' for a day whose file never arrived,
    -- because a comparison over no lines looks perfectly clean. ADR-0012 §8.
    state             text NOT NULL DEFAULT 'running' CHECK (state IN (
                          'running', 'reconciled', 'drift', 'incomplete', 'failed')),
    file_present      boolean NOT NULL DEFAULT false,

    lines_read        int NOT NULL DEFAULT 0 CHECK (lines_read >= 0),
    lines_matched     int NOT NULL DEFAULT 0 CHECK (lines_matched >= 0),
    settled_minor     bigint NOT NULL DEFAULT 0 CHECK (settled_minor >= 0),

    -- Recomputed by the trigger below from settlement_drift, never taken from the
    -- writer. A job that reports zero unresolved items while three drift rows are
    -- open is exactly the failure this table exists to prevent, and asking the job
    -- nicely is not a mechanism.
    unresolved_count  int NOT NULL DEFAULT 0 CHECK (unresolved_count >= 0),
    unresolved_minor  bigint NOT NULL DEFAULT 0 CHECK (unresolved_minor >= 0),

    started_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    completed_at      timestamptz,
    failure_reason    text,

    CONSTRAINT reconciliation_runs_completion_shape CHECK (
        (state IN ('running')) = (completed_at IS NULL)),
    -- reconciliation_runs_reconciled_saw_the_file is in the "load-bearing rules"
    -- block below: a day whose file never arrived is not reconciled, however clean
    -- the comparison over nothing looked.
    CONSTRAINT reconciliation_runs_dates_known CHECK (as_of_date IS NOT NULL)
);

COMMENT ON TABLE reconciliation_runs IS
    'ADR-0012 §8. One provider-day. `reconciled` is earned by a trigger, not claimed by the job.';

-- One run per provider-day. Re-running a day updates it, so a day cannot end up
-- with a reconciled row and an incomplete one and no way to tell which is current.
CREATE UNIQUE INDEX IF NOT EXISTS reconciliation_runs_day_idx
    ON reconciliation_runs (provider, as_of_date);
-- The watchdog's question: which days have not reached an ending. Including
-- 'running', because a run that died leaves one and it must be indistinguishable
-- from a day that never ran.
CREATE INDEX IF NOT EXISTS reconciliation_runs_open_idx
    ON reconciliation_runs (provider, as_of_date)
    WHERE state IN ('running', 'incomplete', 'failed');

-- The counters are computed here, not accepted from the caller, and 'reconciled'
-- is refused while anything is open.
--
-- This is the acceptance criterion made structural. The job that reconciles a day
-- is the same job that would report it clean, so its own report is not evidence.
-- What is evidence is the drift table, and the database is what reads it.
--
-- late_settlement is excluded: the money arrived, and a day whose only fault was
-- slowness is reconciled.
CREATE OR REPLACE FUNCTION reconciliation_run_counters() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    open_count int;
    open_minor bigint;
BEGIN
    SELECT count(*), coalesce(sum(amount_minor), 0)
      INTO open_count, open_minor
      FROM settlement_drift d
     WHERE d.provider = NEW.provider
       AND d.as_of_date <= NEW.as_of_date
       AND d.state = 'open'
       AND d.drift_kind <> 'late_settlement';

    NEW.unresolved_count := open_count;
    NEW.unresolved_minor := open_minor;
    NEW.updated_at := now();

    IF NEW.state = 'reconciled' AND open_count > 0 THEN
        RAISE EXCEPTION 'reconciliation of % for % cannot be called reconciled: % open drift item(s) '
                        'worth % remain — a day that quietly becomes reconciled because nobody looked '
                        'is how money goes missing',
            NEW.provider, NEW.as_of_date, open_count, open_minor
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION reconciliation_run_counters() IS
    'ADR-0012 §8. The run''s unresolved counters are computed from settlement_drift, and `reconciled` is refused while anything is open.';

DROP TRIGGER IF EXISTS reconciliation_runs_counters ON reconciliation_runs;
CREATE TRIGGER reconciliation_runs_counters
    BEFORE INSERT OR UPDATE ON reconciliation_runs
    FOR EACH ROW EXECUTE FUNCTION reconciliation_run_counters();

ALTER TABLE settlement_batches   ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_batches   FORCE  ROW LEVEL SECURITY;
ALTER TABLE settlement_lines     ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_lines     FORCE  ROW LEVEL SECURITY;
ALTER TABLE settlement_drift     ENABLE ROW LEVEL SECURITY;
ALTER TABLE settlement_drift     FORCE  ROW LEVEL SECURITY;
ALTER TABLE reconciliation_runs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE reconciliation_runs  FORCE  ROW LEVEL SECURITY;

-- A batch is one payout from one aggregator account and its totals are every
-- organisation's collections added together. There is no version of it that
-- belongs to a tenant, so no tenant sees it — not even the one whose money is in
-- it. What an owner is shown is their own payments and their own drift.
DROP POLICY IF EXISTS settlement_batches_platform_only ON settlement_batches;
CREATE POLICY settlement_batches_platform_only ON settlement_batches
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Read what is yours once it has been attributed; write nothing. Ingestion runs
-- before it knows whose money a line is, so it cannot run in a tenant-scoped
-- session — the same consequence ADR-0011 §5 recorded for the webhook inbox, and
-- for the same reason.
DROP POLICY IF EXISTS settlement_lines_tenant_isolation ON settlement_lines;
CREATE POLICY settlement_lines_tenant_isolation ON settlement_lines
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

-- Drift is read by the organisation it concerns — an owner asking where their
-- rent is has a right to the answer — and resolved only by the platform. The
-- clearing account spans organisations, so a resolution decided inside one of
-- them would be a decision about somebody else's money.
DROP POLICY IF EXISTS settlement_drift_tenant_isolation ON settlement_drift;
CREATE POLICY settlement_drift_tenant_isolation ON settlement_drift
    USING (is_platform_session()
           OR (tenant_id IS NOT NULL AND tenant_id = current_tenant_id()))
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS reconciliation_runs_platform_only ON reconciliation_runs;
CREATE POLICY reconciliation_runs_platform_only ON reconciliation_runs
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- Nothing here may be deleted. A settlement file that was ingested and a
-- disagreement that was found are the evidence in the dispute that comes later,
-- and a drift row somebody deleted is indistinguishable from a drift row that was
-- never found. A run is kept for the same reason the watchdog exists.
DROP POLICY IF EXISTS settlement_batches_no_delete ON settlement_batches;
CREATE POLICY settlement_batches_no_delete ON settlement_batches AS RESTRICTIVE FOR DELETE USING (false);
DROP POLICY IF EXISTS settlement_lines_no_delete ON settlement_lines;
CREATE POLICY settlement_lines_no_delete ON settlement_lines AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS settlement_drift_no_delete ON settlement_drift;
CREATE POLICY settlement_drift_no_delete ON settlement_drift AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS reconciliation_runs_no_delete ON reconciliation_runs;
CREATE POLICY reconciliation_runs_no_delete ON reconciliation_runs AS RESTRICTIVE FOR DELETE USING (false);

-- A batch is immutable once ingested: its totals are the provider's statement,
-- and a statement that can be edited is not one. The lines are mutable, because
-- matching writes to them, and the runs are mutable because a day is re-run.
DROP POLICY IF EXISTS settlement_batches_no_update ON settlement_batches;
CREATE POLICY settlement_batches_no_update ON settlement_batches AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON settlement_batches TO dwellm8_money;
GRANT SELECT, INSERT, UPDATE ON settlement_lines, settlement_drift,
    reconciliation_runs TO dwellm8_money;
GRANT SELECT ON settlement_drift_ageing TO dwellm8_money;
GRANT EXECUTE ON FUNCTION settlement_age_bucket(interval) TO dwellm8_app;
-- An owner's statement shows what has not settled, so the lease and property
-- modules read drift. Neither writes it.
GRANT SELECT ON settlement_drift TO dwellm8_lease, dwellm8_property;

