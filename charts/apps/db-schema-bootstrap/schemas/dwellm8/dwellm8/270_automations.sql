-- ===========================================================================
-- prebuilt automations (ADR-0033)
-- ===========================================================================

-- The routine sequences a manager does by hand: chase arrears, remind about an
-- expiry, schedule an inspection, run a move-out.
--
--   automation_settings   what an organisation changed. Nothing else.
--   automation_runs       what an automation did, to what, and when
--   automation_approvals  what it wanted to do and was not allowed to
--
-- The first table is the one worth reading twice. **A row here is an override.**
-- The catalogue lives in Go and an organisation with no rows gets every automation
-- with its default parameters — which is ADR-0033 §1's "no configuration", obtained
-- by resolving absence rather than by a seeding step somebody will one day miss.
-- An organisation with nothing chasing its arrears looks exactly like one whose
-- tenants all pay on time, so the failure mode of seeding is silence.

CREATE TABLE IF NOT EXISTS automation_settings (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    -- The catalogue key, e.g. 'arrears_ladder'. Deliberately not a foreign key:
    -- the catalogue is code, and a row naming an automation a later release
    -- removed must not stop this table loading. The engine ignores what it does
    -- not recognise and says so in the run log.
    automation    text NOT NULL CHECK (automation ~ '^[a-z][a-z0-9_]{2,63}$'),

    -- NULL means "the catalogue's answer". Only a deliberate switch writes false.
    enabled       boolean,
    -- Parameter overrides, by name. Validated in Go against the catalogue's
    -- declared parameters, because the schema cannot know what a parameter means
    -- and a jsonb CHECK that tried would be a second, worse copy of the catalogue.
    params        jsonb NOT NULL DEFAULT '{}'::jsonb,

    -- The ceiling above which this automation asks instead of acting. ADR-0007:
    -- money is an integer of minor units, here as everywhere.
    approval_ceiling_minor bigint CHECK (approval_ceiling_minor >= 0),

    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,

    CONSTRAINT automation_settings_params_is_object CHECK (jsonb_typeof(params) = 'object'),
    CONSTRAINT automation_settings_amount_representable CHECK (
        approval_ceiling_minor IS NULL OR approval_ceiling_minor <= 9007199254740991),
    -- One row per automation per organisation. Two would each claim to be the
    -- override and the resolution would depend on which was read first.
    CONSTRAINT automation_settings_one_per_automation UNIQUE (tenant_id, automation),
    CONSTRAINT automation_settings_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE automation_settings IS
    'ADR-0033 §1. Overrides only. An organisation with no rows runs every automation on the catalogue''s defaults.';
COMMENT ON COLUMN automation_settings.enabled IS
    'NULL means the catalogue decides. Only a deliberate switch writes false.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'automation_settings_one_per_automation') THEN
        ALTER TABLE automation_settings ADD CONSTRAINT automation_settings_one_per_automation
            UNIQUE (tenant_id, automation);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'automation_settings_tenant_id_unique') THEN
        ALTER TABLE automation_settings ADD CONSTRAINT automation_settings_tenant_id_unique
            UNIQUE (id, tenant_id);
    END IF;
END $$;

-- What an automation did, to what, and when. ADR-0033 §4.
--
-- This is the provenance the story asks for: "a record must show which automation
-- caused an action and when" is answered by reading this table for a subject,
-- rather than by widening the outbox's actor vocabulary — which would say that an
-- automation acted and never say which one.
--
-- It is also the idempotency ledger. A CronJob that overruns is a CronJob that
-- runs twice (ADR-0028), and `idempotency_key` is what makes the second run a
-- no-op rather than a second reminder on the same Sunday.
CREATE TABLE IF NOT EXISTS automation_runs (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    automation    text NOT NULL,

    -- What it acted on. Polymorphic on purpose — a run is about a lease, a unit, a
    -- property or a statutory rule depending on the automation — so it is not a
    -- foreign key, and subject_kind is closed so it cannot become one by accident.
    subject_kind  text NOT NULL CHECK (subject_kind IN (
                      'lease', 'unit', 'property', 'organisation', 'checklist', 'statutory_rule')),
    subject_id    uuid NOT NULL,

    -- What it did. 'skipped' is a first-class outcome: an automation that
    -- considered a tenancy and decided against it is a fact somebody will ask
    -- about, and the reason is beside it.
    outcome       text NOT NULL CHECK (outcome IN ('acted', 'skipped', 'awaiting_approval', 'failed')),
    action        text NOT NULL,
    detail        text,

    -- The parameters this run resolved to, so "why did it fire on day 3" is
    -- answerable from the row rather than from the release that was deployed then.
    params        jsonb NOT NULL DEFAULT '{}'::jsonb,
    amount_minor  bigint CHECK (amount_minor >= 0),

    -- One proposal, one row. The engine derives this from the automation, the
    -- subject and whatever makes the proposal distinct — usually the step of a
    -- ladder or the period it is about.
    idempotency_key text NOT NULL,

    occurred_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT automation_runs_params_is_object CHECK (jsonb_typeof(params) = 'object'),
    CONSTRAINT automation_runs_amount_representable CHECK (
        amount_minor IS NULL OR amount_minor <= 9007199254740991),
    CONSTRAINT automation_runs_failure_says_why CHECK (
        outcome <> 'failed' OR detail IS NOT NULL),
    CONSTRAINT automation_runs_idempotent UNIQUE (tenant_id, automation, idempotency_key)
);

COMMENT ON TABLE automation_runs IS
    'ADR-0033 §4. Which automation acted, on what, with which parameters. Also the idempotency ledger for a CronJob that runs twice.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'automation_runs_idempotent') THEN
        ALTER TABLE automation_runs ADD CONSTRAINT automation_runs_idempotent
            UNIQUE (tenant_id, automation, idempotency_key);
    END IF;
END $$;

-- "What has been automated on this tenancy", which is the read a record screen
-- makes, and the only read that has to be fast.
CREATE INDEX IF NOT EXISTS automation_runs_subject_idx
    ON automation_runs (tenant_id, subject_kind, subject_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS automation_runs_recent_idx
    ON automation_runs (tenant_id, occurred_at DESC);

-- A run is history. Editing one would make the provenance trail worth nothing,
-- and the whole reason the trail exists is that somebody disputes what happened.
CREATE OR REPLACE FUNCTION automation_runs_are_history() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    RAISE EXCEPTION 'automation run % may not be edited: it is the record of what was done, '
                    'and a record that can be rewritten answers nothing', OLD.id
        USING ERRCODE = 'check_violation';
END
$$;

DROP TRIGGER IF EXISTS automation_runs_immutable ON automation_runs;
CREATE TRIGGER automation_runs_immutable
    BEFORE UPDATE ON automation_runs
    FOR EACH ROW EXECUTE FUNCTION automation_runs_are_history();

-- The story's failure scenario, as a row. ADR-0033 §3.
--
-- An automation that would act beyond the ceiling stops and asks. It asks here,
-- naming the ceiling it hit, because an automation that stops and says nothing is
-- indistinguishable from one that is switched off — which is the failure this
-- table exists to prevent rather than the behaviour it implements.
CREATE TABLE IF NOT EXISTS automation_approvals (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    automation    text NOT NULL,

    subject_kind  text NOT NULL CHECK (subject_kind IN (
                      'lease', 'unit', 'property', 'organisation', 'checklist', 'statutory_rule')),
    subject_id    uuid NOT NULL,

    action        text NOT NULL,
    -- What it wanted to do, and the ceiling that stopped it. Both, because "over
    -- the limit" without the limit is not something anybody can act on.
    amount_minor  bigint NOT NULL CHECK (amount_minor >= 0),
    ceiling_minor bigint NOT NULL CHECK (ceiling_minor >= 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),

    state         text NOT NULL DEFAULT 'pending'
                  CHECK (state IN ('pending', 'approved', 'declined', 'expired')),
    decided_at    timestamptz,
    decided_by    uuid,
    decided_reason text,

    requested_at  timestamptz NOT NULL DEFAULT now(),
    idempotency_key text NOT NULL,

    CONSTRAINT automation_approvals_over_the_ceiling CHECK (amount_minor > ceiling_minor),
    CONSTRAINT automation_approvals_amount_representable CHECK (amount_minor <= 9007199254740991),
    CONSTRAINT automation_approvals_decision_shape CHECK (
        state = 'pending' OR decided_at IS NOT NULL),
    -- A decision that refuses says why. An approval need not: agreeing with a
    -- request the row already describes adds nothing.
    CONSTRAINT automation_approvals_decline_says_why CHECK (
        state <> 'declined' OR decided_reason IS NOT NULL),
    -- One request per proposal. A run that asks twice is a manager with two
    -- identical approvals and no idea whether granting one is enough.
    CONSTRAINT automation_approvals_idempotent UNIQUE (tenant_id, automation, idempotency_key)
);

COMMENT ON TABLE automation_approvals IS
    'ADR-0033 §3. What an automation wanted to do beyond its ceiling. Pending until somebody decides, and nothing was performed.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'automation_approvals_idempotent') THEN
        ALTER TABLE automation_approvals ADD CONSTRAINT automation_approvals_idempotent
            UNIQUE (tenant_id, automation, idempotency_key);
    END IF;
END $$;

CREATE INDEX IF NOT EXISTS automation_approvals_pending_idx
    ON automation_approvals (tenant_id, requested_at) WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS automation_approvals_subject_idx
    ON automation_approvals (tenant_id, subject_kind, subject_id);

-- A decision is made once. Re-deciding an approval after the automation acted on
-- it would leave the action and change the record of why it was permitted.
CREATE OR REPLACE FUNCTION automation_approvals_decided_once() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF OLD.state <> 'pending' AND NEW.state IS DISTINCT FROM OLD.state THEN
        RAISE EXCEPTION 'approval % was already %', OLD.id, OLD.state
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.state <> OLD.state AND NEW.decided_at IS NULL THEN
        NEW.decided_at := now();
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS automation_approvals_once ON automation_approvals;
CREATE TRIGGER automation_approvals_once
    BEFORE UPDATE ON automation_approvals
    FOR EACH ROW EXECUTE FUNCTION automation_approvals_decided_once();

-- ---------------------------------------------------------------------------
-- what a screen reads
-- ---------------------------------------------------------------------------
--
-- security_invoker, as assertion 10 requires of every view here.

-- The last thing each automation did, per organisation — the settings screen's
-- "this is running" line, which is what turns a toggle into something a manager
-- can believe.
CREATE OR REPLACE VIEW automation_activity
    WITH (security_invoker = true) AS
    SELECT r.tenant_id,
           r.automation,
           count(*)                                                  AS runs,
           count(*) FILTER (WHERE r.outcome = 'acted')               AS acted,
           count(*) FILTER (WHERE r.outcome = 'awaiting_approval')   AS awaiting_approval,
           count(*) FILTER (WHERE r.outcome = 'failed')              AS failed,
           max(r.occurred_at)                                        AS last_run_at,
           max(r.occurred_at) FILTER (WHERE r.outcome = 'acted')     AS last_acted_at
      FROM automation_runs r
     GROUP BY r.tenant_id, r.automation;

COMMENT ON VIEW automation_activity IS
    'ADR-0033. Per-automation activity, derived. What the settings screen shows beside each switch.';

ALTER TABLE automation_settings  ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_settings  FORCE  ROW LEVEL SECURITY;
ALTER TABLE automation_runs      ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_runs      FORCE  ROW LEVEL SECURITY;
ALTER TABLE automation_approvals ENABLE ROW LEVEL SECURITY;
ALTER TABLE automation_approvals FORCE  ROW LEVEL SECURITY;

-- No delegated branch on any of the three, and that is the decision rather than
-- an omission: a management firm operates an owner's property under ADR-0005, and
-- which automations the owner's organisation runs is the owner's configuration,
-- not part of the mandate. A firm that should be able to change them is a firm
-- whose staff hold a role in that organisation.
DROP POLICY IF EXISTS automation_settings_tenant_isolation ON automation_settings;
CREATE POLICY automation_settings_tenant_isolation ON automation_settings
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS automation_runs_tenant_isolation ON automation_runs;
CREATE POLICY automation_runs_tenant_isolation ON automation_runs
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS automation_approvals_tenant_isolation ON automation_approvals;
CREATE POLICY automation_approvals_tenant_isolation ON automation_approvals
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS automation_settings_no_delete ON automation_settings;
CREATE POLICY automation_settings_no_delete ON automation_settings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
-- A run and an approval are evidence. "Why did this tenant get a message on a
-- Sunday" has one answer and it is these rows.
DROP POLICY IF EXISTS automation_runs_no_delete ON automation_runs;
CREATE POLICY automation_runs_no_delete ON automation_runs AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS automation_approvals_no_delete ON automation_approvals;
CREATE POLICY automation_approvals_no_delete ON automation_approvals AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- ADR-0029, written here rather than left to the generator in 220 for the reason
-- given in 250: that file runs before this one, so on a fresh database these
-- tables would stand open to a renter session until the next replay. The names
-- match the generator's, so its DROP-and-CREATE replaces these with identical
-- policies rather than adding a second copy.
DROP POLICY IF EXISTS automation_settings_resident_denied ON automation_settings;
CREATE POLICY automation_settings_resident_denied ON automation_settings AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
DROP POLICY IF EXISTS automation_runs_resident_denied ON automation_runs;
CREATE POLICY automation_runs_resident_denied ON automation_runs AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
DROP POLICY IF EXISTS automation_approvals_resident_denied ON automation_approvals;
CREATE POLICY automation_approvals_resident_denied ON automation_approvals AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- ---------------------------------------------------------------------------
-- privileges
-- ---------------------------------------------------------------------------
--
-- The engine is platform machinery (ADR-0033 §2), like the outbox and the
-- workflow tables, so the privileges are held by the application role rather than
-- by a module's. Every module's automations write through the one engine.
GRANT SELECT, INSERT, UPDATE ON automation_settings, automation_approvals TO dwellm8_app;
-- A run is written and read and never updated: the trigger above refuses it, and
-- withholding the privilege means a session never reaches the trigger.
GRANT SELECT, INSERT ON automation_runs TO dwellm8_app;
REVOKE UPDATE ON automation_runs FROM dwellm8_app;
GRANT SELECT ON automation_activity TO dwellm8_app;

-- Created after 180's blanket grant, so they arrive with DELETE from the default
-- privileges. Two locks, as everywhere else.
REVOKE DELETE ON automation_settings, automation_runs, automation_approvals FROM dwellm8_app;
GRANT DELETE ON automation_settings, automation_runs, automation_approvals TO dwellm8_purge;
REVOKE INSERT, UPDATE, DELETE ON automation_activity FROM dwellm8_app;
