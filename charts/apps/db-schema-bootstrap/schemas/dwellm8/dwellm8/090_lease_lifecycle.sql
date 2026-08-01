-- ===========================================================================
-- lease lifecycle (ADR-0010)
-- ===========================================================================

-- The lease is the object every other module hangs off, so its states are fixed here
-- before invoicing, documents or move-out are built.
--
--   leases         the tenancy, its agreed term and its state
--   lease_parties  who is on it, effective-dated (a tenant joins or leaves mid-term)
--   rent_schedule  what is owed, effective-dated (ADR-0008's own example)
--
-- All three are on ADR-0008's pattern, and assertion 14 policed rent_schedule before
-- this section existed — it is column-driven, so it found the table by its valid_from
-- rather than by anybody adding it to a list.
--
-- The agreed term and the actual end are different facts. `valid_from`/`valid_to` are
-- what the parties signed and never change; `ended_on` is the date occupancy actually
-- ceased. `validity` is the intersection, and it is what money and the no-double-let
-- constraint are computed over — so terminating early stops the billing by shortening
-- an interval rather than by setting a flag something has to remember to check.

CREATE TABLE IF NOT EXISTS leases (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    unit_parent_id uuid,

    state         text NOT NULL DEFAULT 'draft' CHECK (state IN (
                      'draft', 'pending_signature', 'active', 'in_notice',
                      'renewed', 'terminated', 'settled', 'lapsed')),

    -- The agreed term. NULL valid_to is a periodic tenancy with no agreed end.
    valid_from    date NOT NULL,
    valid_to      date,
    -- The date occupancy actually ceased, exclusive. NULL while running or if it ran
    -- to term. LEAST ignores NULLs, so the generated range below is: unbounded when
    -- both are NULL, whichever exists when one is, and the earlier when both are.
    ended_on      date,
    validity      daterange GENERATED ALWAYS AS
                  (daterange(valid_from, LEAST(valid_to, ended_on), '[)')) STORED,

    notice_days   int NOT NULL DEFAULT 30 CHECK (notice_days >= 0),
    lock_in_until date,

    -- Renewal is a new lease that names its predecessor, never a mutated row: the
    -- ledger history a tenancy accumulates hangs off the lease id, so mutating the row
    -- would silently re-attribute two years of postings to a different set of terms.
    renews_lease_id uuid REFERENCES leases(id),

    -- Termination, and the decision the story's failure scenario requires.
    terminated_by     text CHECK (terminated_by IN ('owner', 'tenant', 'system', 'platform')),
    terminated_reason text,
    settlement_decision text CHECK (settlement_decision IN ('none', 'adjust', 'refund', 'forfeit')),
    -- The only transition in the machine that goes backwards, so the only one that has
    -- to say why. ADR-0010 §3.
    notice_withdrawn_reason text,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT leases_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT leases_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT leases_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT leases_term CHECK (valid_to IS NULL OR valid_to > valid_from),
    -- A tenancy cannot cease before it began, and ceasing after the agreement ran out
    -- is the agreement running out rather than a termination.
    CONSTRAINT leases_ended_within_term CHECK (
        ended_on IS NULL
        OR (ended_on > valid_from AND (valid_to IS NULL OR ended_on <= valid_to))),
    -- A lock-in that outlasts the tenancy locks the tenant in past the end of their
    -- own lease, which is not a term anybody agreed to.
    CONSTRAINT leases_lock_in_shape CHECK (
        lock_in_until IS NULL
        OR (lock_in_until > valid_from AND (valid_to IS NULL OR lock_in_until <= valid_to))),
    -- A terminated tenancy says who ended it, why, and what happened to the money.
    -- "Requires an explicit decision rather than silently deleting charges" starts
    -- here: the row cannot reach the state without one.
    CONSTRAINT leases_termination_shape CHECK (
        state NOT IN ('terminated', 'settled')
        OR (ended_on IS NOT NULL AND terminated_by IS NOT NULL
            AND terminated_reason IS NOT NULL AND settlement_decision IS NOT NULL)),
    -- A renewed tenancy has an end date, because its successor starts there.
    CONSTRAINT leases_renewed_has_an_end CHECK (state <> 'renewed' OR valid_to IS NOT NULL),
    CONSTRAINT leases_no_self_renewal CHECK (renews_lease_id <> id),
    -- So a journal entry can carry a composite foreign key to the lease it bills,
    -- which is what makes ADR-0010 §7's rule enforceable rather than conventional.
    CONSTRAINT leases_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE leases IS
    'ADR-0010. The tenancy. valid_from/valid_to are what the parties agreed and never change; ended_on is when occupancy actually ceased.';
COMMENT ON COLUMN leases.validity IS
    'The agreed term cut short by ended_on. What charge generation and the no-double-let constraint are computed over.';

-- The composite unique again, for the clusters where leases predates it: CREATE
-- TABLE IF NOT EXISTS adds no constraint to a table that already exists, so on
-- prod the declaration above was a no-op and every later composite foreign key
-- referencing (id, tenant_id) failed to create.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'leases_tenant_id_unique') THEN
        ALTER TABLE leases ADD CONSTRAINT leases_tenant_id_unique UNIQUE (id, tenant_id);
    END IF;
END $$;

-- One flat, one tenancy at a time — the constraint that matters most in a rental
-- product, and it is scoped to the states that are actually tenancies.
--
-- Draft and pending_signature are excluded on purpose: two competing offers on one
-- flat are legitimate, and refusing them would mean an owner cannot prepare a renewal
-- while the current tenancy runs. The moment one is signed, nothing else may overlap
-- it. lapsed is excluded because it never was a tenancy.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'leases_no_double_let') THEN
        ALTER TABLE leases ADD CONSTRAINT leases_no_double_let
            EXCLUDE USING gist (tenant_id WITH =, unit_id WITH =, validity WITH &&)
            WHERE (state IN ('active', 'in_notice', 'renewed', 'terminated', 'settled'));
    END IF;
END
$$;

-- A lease is renewed at most once. Two successors would each claim the tenancy
-- continued, and the ledger would have two candidates for where to carry the deposit.
CREATE UNIQUE INDEX IF NOT EXISTS leases_one_renewal
    ON leases (renews_lease_id) WHERE renews_lease_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS leases_unit_idx ON leases (tenant_id, unit_id, state);
-- "What is live", and "what is running out" — the renewal reminder reads the second.
CREATE INDEX IF NOT EXISTS leases_live_idx
    ON leases (tenant_id, valid_to) WHERE state IN ('active', 'in_notice');
CREATE INDEX IF NOT EXISTS leases_asof_idx
    ON leases USING gist (tenant_id, validity) WHERE state IN ('active', 'in_notice');

-- The transition table, ADR-0010 §3. The same set exists in Go and the store contract
-- test evaluates this function over all 64 ordered pairs.
--
-- from = to is permitted: a redelivered event asks for the state the lease is already
-- in. in_notice -> active is the only backward edge, and the trigger below requires a
-- reason for it.
CREATE OR REPLACE FUNCTION lease_transition_allowed(from_state text, to_state text)
    RETURNS boolean LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT from_state = to_state
        OR (from_state, to_state) IN (
            ('draft',            'pending_signature'),
            ('draft',            'lapsed'),
            ('pending_signature','active'),
            -- The story's edge case: a lease whose tenant never signs. It bills
            -- nothing, because it was never a tenancy.
            ('pending_signature','lapsed'),
            ('active',           'in_notice'),
            ('active',           'renewed'),
            ('active',           'terminated'),
            ('in_notice',        'terminated'),
            -- Notice withdrawn. The workaround for refusing this is a new lease, which
            -- loses the ledger history the tenancy already has.
            ('in_notice',        'active'),
            ('terminated',       'settled'))
$$;

COMMENT ON FUNCTION lease_transition_allowed(text, text) IS
    'ADR-0010 §3. Terminal states absorb, from = to is a no-op, and in_notice -> active is the one backward edge.';

CREATE OR REPLACE FUNCTION leases_transition_is_legal() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT lease_transition_allowed(OLD.state, NEW.state) THEN
        RAISE EXCEPTION 'lease % cannot go from % to %', OLD.id, OLD.state, NEW.state
            USING ERRCODE = 'check_violation';
    END IF;
    -- The agreement is what the parties signed. Only ended_on may shorten the tenancy,
    -- and only once — for the reason ADR-0008 §6 gives about moving a boundary that
    -- something downstream has already reported on.
    IF NEW.valid_from <> OLD.valid_from OR NEW.valid_to IS DISTINCT FROM OLD.valid_to THEN
        RAISE EXCEPTION 'lease % may not have its agreed term edited: an early exit is recorded '
                        'in ended_on, because the parties did not agree to a shorter tenancy', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    IF OLD.ended_on IS NOT NULL AND NEW.ended_on IS DISTINCT FROM OLD.ended_on THEN
        RAISE EXCEPTION 'lease % already ceased on %', OLD.id, OLD.ended_on
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.unit_id <> OLD.unit_id THEN
        RAISE EXCEPTION 'lease % may not be moved to another unit: its ledger history is against '
                        'the unit it was let for', OLD.id USING ERRCODE = 'check_violation';
    END IF;
    -- The one backward edge says why. It is the transition that makes the history
    -- non-monotonic, so it is the one somebody will later ask about.
    IF OLD.state = 'in_notice' AND NEW.state = 'active'
       AND NEW.notice_withdrawn_reason IS NULL THEN
        RAISE EXCEPTION 'lease % withdrew notice with no reason recorded', OLD.id
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_legal_transitions ON leases;
CREATE TRIGGER leases_legal_transitions
    BEFORE UPDATE ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_transition_is_legal();

-- The story's failure scenario, in the database.
--
-- A termination effective before the last invoiced period leaves charges raised for
-- time the tenant will not occupy. Deleting them is already impossible — ADR-0006 §3
-- revokes DELETE on the ledger and refuses it again in a policy — so what remains is
-- that somebody must decide, and 'none' is not a decision when money is at stake.
--
-- It asks the ledger, through journal_entries.lease_id.
--
-- The first version of this trigger matched on source_kind = 'lease_charge' AND
-- source_id = the lease id — a string convention the invoicing story had not yet been
-- written to follow, so the trigger was correct and inert: it found nothing and
-- permitted everything. A guard that depends on a convention nobody has agreed to is
-- not a guard, so the convention is now a foreign key (see journal_entries.lease_id
-- below) and journal_entries_lease_charge_shape makes the pairing structural. An
-- invoice cannot claim to be a lease charge without naming the lease.
--
-- source_kind is filtered because lease_id now names the tenancy an entry concerns,
-- payments included; unfiltered, the last receipt would move "billed through".
-- ADR-0006 §5 amendment.
--
-- SECURITY INVOKER: the lookup runs under the writer's own row-level security, so a
-- session that cannot see the ledger gets no rows and the check fails open rather than
-- reading another organisation's charges.
CREATE OR REPLACE FUNCTION leases_retrospective_end_needs_a_decision() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    billed_through date;
BEGIN
    IF NEW.ended_on IS NULL OR NEW.settlement_decision IS DISTINCT FROM 'none' THEN
        RETURN NEW;
    END IF;

    SELECT max(occurred_on) INTO billed_through
      FROM journal_entries e
     WHERE e.tenant_id = NEW.tenant_id
       AND e.lease_id = NEW.id
       AND e.source_kind = 'lease_charge';

    IF billed_through IS NOT NULL AND NEW.ended_on < billed_through THEN
        RAISE EXCEPTION 'lease % is ending % and charges are raised through %: an over-billed '
                        'period exists, so adjust it, refund it, or forfeit it — but say which',
            NEW.id, NEW.ended_on, billed_through
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_retrospective_end ON leases;
CREATE TRIGGER leases_retrospective_end
    BEFORE INSERT OR UPDATE OF ended_on, settlement_decision ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_retrospective_end_needs_a_decision();

-- A renewal starts exactly where its predecessor's agreed term ends. ADR-0008's
-- half-open interval doing the work: no gap for a day of unbilled occupancy, no
-- overlap for leases_no_double_let to refuse.
CREATE OR REPLACE FUNCTION leases_renewal_is_contiguous() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    prev_end date;
    prev_unit uuid;
BEGIN
    IF NEW.renews_lease_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT valid_to, unit_id INTO prev_end, prev_unit
      FROM leases WHERE id = NEW.renews_lease_id;
    IF prev_end IS NULL THEN
        RAISE EXCEPTION 'lease % renews %, which has no agreed end — a renewal starts where the '
                        'term ends, and that one does not end', NEW.id, NEW.renews_lease_id
            USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.valid_from <> prev_end THEN
        RAISE EXCEPTION 'lease % starts % and renews a tenancy ending %: a gap leaves a day '
                        'unbilled and an overlap is two tenancies of one flat',
            NEW.id, NEW.valid_from, prev_end USING ERRCODE = 'check_violation';
    END IF;
    IF prev_unit IS DISTINCT FROM NEW.unit_id THEN
        RAISE EXCEPTION 'lease % renews a tenancy of a different unit', NEW.id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_renewal_contiguous ON leases;
CREATE TRIGGER leases_renewal_contiguous
    BEFORE INSERT OR UPDATE OF renews_lease_id, valid_from ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_renewal_is_contiguous();

CREATE OR REPLACE FUNCTION leases_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT u.parent_unit_id INTO NEW.unit_parent_id FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS leases_parent ON leases;
CREATE TRIGGER leases_parent
    BEFORE INSERT OR UPDATE OF unit_id ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_unit_parent();

-- Who is on the lease, and when. Effective-dated because a co-tenant joins or leaves
-- mid-term and the deposit apportionment has to know who was there when.
CREATE TABLE IF NOT EXISTS lease_parties (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),

    party_id      uuid NOT NULL,
    role          text NOT NULL CHECK (role IN ('tenant', 'guarantor', 'occupant')),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES lease_parties(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lease_parties_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT lease_parties_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE lease_parties IS
    'ADR-0010. Who is on a lease and when. Effective-dated: a co-tenant joins or leaves mid-term.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lease_parties_no_overlap') THEN
        -- One person cannot hold the same role on the same lease twice at once. Two
        -- different people in the same role is the normal case for co-tenants, so the
        -- party is part of the key.
        ALTER TABLE lease_parties ADD CONSTRAINT lease_parties_no_overlap
            EXCLUDE USING gist (lease_id WITH =, party_id WITH =, role WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS lease_parties_lease_idx
    ON lease_parties (lease_id, role) WHERE retired_at IS NULL;
CREATE INDEX IF NOT EXISTS lease_parties_party_idx
    ON lease_parties (tenant_id, party_id) WHERE retired_at IS NULL;

-- What is owed, and from when. ADR-0008's own worked example: a rent revision from
-- 25,000 to 27,000 effective 1 April is two rows, and an as-of query for 15 March
-- still says 25,000.
CREATE TABLE IF NOT EXISTS rent_schedule (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),

    -- ADR-0007: an integer of minor units, and the assertion about money columns
    -- checks the name and the type.
    amount_minor  bigint NOT NULL CHECK (amount_minor > 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    -- The day of the month rent falls due. 31 means the last day, whatever that is.
    due_day       int NOT NULL DEFAULT 5 CHECK (due_day BETWEEN 1 AND 31),

    valid_from    date NOT NULL,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    retired_at    timestamptz,
    corrects      uuid REFERENCES rent_schedule(id),

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT rent_schedule_window CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT rent_schedule_amount_representable CHECK (amount_minor <= 9007199254740991),
    CONSTRAINT rent_schedule_correction_shape CHECK (corrects IS NULL OR corrects <> id)
);

COMMENT ON TABLE rent_schedule IS
    'ADR-0010 and ADR-0008. What is owed and from when. Charge generation is this intersected with the lease''s validity.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rent_schedule_no_overlap') THEN
        -- One rent at a time. This is the constraint the story's failure scenario is
        -- about, on the table the story's primary scenario is about.
        ALTER TABLE rent_schedule ADD CONSTRAINT rent_schedule_no_overlap
            EXCLUDE USING gist (lease_id WITH =, validity WITH &&)
            WHERE (retired_at IS NULL);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS rent_schedule_asof_idx
    ON rent_schedule USING gist (lease_id, validity) WHERE retired_at IS NULL;

-- Expiring, derived. ADR-0010 §6: a stored `expiring` state needs a job to maintain it,
-- and a lease that should be expiring and is not would be a silent bug. Same argument
-- ADR-0012 §7 makes about ageing buckets.
--
-- security_invoker, as assertion 10 requires of every view in this schema.
CREATE OR REPLACE VIEW lease_expiring
    WITH (security_invoker = true) AS
    SELECT l.id AS lease_id,
           l.tenant_id,
           l.property_id,
           l.unit_id,
           l.state,
           l.valid_to                        AS ends_on,
           (l.valid_to - current_date)       AS days_remaining,
           l.notice_days,
           -- Whether notice can still be given in time, which is the thing an owner
           -- actually needs to know and is one subtraction away from being got wrong
           -- in a dashboard.
           (l.valid_to - current_date) <= l.notice_days AS inside_notice_window
      FROM leases l
     WHERE l.state IN ('active', 'in_notice')
       AND l.valid_to IS NOT NULL
       AND l.valid_to > current_date;

COMMENT ON VIEW lease_expiring IS
    'ADR-0010 §6. Tenancies running out, derived from the clock. Never a stored state: one that should be expiring and is not would be a silent bug.';

ALTER TABLE leases        ENABLE ROW LEVEL SECURITY;
ALTER TABLE leases        FORCE  ROW LEVEL SECURITY;
ALTER TABLE lease_parties ENABLE ROW LEVEL SECURITY;
ALTER TABLE lease_parties FORCE  ROW LEVEL SECURITY;
ALTER TABLE rent_schedule ENABLE ROW LEVEL SECURITY;
ALTER TABLE rent_schedule FORCE  ROW LEVEL SECURITY;

-- Unit granularity on leases, as ADR-0009 §4 requires and assertion 6 enforces: a firm
-- managing two flats must not read the tower's rent roll.
DROP POLICY IF EXISTS leases_tenant_isolation ON leases;
CREATE POLICY leases_tenant_isolation ON leases
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'lease.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'lease.write'));

-- The two child tables carry no unit of their own, so their delegated branch is the
-- parent lease's. Written as a lookup against leases rather than by denormalising the
-- unit, because the lease's own policy then governs both — one definition of who may
-- see a tenancy, rather than three that can drift.
--
-- It is a plpgsql function rather than an inline EXISTS, and the reason is ADR-0029.
-- The resident policy on `leases` asks whether this renter is a party to it, which
-- reads lease_parties — and if lease_parties' own policy then reads leases, the two
-- recurse until PostgreSQL gives up. Measured, before this function existed: "stack
-- depth limit exceeded (SQLSTATE 54001)" on the first tenant-view query.
--
-- plpgsql is what makes the guard load-bearing: statements run in order, so the
-- EXISTS below is never executed in a resident session. Written as `NOT
-- is_resident_session() AND EXISTS (…)` inside a SQL policy the planner is free to
-- evaluate the correlated subquery first, and the cycle comes back — intermittently,
-- which is worse than always.
CREATE OR REPLACE FUNCTION lease_delegated_read(row_lease uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE PARALLEL SAFE AS
$$
BEGIN
    -- A renter reaches a tenancy through ADR-0029's own policy, never through a
    -- delegation: a delegation is a mandate between organisations, and a renter
    -- is not one.
    IF is_resident_session() THEN
        RETURN false;
    END IF;
    RETURN EXISTS (SELECT 1 FROM leases l WHERE l.id = row_lease);
END
$$;

COMMENT ON FUNCTION lease_delegated_read(uuid) IS
    'ADR-0005 and ADR-0029. The delegated read branch for a lease''s child tables, guarded so it cannot recurse into the resident scope.';

DROP POLICY IF EXISTS lease_parties_tenant_isolation ON lease_parties;
CREATE POLICY lease_parties_tenant_isolation ON lease_parties
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR lease_delegated_read(lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS rent_schedule_tenant_isolation ON rent_schedule;
CREATE POLICY rent_schedule_tenant_isolation ON rent_schedule
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR lease_delegated_read(lease_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A lease that lapsed and a rent that was revised are
-- what a dispute turns on, and a deleted lease orphans every posting made against it.
DROP POLICY IF EXISTS leases_no_delete ON leases;
CREATE POLICY leases_no_delete ON leases AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS lease_parties_no_delete ON lease_parties;
CREATE POLICY lease_parties_no_delete ON lease_parties AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS rent_schedule_no_delete ON rent_schedule;
CREATE POLICY rent_schedule_no_delete ON rent_schedule AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- dwellm8_app only: dwellm8_platform inherits it, and the role does not exist
-- yet at this point in the file. CI caught it — "role dwellm8_platform does not
-- exist" on a fresh database, where a laptop that already had the role did not.
GRANT EXECUTE ON FUNCTION lease_delegated_read(uuid) TO dwellm8_app;

GRANT SELECT, INSERT, UPDATE ON leases, lease_parties, rent_schedule TO dwellm8_lease;
GRANT SELECT ON lease_expiring TO dwellm8_lease, dwellm8_notify, dwellm8_property;
-- Money bills against the lease and reads the schedule; it writes neither.
GRANT SELECT ON leases, lease_parties, rent_schedule
    TO dwellm8_money, dwellm8_property, dwellm8_identity, dwellm8_notify, dwellm8_maintenance;

