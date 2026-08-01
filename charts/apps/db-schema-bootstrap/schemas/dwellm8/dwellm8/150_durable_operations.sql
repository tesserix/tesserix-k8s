-- ===========================================================================
-- durable operations (ADR-0015)
-- ===========================================================================

-- Temporal is the executor. These tables are the record, and the distinction is
-- the whole of ADR-0015 §7.
--
-- A Temporal namespace keeps history for days — HomeChef's is 168 hours — and a
-- support call about a payout from last month has to have something to look at.
-- More than that: a workflow's history is a log of activity results, not an
-- account of what happened to somebody's money. So every durable operation records
-- its own progress here, in tables that outlive the namespace's retention and can
-- be read by the organisation whose money it is.
--
--   workflow_runs   one durable operation, and where it got to
--   workflow_steps  its steps and compensations, with the idempotency key each used
--
-- Both are ordinary tenant-scoped tables under ADR-0003, not platform-owned like
-- ADR-0012's. A platform-wide operation — the nightly reconciliation — carries the
-- platform organisation, exactly as ADR-0002 §1 requires of a platform-level event.
-- That keeps tenant_id NOT NULL and keeps these two off assertion 12's list, where
-- they would have needed the nullable-tenant argument for no benefit.

-- The platform organisation that a platform-wide run belongs to is seeded in the
-- data-migrations section, not here: it is a row, and a row written by this file
-- needs the row-level security window that section exists for.

CREATE TABLE IF NOT EXISTS workflow_runs (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),

    -- The operation, from the list ADR-0015 §2 derives from its rule. Not a CHECK
    -- against a fixed set: the list lives in Go, where each entry carries the
    -- clause of the rule that put it there, and the store contract test compares
    -- the two. A CHECK here would be a third copy.
    operation      text NOT NULL,
    task_queue     text NOT NULL,

    -- The deterministic Temporal id, `dwellm8:<operation>:<subject>`. UNIQUE, and
    -- that is the same guarantee ADR-0011 §2 gets from an index: starting the same
    -- operation for the same subject twice collides rather than producing a second
    -- workflow. A support agent constructs this from a payout id rather than
    -- searching for it, which is why it is derived and not generated.
    workflow_id    text NOT NULL,
    -- Temporal's own run id, for the operator who does have namespace access. It
    -- changes on a continue-as-new, so it is recorded and never relied on.
    temporal_run_id text,

    subject_kind   text NOT NULL,
    subject_id     text NOT NULL,
    -- ADR-0002's chain, so a support call can walk from a tenant's tap to the
    -- owner's payout.
    correlation_id text,

    state          text NOT NULL DEFAULT 'running' CHECK (state IN (
                       'running', 'completed', 'compensating', 'compensated', 'escalated')),

    -- ADR-0015 §4, made structural. Once the irreversible step has begun this is
    -- true forever, and the constraint below is what the flag is for.
    past_no_return boolean NOT NULL DEFAULT false,

    -- Where it got to, for the support call. The step name, not a percentage.
    last_step      text,
    failed_step    text,
    failure_reason text,

    -- Escalation is not failure: it is a run waiting for a person. It carries a
    -- reason for the same purpose ADR-0012's drift resolution does — a row somebody
    -- closed is not a row somebody explained.
    escalated_at     timestamptz,
    escalation_reason text,

    started_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    completed_at   timestamptz,

    -- workflow_runs_compensated_means_reversible — a run that passed the point of no
    -- return cannot have been compensated — is in the "load-bearing rules" block
    -- below, where it reaches a database that already has this table.
    CONSTRAINT workflow_runs_escalation_shape CHECK (
        (state = 'escalated') = (escalated_at IS NOT NULL)
        AND (state = 'escalated') = (escalation_reason IS NOT NULL)),
    CONSTRAINT workflow_runs_completion_shape CHECK (
        (state IN ('running', 'compensating')) = (completed_at IS NULL))
);

COMMENT ON TABLE workflow_runs IS
    'ADR-0015 §7. One durable operation. Temporal is the executor; this is the record, because a namespace keeps history for days and a dispute lasts longer.';
COMMENT ON COLUMN workflow_runs.past_no_return IS
    'True once the irreversible step has begun. A run with this set may not be recorded as compensated — nothing after that point can be undone.';

-- The idempotency of starting. A producer-side retry — a double-tapped button, a
-- redelivered event, a replayed queue — finds this row rather than making a second.
CREATE UNIQUE INDEX IF NOT EXISTS workflow_runs_workflow_idx
    ON workflow_runs (workflow_id);
-- "What is this payout doing" — the support call, from the subject rather than the
-- workflow id.
CREATE INDEX IF NOT EXISTS workflow_runs_subject_idx
    ON workflow_runs (tenant_id, subject_kind, subject_id);
-- "What needs a person" — the escalation queue, and the only screen in this
-- subsystem somebody is meant to be looking at.
CREATE INDEX IF NOT EXISTS workflow_runs_escalated_idx
    ON workflow_runs (operation, escalated_at) WHERE state = 'escalated';
-- "What is still in flight, and since when" — the stuck-workflow sweep. A run that
-- has been running longer than its operation's budget is the edge case ADR-0015's
-- story names, and this is the index that finds it.
CREATE INDEX IF NOT EXISTS workflow_runs_inflight_idx
    ON workflow_runs (operation, started_at) WHERE state IN ('running', 'compensating');
CREATE INDEX IF NOT EXISTS workflow_runs_correlation_idx
    ON workflow_runs (correlation_id) WHERE correlation_id IS NOT NULL;

-- The state machine, in the schema as well as in Go, for the reason ADR-0011 §3
-- gives: an out-of-order update must be refused even on a path that never went
-- through Go, and the contract test evaluates this function over every ordered
-- pair.
--
-- from = to is permitted and is the point: a step recorded twice asks for the state
-- the run is already in.
CREATE OR REPLACE FUNCTION workflow_transition_allowed(from_state text, to_state text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_state = to_state
        OR (from_state, to_state) IN (
            ('running',      'completed'),
            ('running',      'compensating'),
            -- Straight to escalated: a step that failed after the point of no
            -- return never compensates, so it never passes through compensating.
            ('running',      'escalated'),
            ('compensating', 'compensated'),
            -- A compensation that could not be applied. The worst state in the
            -- system, and the only one that pages somebody.
            ('compensating', 'escalated'))
$$;

COMMENT ON FUNCTION workflow_transition_allowed(text, text) IS
    'ADR-0015 §5. Forward-only. Terminal states absorb, and from = to is a permitted no-op so a step recorded twice needs no special case.';

CREATE OR REPLACE FUNCTION workflow_runs_forward_only() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT workflow_transition_allowed(OLD.state, NEW.state) THEN
        RAISE EXCEPTION 'workflow run % cannot go from % to %',
            OLD.workflow_id, OLD.state, NEW.state USING ERRCODE = 'check_violation';
    END IF;
    -- Monotonic. A run that has passed the point of no return has passed it
    -- forever, and clearing the flag would let the constraint above be satisfied
    -- by editing the evidence rather than by the world being reversible.
    IF OLD.past_no_return AND NOT NEW.past_no_return THEN
        RAISE EXCEPTION 'workflow run % cannot un-pass the point of no return: the irreversible step '
                        'either began or it did not', OLD.workflow_id
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS workflow_runs_forward ON workflow_runs;
CREATE TRIGGER workflow_runs_forward
    BEFORE UPDATE ON workflow_runs
    FOR EACH ROW EXECUTE FUNCTION workflow_runs_forward_only();

-- One row per step per direction, carrying the idempotency key it presented.
--
-- This is the trail that answers "was the tenant charged twice" after the Temporal
-- history has expired. The key is stored rather than recomputed because the answer
-- has to be what was actually sent, not what today's code would send.
CREATE TABLE IF NOT EXISTS workflow_steps (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id          uuid NOT NULL REFERENCES workflow_runs(id),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),

    seq             int  NOT NULL CHECK (seq >= 0),
    step            text NOT NULL,
    -- 'do' or 'undo'. A step and its compensation are two rows, so the trail reads
    -- as what happened rather than as a final state.
    direction       text NOT NULL CHECK (direction IN ('do', 'undo')),

    idempotency_key text NOT NULL,
    outcome         text NOT NULL DEFAULT 'running'
                    CHECK (outcome IN ('running', 'succeeded', 'failed')),
    -- Attempts, because "it eventually worked" and "it worked first time" are
    -- different facts about a provider, and only one of them is worth an alert.
    attempts        int  NOT NULL DEFAULT 1 CHECK (attempts >= 1),
    error           text,

    started_at      timestamptz NOT NULL DEFAULT now(),
    finished_at     timestamptz,

    CONSTRAINT workflow_steps_outcome_shape CHECK (
        (outcome = 'running') = (finished_at IS NULL)),
    CONSTRAINT workflow_steps_error_shape CHECK (
        outcome = 'failed' OR error IS NULL)
);

COMMENT ON TABLE workflow_steps IS
    'ADR-0015 §7. Each step and compensation, with the idempotency key it presented. Outlives Temporal''s retention, which is what a dispute needs.';

-- A retry updates its row rather than adding one. Without this, an activity retried
-- forty times over a day reads as forty steps and the trail becomes unreadable
-- exactly when somebody needs it.
CREATE UNIQUE INDEX IF NOT EXISTS workflow_steps_unique
    ON workflow_steps (run_id, step, direction);
CREATE INDEX IF NOT EXISTS workflow_steps_run_idx
    ON workflow_steps (run_id, seq);
-- "Which step presented this key" — the question a provider's support desk asks.
CREATE INDEX IF NOT EXISTS workflow_steps_key_idx
    ON workflow_steps (idempotency_key);

ALTER TABLE workflow_runs  ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_runs  FORCE  ROW LEVEL SECURITY;
ALTER TABLE workflow_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_steps FORCE  ROW LEVEL SECURITY;

-- Ordinary ADR-0003 isolation, with no delegated branch.
--
-- The omission is deliberate and is worth stating: a run carries no property_id, so
-- there is nothing for is_delegated_unit() to be judged against, and adding a
-- grant-level branch would hand a management firm every durable operation of the
-- owner that granted it — including payouts to that owner's bank account, which is
-- not the firm's business. A firm sees the payments and the drift for the units it
-- manages; how the money was moved is between the owner and the platform.
DROP POLICY IF EXISTS workflow_runs_tenant_isolation ON workflow_runs;
CREATE POLICY workflow_runs_tenant_isolation ON workflow_runs
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS workflow_steps_tenant_isolation ON workflow_steps;
CREATE POLICY workflow_steps_tenant_isolation ON workflow_steps
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A run that escalated and a step that failed are the
-- evidence in the dispute that follows, and the reason this record exists rather
-- than relying on Temporal's is precisely that it has to survive.
DROP POLICY IF EXISTS workflow_runs_no_delete ON workflow_runs;
CREATE POLICY workflow_runs_no_delete ON workflow_runs AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS workflow_steps_no_delete ON workflow_steps;
CREATE POLICY workflow_steps_no_delete ON workflow_steps AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- Money owns durable operations, because every operation on the list is a money or
-- document operation. Every other module reads: a lease screen shows whether the
-- deposit refund is in flight, and a support console shows why it is not.
GRANT SELECT, INSERT, UPDATE ON workflow_runs, workflow_steps TO dwellm8_money;
GRANT SELECT ON workflow_runs, workflow_steps TO dwellm8_lease, dwellm8_property,
    dwellm8_identity, dwellm8_notify;

