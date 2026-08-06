-- ===========================================================================
-- period close (#190)
-- ===========================================================================
-- Without a close, last month's figures can move after an owner has been sent
-- a statement. The close is a fact, not a flag: an append-only row per action,
-- so "who closed March, and who reopened it and why" is a query, never a
-- reconstruction. The current state of a month is its latest row.
CREATE TABLE IF NOT EXISTS ledger_period_closes (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    -- The month, as its first day. Monthly on purpose — rent runs monthly, and
    -- a quarterly close is three monthly ones.
    period_month  date NOT NULL CHECK (period_month = date_trunc('month', period_month)::date),
    action        text NOT NULL CHECK (action IN ('closed', 'reopened')),
    -- The session's principal, a label until #229 lands party uuids — the same
    -- trade the outbox actors and activity notes make.
    actor         text NOT NULL CHECK (btrim(actor) <> ''),
    -- A close can say "month-end close"; a reopen is rare and audited, so its
    -- reason has to say something a reviewer can weigh.
    reason        text NOT NULL CHECK (btrim(reason) <> ''),
    acted_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ledger_period_closes_reopen_reason CHECK (
        action <> 'reopened' OR length(btrim(reason)) >= 8)
);

CREATE INDEX IF NOT EXISTS ledger_period_closes_month_idx
    ON ledger_period_closes (tenant_id, period_month, acted_at DESC);

ALTER TABLE ledger_period_closes ENABLE ROW LEVEL SECURITY;
ALTER TABLE ledger_period_closes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS ledger_period_closes_tenant_isolation ON ledger_period_closes;
CREATE POLICY ledger_period_closes_tenant_isolation ON ledger_period_closes
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());
-- The close history is audit: append-only, like the ledger it protects.
DROP POLICY IF EXISTS ledger_period_closes_no_delete ON ledger_period_closes;
CREATE POLICY ledger_period_closes_no_delete ON ledger_period_closes AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS ledger_period_closes_no_update ON ledger_period_closes;
CREATE POLICY ledger_period_closes_no_update ON ledger_period_closes AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON ledger_period_closes TO dwellm8_money;

-- Whether a date falls in a closed month. Not SECURITY DEFINER — it reads
-- under the caller's own row-level security, like is_delegated() and
-- payout_account_payable(), and for the same reason.
CREATE OR REPLACE FUNCTION ledger_period_is_closed(p_tenant uuid, p_on date)
RETURNS boolean LANGUAGE sql STABLE AS $fn$
    SELECT coalesce((
        SELECT c.action = 'closed'
          FROM ledger_period_closes c
         WHERE c.tenant_id = p_tenant
           AND c.period_month = date_trunc('month', p_on)::date
         ORDER BY c.acted_at DESC, c.id DESC
         LIMIT 1), false)
$fn$;
COMMENT ON FUNCTION ledger_period_is_closed(uuid, date) IS
    'The latest close/reopen row decides. Used by the journal-entry guard; callable by anything pricing a backdated posting (#190).';
GRANT EXECUTE ON FUNCTION ledger_period_is_closed(uuid, date) TO dwellm8_money, dwellm8_app;

-- The enforcement. In the database rather than in the store, because the store
-- is one of several writers (the API, the settlement consumer, the jobs
-- binary) and a rule enforced in Go is enforced in the copies of Go that
-- remembered. The correction path stays open by construction: a reversal or
-- adjustment is a new entry dated today, and today is not in a closed month.
CREATE OR REPLACE FUNCTION ledger_period_guard() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
    IF ledger_period_is_closed(NEW.tenant_id, NEW.occurred_on) THEN
        RAISE EXCEPTION 'ledger: % falls in a closed period', NEW.occurred_on
            USING ERRCODE = 'raise_exception',
                  HINT = 'post a current-period adjustment referencing the original entry (reversal reason wrong_period), or reopen the period with a reason (#190)';
    END IF;
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS journal_entries_period_guard ON journal_entries;
CREATE TRIGGER journal_entries_period_guard
    BEFORE INSERT ON journal_entries
    FOR EACH ROW EXECUTE FUNCTION ledger_period_guard();

-- ADR-0029. The close is the landlord's book-keeping; a renter has no business
-- knowing which months their landlord has locked.
DROP POLICY IF EXISTS ledger_period_closes_resident_denied ON ledger_period_closes;
CREATE POLICY ledger_period_closes_resident_denied ON ledger_period_closes AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
