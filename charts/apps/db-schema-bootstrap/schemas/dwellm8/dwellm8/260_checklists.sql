-- ===========================================================================
-- checklist automation (ADR-0032)
-- ===========================================================================

-- A move-in is fifteen steps and a move-out is twenty, and the person doing them
-- is on their fourth property of the day.
--
--   checklist_templates       what a process looks like, per organisation and kind
--   checklist_template_steps  the steps, their offsets, their dependencies
--   checklists                one firing of a template against a lease or a unit
--   checklist_tasks           the materialised graph, with owners and due dates
--
-- Two things here are not bookkeeping.
--
-- A step marked `blocking` refuses the lease transition its process gates, from a
-- trigger on `leases` — the same shape as ADR-0010's own retrospective-termination
-- trigger, and for the same reason: `leases.state` is written by more than one
-- path, and the paths that skip the service are exactly the ones nobody reviews.
--
-- Abandonment is derived. `checklist_stalled` is a view, never a column, because a
-- stored flag needs a job to maintain it and a checklist that should be flagged and
-- is not is invisible in precisely the way the story's edge case is about.

-- ---------------------------------------------------------------------------
-- templates
-- ---------------------------------------------------------------------------
--
-- `is_default` marks the platform library. Those rows belong to the platform
-- organisation, are readable by any signed-in organisation and writable only by a
-- platform session — the privilege model ADR-0023's rule tables use, expressed in a
-- policy rather than a GRANT because the same table also holds tenant data.
--
-- property_kind is `properties.kind` and deliberately not a new "vertical" column:
-- a second vocabulary for the same idea drifts the first day somebody adds a value
-- to one and not the other. NULL means "any kind", which is the fallback rung of
-- ADR-0032 §2's resolution order.

CREATE TABLE IF NOT EXISTS checklist_templates (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    is_default    boolean NOT NULL DEFAULT false,

    process       text NOT NULL CHECK (process IN (
                      'move_in', 'move_out', 'owner_onboarding',
                      'manager_handover', 'tenancy_renewal')),
    property_kind text CHECK (property_kind IN (
                      'standalone', 'building', 'society', 'commercial', 'coliving', 'plot')),

    name          text NOT NULL,
    version       int NOT NULL DEFAULT 1 CHECK (version > 0),
    -- An unpublished template is a draft nothing may be fired from, and a retired
    -- one is history: instances already reference it and it is never deleted.
    published_at  timestamptz,
    retired_at    timestamptz,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT checklist_templates_retired_after_published CHECK (
        retired_at IS NULL OR published_at IS NOT NULL),
    -- So the steps can carry a composite foreign key and cannot be attached to
    -- another organisation's template. Same device as leases_tenant_id_unique.
    CONSTRAINT checklist_templates_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE checklist_templates IS
    'ADR-0032 §2. A process for an organisation and a property kind. is_default marks the platform library.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checklist_templates_tenant_id_unique') THEN
        ALTER TABLE checklist_templates ADD CONSTRAINT checklist_templates_tenant_id_unique UNIQUE (id, tenant_id);
    END IF;
END $$;

-- One live template per organisation, process, kind and version. coalesce() is what
-- makes the "any kind" row participate: a NULL in a unique index collides with
-- nothing, so without it an organisation could hold two any-kind move-outs.
CREATE UNIQUE INDEX IF NOT EXISTS checklist_templates_version_idx
    ON checklist_templates (tenant_id, process, coalesce(property_kind, '*'), version)
    WHERE retired_at IS NULL;

-- The resolution read, ADR-0032 §2: process, then kind, most specific first.
CREATE INDEX IF NOT EXISTS checklist_templates_resolve_idx
    ON checklist_templates (process, property_kind, tenant_id)
    WHERE retired_at IS NULL AND published_at IS NOT NULL;

-- The steps.
--
-- depends_on holds step codes rather than ids, because a template's steps are
-- authored together and a code survives a version being copied forward. The
-- triggers below check that every code exists in the same template and that the
-- graph is acyclic — a cycle is not a security failure, it is a checklist that can
-- never complete and therefore a tenancy that can never close.
CREATE TABLE IF NOT EXISTS checklist_template_steps (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    template_id   uuid NOT NULL,
    -- Denormalised from the parent by a trigger, so this table's policy can be read
    -- on its own rather than through a lookup that would recurse under ADR-0029.
    is_default    boolean NOT NULL DEFAULT false,

    code          citext NOT NULL,
    title         text NOT NULL,
    description   text,
    position      int NOT NULL CHECK (position > 0),

    blocking      boolean NOT NULL DEFAULT false,
    -- Who it lands on by default. A role rather than a person: a template outlives
    -- the manager who wrote it.
    owner_role    text NOT NULL DEFAULT 'manager' CHECK (owner_role IN (
                      'manager', 'staff', 'accountant', 'owner', 'field_agent',
                      'warden', 'guard', 'tenant', 'vendor')),
    -- Signed, and relative to the checklist's anchor: "three days before the tenant
    -- leaves" is -3 and "seven days after handover" is 7. One integer either way.
    due_offset_days int NOT NULL DEFAULT 0,
    depends_on    citext[] NOT NULL DEFAULT '{}',

    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT checklist_template_steps_template_fkey FOREIGN KEY (template_id, tenant_id)
        REFERENCES checklist_templates (id, tenant_id),
    -- A step that depends on itself is the smallest cycle and the easiest to type.
    CONSTRAINT checklist_template_steps_not_self CHECK (NOT (code = ANY (depends_on))),
    CONSTRAINT checklist_template_steps_code_unique UNIQUE (template_id, code)
);

COMMENT ON TABLE checklist_template_steps IS
    'ADR-0032 §3. Steps, their blocking flag, their owner role and their offset from the anchor date.';

CREATE UNIQUE INDEX IF NOT EXISTS checklist_template_steps_position_idx
    ON checklist_template_steps (template_id, position);

-- Every dependency names a step of the same template, and the graph does not cycle.
--
-- Both checks are here rather than only in Go because a template is the thing an
-- organisation edits, and an edit that introduces a cycle produces its damage weeks
-- later — at the move-out that will not close, on a task nobody can release.
CREATE OR REPLACE FUNCTION checklist_template_steps_graph_is_sound() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    missing text;
    cycle   text;
BEGIN
    SELECT string_agg(d, ', ') INTO missing
      FROM unnest(NEW.depends_on) AS d
     WHERE NOT EXISTS (
         SELECT 1 FROM checklist_template_steps s
          WHERE s.template_id = NEW.template_id AND s.code = d::citext);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'step % depends on %, which is not a step of this template',
            NEW.code, missing USING ERRCODE = 'foreign_key_violation';
    END IF;

    -- Walk forward from this step's dependencies and see whether the walk reaches
    -- this step again. The path is carried so the refusal can print it, and the
    -- walk stops at a node it has already visited — without that, a cycle anywhere
    -- in the template makes this recursion the thing that hangs.
    WITH RECURSIVE walk(code, path, closes) AS (
        SELECT d::citext, ARRAY[d::text], d::citext = NEW.code
          FROM unnest(NEW.depends_on) AS d
        UNION ALL
        SELECT dep::citext, walk.path || dep::text, dep::citext = NEW.code
          FROM walk
          JOIN checklist_template_steps s
            ON s.template_id = NEW.template_id AND s.code = walk.code
          CROSS JOIN LATERAL unnest(s.depends_on) AS dep
         WHERE NOT walk.closes AND NOT (dep::text = ANY (walk.path))
    )
    SELECT array_to_string(NEW.code::text || path, ' -> ') INTO cycle
      FROM walk WHERE closes LIMIT 1;
    IF cycle IS NOT NULL THEN
        RAISE EXCEPTION 'the steps of this template depend on each other in a circle: % — '
                        'every task in it would wait for a task waiting for it', cycle
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END
$$;

-- Deferred to commit, because a template's steps are written together and step one
-- legitimately names step four before step four exists. An immediate check would
-- force the writer to insert in dependency order, which is an ordering nobody has
-- and which the graph itself is the definition of.
DROP TRIGGER IF EXISTS checklist_template_steps_sound ON checklist_template_steps;
CREATE CONSTRAINT TRIGGER checklist_template_steps_sound
    AFTER INSERT OR UPDATE ON checklist_template_steps
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION checklist_template_steps_graph_is_sound();

-- is_default follows the template it belongs to, never the writer's word for it:
-- otherwise a tenant could write a step claiming to be part of the platform library
-- and the policy below would let every organisation read it.
CREATE OR REPLACE FUNCTION checklist_template_steps_inherit_default() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT t.is_default INTO NEW.is_default
      FROM checklist_templates t WHERE t.id = NEW.template_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS checklist_template_steps_default ON checklist_template_steps;
CREATE TRIGGER checklist_template_steps_default
    BEFORE INSERT OR UPDATE OF template_id ON checklist_template_steps
    FOR EACH ROW EXECUTE FUNCTION checklist_template_steps_inherit_default();

-- ---------------------------------------------------------------------------
-- instances
-- ---------------------------------------------------------------------------
--
-- The version is snapshotted because editing a template must not rewrite what a
-- manager is halfway through, and the anchor is stored because every due date on
-- every task was computed from it — a reader who cannot see the anchor cannot say
-- why a task is due on Tuesday.

CREATE TABLE IF NOT EXISTS checklists (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    process       text NOT NULL CHECK (process IN (
                      'move_in', 'move_out', 'owner_onboarding',
                      'manager_handover', 'tenancy_renewal')),
    template_id      uuid NOT NULL,
    template_version int NOT NULL CHECK (template_version > 0),

    -- What it is about. property_id is required because a checklist that names no
    -- property cannot be judged at unit granularity, and ADR-0009 §4 says every
    -- delegated read must be.
    property_id   uuid NOT NULL,
    unit_id       uuid,
    unit_parent_id uuid,
    lease_id      uuid,

    -- The date every offset is measured from: the move-out date, the handover date,
    -- the tenancy start. Supplied by the caller, because only the caller knows it.
    anchor_on     date NOT NULL,

    state         text NOT NULL DEFAULT 'open'
                  CHECK (state IN ('open', 'completed', 'abandoned')),
    started_by    uuid,
    started_at    timestamptz NOT NULL DEFAULT now(),
    completed_at  timestamptz,
    abandoned_at  timestamptz,
    abandoned_reason text,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT checklists_template_fkey FOREIGN KEY (template_id, tenant_id)
        REFERENCES checklist_templates (id, tenant_id),
    CONSTRAINT checklists_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT checklists_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT checklists_lease_fkey FOREIGN KEY (lease_id, tenant_id)
        REFERENCES leases (id, tenant_id),
    -- The three tenancy processes are about a tenancy, so they name one. Without
    -- this the move-out gate has nothing to attach to and would silently never fire.
    CONSTRAINT checklists_tenancy_process_names_a_lease CHECK (
        process NOT IN ('move_in', 'move_out', 'tenancy_renewal') OR lease_id IS NOT NULL),
    CONSTRAINT checklists_completion_shape CHECK (
        state <> 'completed' OR completed_at IS NOT NULL),
    -- An abandoned checklist says why. It is the one ending that is a decision
    -- rather than an outcome, and the story asks for it to be visible.
    CONSTRAINT checklists_abandonment_shape CHECK (
        state <> 'abandoned' OR (abandoned_at IS NOT NULL AND abandoned_reason IS NOT NULL)),
    CONSTRAINT checklists_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON TABLE checklists IS
    'ADR-0032 §3. One firing of a template. anchor_on is the date every task''s due date was computed from.';
COMMENT ON COLUMN checklists.template_version IS
    'Snapshotted: editing a template must not rewrite a process somebody is halfway through.';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'checklists_tenant_id_unique') THEN
        ALTER TABLE checklists ADD CONSTRAINT checklists_tenant_id_unique UNIQUE (id, tenant_id);
    END IF;
END $$;

-- One open checklist per process per tenancy. Firing a move-out twice is a manager
-- pressing the button twice, not a second move-out, and two graphs over one tenancy
-- would each be half done.
CREATE UNIQUE INDEX IF NOT EXISTS checklists_one_open_per_lease
    ON checklists (tenant_id, lease_id, process)
    WHERE state = 'open' AND lease_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS checklists_portfolio_idx
    ON checklists (tenant_id, state, property_id);
CREATE INDEX IF NOT EXISTS checklists_lease_idx
    ON checklists (tenant_id, lease_id) WHERE lease_id IS NOT NULL;

CREATE OR REPLACE FUNCTION checklists_unit_parent() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    SELECT u.parent_unit_id INTO NEW.unit_parent_id FROM units u WHERE u.id = NEW.unit_id;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS checklists_parent ON checklists;
CREATE TRIGGER checklists_parent
    BEFORE INSERT OR UPDATE OF unit_id ON checklists
    FOR EACH ROW EXECUTE FUNCTION checklists_unit_parent();

-- The tasks. Materialised at trigger time, never computed on read — an instance is
-- a record of what was asked for, and a template edited next month must not change
-- what a manager was told to do last week.
CREATE TABLE IF NOT EXISTS checklist_tasks (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    checklist_id  uuid NOT NULL,

    step_code     citext NOT NULL,
    title         text NOT NULL,
    position      int NOT NULL CHECK (position > 0),
    blocking      boolean NOT NULL DEFAULT false,

    owner_role    text NOT NULL,
    assignee_party_id uuid,
    due_on        date NOT NULL,
    depends_on    citext[] NOT NULL DEFAULT '{}',

    -- blocked is not a synonym for pending: it says the reason this cannot be done
    -- yet is another task, which is a sentence a screen can show before somebody
    -- drives to the property.
    state         text NOT NULL DEFAULT 'pending'
                  CHECK (state IN ('blocked', 'pending', 'done', 'skipped')),
    completed_at  timestamptz,
    completed_by  uuid,
    skipped_reason text,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT checklist_tasks_checklist_fkey FOREIGN KEY (checklist_id, tenant_id)
        REFERENCES checklists (id, tenant_id),
    CONSTRAINT checklist_tasks_step_unique UNIQUE (checklist_id, step_code),
    CONSTRAINT checklist_tasks_not_self CHECK (NOT (step_code = ANY (depends_on))),
    CONSTRAINT checklist_tasks_completion_shape CHECK (
        state <> 'done' OR completed_at IS NOT NULL),
    -- A blocking step may not be skipped at all. If a step is skippable it was not
    -- blocking, and a skipped blocking step that satisfied the gate would make every
    -- gate advisory. ADR-0032 §4.
    CONSTRAINT checklist_tasks_skip_shape CHECK (
        state <> 'skipped' OR (NOT blocking AND skipped_reason IS NOT NULL))
);

COMMENT ON TABLE checklist_tasks IS
    'ADR-0032 §3. The materialised graph. A blocking task refuses the lease transition its process gates.';
COMMENT ON CONSTRAINT checklist_tasks_skip_shape ON checklist_tasks IS
    'ADR-0032 §4. A blocking step cannot be skipped: if it were skippable it was not blocking.';

CREATE INDEX IF NOT EXISTS checklist_tasks_checklist_idx
    ON checklist_tasks (checklist_id, position);
-- "What is outstanding here", which is what the gate, the progress view and the
-- stalled view all ask.
CREATE INDEX IF NOT EXISTS checklist_tasks_outstanding_idx
    ON checklist_tasks (tenant_id, checklist_id, due_on)
    WHERE state IN ('blocked', 'pending');
CREATE INDEX IF NOT EXISTS checklist_tasks_assignee_idx
    ON checklist_tasks (tenant_id, assignee_party_id)
    WHERE state IN ('blocked', 'pending');

-- ---------------------------------------------------------------------------
-- the rules
-- ---------------------------------------------------------------------------

-- A task cannot be finished before what it waits on.
--
-- Ticking the last box first is the failure a paper checklist has and a digital one
-- should not: it records a process that did not happen, and the record is what the
-- deposit dispute turns on six months later.
CREATE OR REPLACE FUNCTION checklist_tasks_dependencies_are_settled() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    outstanding text;
    parent_state text;
BEGIN
    IF NEW.state NOT IN ('done', 'skipped') OR OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;

    SELECT c.state INTO parent_state FROM checklists c WHERE c.id = NEW.checklist_id;
    IF parent_state <> 'open' THEN
        RAISE EXCEPTION 'checklist % is %, so its tasks are history', NEW.checklist_id, parent_state
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT string_agg(t.title, ', ' ORDER BY t.position) INTO outstanding
      FROM checklist_tasks t
     WHERE t.checklist_id = NEW.checklist_id
       AND t.step_code = ANY (NEW.depends_on)
       AND t.state NOT IN ('done', 'skipped');
    IF outstanding IS NOT NULL THEN
        RAISE EXCEPTION '% cannot be done yet: it waits on %', NEW.title, outstanding
            USING ERRCODE = 'check_violation';
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS checklist_tasks_dependencies ON checklist_tasks;
CREATE TRIGGER checklist_tasks_dependencies
    BEFORE UPDATE ON checklist_tasks
    FOR EACH ROW EXECUTE FUNCTION checklist_tasks_dependencies_are_settled();

-- Settling a task releases whatever was waiting on it. Done here rather than in the
-- service so that `blocked` is never stale: a task's state is a fact about the
-- graph, and a fact maintained by one caller is a fact the next caller forgets.
CREATE OR REPLACE FUNCTION checklist_tasks_release_dependents() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    UPDATE checklist_tasks t
       SET state = 'pending', updated_at = now()
     WHERE t.checklist_id = NEW.checklist_id
       AND t.state = 'blocked'
       AND NEW.step_code = ANY (t.depends_on)
       AND NOT EXISTS (
           SELECT 1 FROM checklist_tasks d
            WHERE d.checklist_id = t.checklist_id
              AND d.step_code = ANY (t.depends_on)
              AND d.state NOT IN ('done', 'skipped'));
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS checklist_tasks_release ON checklist_tasks;
CREATE TRIGGER checklist_tasks_release
    AFTER UPDATE OF state ON checklist_tasks
    FOR EACH ROW WHEN (NEW.state IN ('done', 'skipped') AND OLD.state IS DISTINCT FROM NEW.state)
    EXECUTE FUNCTION checklist_tasks_release_dependents();

-- A checklist completes when nothing blocking is outstanding, and the refusal names
-- what is — the story's failure scenario, in the database.
CREATE OR REPLACE FUNCTION checklists_completion_needs_its_blocking_steps() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    outstanding text;
BEGIN
    IF NEW.state = OLD.state THEN
        NEW.updated_at := now();
        RETURN NEW;
    END IF;
    IF OLD.state <> 'open' THEN
        RAISE EXCEPTION 'checklist % is already %', OLD.id, OLD.state
            USING ERRCODE = 'check_violation';
    END IF;

    IF NEW.state = 'completed' THEN
        SELECT string_agg(t.title, ', ' ORDER BY t.position) INTO outstanding
          FROM checklist_tasks t
         WHERE t.checklist_id = NEW.id AND t.blocking AND t.state NOT IN ('done', 'skipped');
        IF outstanding IS NOT NULL THEN
            RAISE EXCEPTION 'this checklist cannot be completed: % outstanding', outstanding
                USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS checklists_completion ON checklists;
CREATE TRIGGER checklists_completion
    BEFORE UPDATE ON checklists
    FOR EACH ROW EXECUTE FUNCTION checklists_completion_needs_its_blocking_steps();

-- The gate. ADR-0032 §4.
--
-- A tenancy may not close while its move-out has blocking steps outstanding, and
-- the refusal names the first of them. This is the second of two copies — the
-- service refuses first, with the whole list, so a client can render it — and it
-- exists for the reason ADR-0010's own trigger exists: `leases.state` is written by
-- support actions, backfills and future modules, and those are the paths that skip
-- the service.
--
-- SECURITY INVOKER, like leases_retrospective_end_needs_a_decision: the lookup runs
-- under the writer's own row-level security, so a session that cannot see the
-- checklist finds nothing and the close is permitted rather than the checklist of
-- another organisation being read.
CREATE OR REPLACE FUNCTION leases_close_needs_its_blocking_steps() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    outstanding text;
BEGIN
    IF NEW.state NOT IN ('terminated', 'settled') OR OLD.state = NEW.state THEN
        RETURN NEW;
    END IF;

    SELECT string_agg(t.title, ', ' ORDER BY t.position) INTO outstanding
      FROM checklist_tasks t
      JOIN checklists c ON c.id = t.checklist_id
     WHERE c.tenant_id = NEW.tenant_id
       AND c.lease_id = NEW.id
       AND c.process = 'move_out'
       AND c.state = 'open'
       AND t.blocking
       AND t.state NOT IN ('done', 'skipped');

    IF outstanding IS NOT NULL THEN
        RAISE EXCEPTION 'lease % cannot be closed while its move-out is outstanding: % — '
                        'finish the step or record why it does not apply', NEW.id, outstanding
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION leases_close_needs_its_blocking_steps() IS
    'ADR-0032 §4. A tenancy does not close over an unfinished move-out. The service refuses first; this catches the paths that skip it.';

DROP TRIGGER IF EXISTS leases_blocking_checklist ON leases;
CREATE TRIGGER leases_blocking_checklist
    BEFORE UPDATE OF state ON leases
    FOR EACH ROW EXECUTE FUNCTION leases_close_needs_its_blocking_steps();

-- ---------------------------------------------------------------------------
-- what a portfolio view reads
-- ---------------------------------------------------------------------------
--
-- Both derived, both security_invoker as assertion 10 requires. A stored counter is
-- one failed update away from lying, and the lie is "this move-out is finished".

CREATE OR REPLACE VIEW checklist_progress
    WITH (security_invoker = true) AS
    SELECT c.id AS checklist_id,
           c.tenant_id,
           c.process,
           c.property_id,
           c.unit_id,
           c.lease_id,
           c.state,
           c.anchor_on,
           count(t.*)                                                    AS tasks,
           count(*) FILTER (WHERE t.state IN ('done', 'skipped'))        AS settled,
           count(*) FILTER (WHERE t.state NOT IN ('done', 'skipped'))    AS outstanding,
           count(*) FILTER (WHERE t.blocking
                              AND t.state NOT IN ('done', 'skipped'))    AS blocking_outstanding,
           min(t.due_on) FILTER (WHERE t.state NOT IN ('done', 'skipped')) AS next_due_on
      FROM checklists c
      LEFT JOIN checklist_tasks t ON t.checklist_id = c.id
     GROUP BY c.id, c.tenant_id, c.process, c.property_id, c.unit_id, c.lease_id,
              c.state, c.anchor_on;

COMMENT ON VIEW checklist_progress IS
    'ADR-0032 §5. Progress per checklist, derived. Never a stored counter.';

-- The story's second edge case: an abandoned checklist must be visible rather than
-- silently incomplete.
--
-- "Abandoned" here is not the explicit state — that one says why and is already
-- visible. This is the other kind, the one nobody decided: open, overdue, and
-- reading on every screen as a process that is under way. Derived from the clock for
-- the reason ADR-0010 §6 gives about `expiring`.
CREATE OR REPLACE VIEW checklist_stalled
    WITH (security_invoker = true) AS
    SELECT p.checklist_id,
           p.tenant_id,
           p.process,
           p.property_id,
           p.unit_id,
           p.lease_id,
           p.outstanding,
           p.blocking_outstanding,
           p.next_due_on,
           (current_date - p.next_due_on) AS days_overdue
      FROM checklist_progress p
     WHERE p.state = 'open'
       AND p.next_due_on IS NOT NULL
       AND p.next_due_on < current_date;

COMMENT ON VIEW checklist_stalled IS
    'ADR-0032 §5. Open checklists whose next step is already late — the abandonment nobody declared.';

-- ---------------------------------------------------------------------------
-- row-level security
-- ---------------------------------------------------------------------------

ALTER TABLE checklist_templates      ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_templates      FORCE  ROW LEVEL SECURITY;
ALTER TABLE checklist_template_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_template_steps FORCE  ROW LEVEL SECURITY;
ALTER TABLE checklists               ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklists               FORCE  ROW LEVEL SECURITY;
ALTER TABLE checklist_tasks          ENABLE ROW LEVEL SECURITY;
ALTER TABLE checklist_tasks          FORCE  ROW LEVEL SECURITY;

-- The platform library is readable by any organisation that has one — and by nobody
-- who has not. `current_tenant_id() IS NOT NULL` is what keeps this out of assertion
-- 17's territory: an unscoped session is an anonymous visitor, and the default
-- move-out list is not a thing the internet gets to enumerate.
--
-- The write branch is where the library is protected: an organisation may write its
-- own rows and may not write a default, so a tenant cannot publish a step into every
-- other organisation's resolution order.
DROP POLICY IF EXISTS checklist_templates_tenant_isolation ON checklist_templates;
CREATE POLICY checklist_templates_tenant_isolation ON checklist_templates
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (is_default AND current_tenant_id() IS NOT NULL))
    WITH CHECK ((tenant_id = current_tenant_id() AND NOT is_default)
           OR is_platform_session());

DROP POLICY IF EXISTS checklist_template_steps_tenant_isolation ON checklist_template_steps;
CREATE POLICY checklist_template_steps_tenant_isolation ON checklist_template_steps
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (is_default AND current_tenant_id() IS NOT NULL))
    WITH CHECK ((tenant_id = current_tenant_id() AND NOT is_default)
           OR is_platform_session());

-- Unit granularity, as ADR-0009 §4 requires and assertions 5 and 6 enforce: a firm
-- managing two flats must not read the tower's move-outs.
DROP POLICY IF EXISTS checklists_tenant_isolation ON checklists;
CREATE POLICY checklists_tenant_isolation ON checklists
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'maintenance.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'maintenance.write'));

-- A task carries no unit of its own, so its delegated branch is its checklist's.
-- Written as a lookup so there is one definition of who may see a process rather
-- than two that drift, and guarded against the resident scope for the reason
-- lease_delegated_read() is: a policy that reads a table whose policy reads back
-- exhausts the stack, intermittently.
CREATE OR REPLACE FUNCTION checklist_delegated_read(row_checklist uuid) RETURNS boolean
    LANGUAGE plpgsql STABLE PARALLEL SAFE AS
$$
BEGIN
    IF is_resident_session() THEN
        RETURN false;
    END IF;
    RETURN EXISTS (SELECT 1 FROM checklists c WHERE c.id = row_checklist);
END
$$;

COMMENT ON FUNCTION checklist_delegated_read(uuid) IS
    'ADR-0005 and ADR-0029. The delegated branch for checklist_tasks, guarded so it cannot recurse into the resident scope.';

DROP POLICY IF EXISTS checklist_tasks_tenant_isolation ON checklist_tasks;
CREATE POLICY checklist_tasks_tenant_isolation ON checklist_tasks
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR checklist_delegated_read(checklist_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Nothing here may be deleted. A move-out that was abandoned and a step that was
-- skipped are what a deposit dispute turns on, and a template is the evidence of
-- what the organisation asked for at the time.
DROP POLICY IF EXISTS checklist_templates_no_delete ON checklist_templates;
CREATE POLICY checklist_templates_no_delete ON checklist_templates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS checklist_template_steps_no_delete ON checklist_template_steps;
CREATE POLICY checklist_template_steps_no_delete ON checklist_template_steps AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS checklists_no_delete ON checklists;
CREATE POLICY checklists_no_delete ON checklists AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS checklist_tasks_no_delete ON checklist_tasks;
CREATE POLICY checklist_tasks_no_delete ON checklist_tasks AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- ADR-0029. Written here rather than left to the generator in 220, which runs
-- before this file: on a fresh database these tables would otherwise stand open to
-- a renter session until the next replay, which is thirty minutes in production and
-- forever in CI. The names match the generator's, so its DROP-and-CREATE replaces
-- these with identical policies rather than adding a second copy.
--
-- A renter has no business in an operations checklist at all — their move-out tasks
-- reach them as notifications, not as rows.
DROP POLICY IF EXISTS checklist_templates_resident_denied ON checklist_templates;
CREATE POLICY checklist_templates_resident_denied ON checklist_templates AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
DROP POLICY IF EXISTS checklist_template_steps_resident_denied ON checklist_template_steps;
CREATE POLICY checklist_template_steps_resident_denied ON checklist_template_steps AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
DROP POLICY IF EXISTS checklists_resident_denied ON checklists;
CREATE POLICY checklists_resident_denied ON checklists AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());
DROP POLICY IF EXISTS checklist_tasks_resident_denied ON checklist_tasks;
CREATE POLICY checklist_tasks_resident_denied ON checklist_tasks AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- ---------------------------------------------------------------------------
-- the default library
-- ---------------------------------------------------------------------------
--
-- The bottom two rungs of ADR-0032 §2's resolution order. Without them a firm that
-- has configured nothing fires a move-out and gets an empty list, which is the
-- product not working rather than the product being unconfigured.
--
-- Owned by the platform organisation seeded in the migrations section, and written
-- inside the same NO FORCE window that section explains: the bootstrap connects as
-- the table owner, FORCE row-level security applies to the owner, and no
-- app.tenant_id is set — so every policy here evaluates false and the insert is
-- refused. A tenant session still cannot write one of these rows: its policy's
-- write branch requires NOT is_default.
--
-- Each template's steps go in one statement so the deferred graph check sees the
-- whole graph. Fixed uuids, so a replay updates the library rather than growing a
-- second copy of it.
DO $$
DECLARE
    platform_org constant uuid := '00000000-0000-0000-0000-0000000000d8';
BEGIN
    ALTER TABLE checklist_templates      NO FORCE ROW LEVEL SECURITY;
    ALTER TABLE checklist_template_steps NO FORCE ROW LEVEL SECURITY;

    INSERT INTO checklist_templates (id, tenant_id, is_default, process, property_kind, name, published_at)
    VALUES
      ('d8000000-0000-0000-0000-000000000001', platform_org, true, 'move_in',          NULL, 'Move-in', now()),
      ('d8000000-0000-0000-0000-000000000002', platform_org, true, 'move_out',         NULL, 'Move-out', now()),
      ('d8000000-0000-0000-0000-000000000003', platform_org, true, 'owner_onboarding', NULL, 'Owner onboarding', now()),
      ('d8000000-0000-0000-0000-000000000004', platform_org, true, 'manager_handover', NULL, 'Manager handover', now()),
      ('d8000000-0000-0000-0000-000000000005', platform_org, true, 'tenancy_renewal',  NULL, 'Tenancy renewal', now()),
      -- The story's first edge case: a hostel move-out is not a commercial one. Two
      -- kind-specific rows, which is what makes the resolution order do any work.
      ('d8000000-0000-0000-0000-000000000006', platform_org, true, 'move_out', 'coliving',   'Move-out — co-living', now()),
      ('d8000000-0000-0000-0000-000000000007', platform_org, true, 'move_out', 'commercial', 'Move-out — commercial', now())
    ON CONFLICT (id) DO NOTHING;

    -- move_in. The anchor is the tenancy start; the statutory steps are dated before
    -- it because they are what makes the tenancy lawful on the day it begins.
    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'agreement_signed',  'Agreement signed by both parties', 1, true,  'manager', -7, '{}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'stamp_duty',        'Stamp duty paid and instrument stamped', 2, true, 'manager', -5, '{agreement_signed}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'deposit_received',  'Security deposit received', 3, true,  'accountant', -1, '{agreement_signed}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'police_verification','Tenant police verification submitted', 4, false, 'staff', 7, '{agreement_signed}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'entry_inspection',  'Entry inspection with photographs', 5, true,  'field_agent', 0, '{}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'meter_baseline',    'Opening meter readings recorded', 6, true,  'field_agent', 0, '{entry_inspection}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'keys_handed',       'Keys and access cards handed over', 7, true,  'field_agent', 0, '{deposit_received,entry_inspection}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'society_intimation','Society or RWA informed of the new occupant', 8, false, 'staff', 2, '{keys_handed}'),
      ('d8000000-0000-0000-0000-000000000001', platform_org, 'welcome_pack',      'Welcome pack and payment instructions sent', 9, false, 'staff', 1, '{keys_handed}')
    ON CONFLICT (template_id, code) DO NOTHING;

    -- move_out. The anchor is the date occupancy ceases. Every blocking step here is
    -- one the deposit settlement depends on being able to answer for.
    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'notice_acknowledged','Notice acknowledged and end date confirmed', 1, false, 'manager', -30, '{}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'inspection_booked',  'Exit inspection scheduled with the tenant', 2, false, 'staff', -7, '{notice_acknowledged}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'exit_inspection',    'Exit inspection with photographs', 3, true,  'field_agent', 0, '{inspection_booked}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'meter_readings',     'Closing meter readings recorded', 4, true,  'field_agent', 0, '{exit_inspection}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'keys_collected',     'Keys and access cards collected', 5, true,  'field_agent', 0, '{exit_inspection}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'utilities_closed',   'Utility accounts closed or transferred', 6, false, 'staff', 3, '{meter_readings}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'dues_settled',       'Outstanding rent and charges settled', 7, true,  'accountant', 3, '{meter_readings}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'deductions_agreed',  'Damage deductions itemised and agreed', 8, true,  'manager', 5, '{exit_inspection}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'deposit_settled',    'Deposit returned or applied', 9, true,  'accountant', 7, '{dues_settled,deductions_agreed}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'society_noc',        'Society no-objection obtained', 10, false, 'staff', 3, '{keys_collected}'),
      ('d8000000-0000-0000-0000-000000000002', platform_org, 'unit_relisted',      'Unit cleaned and made available', 11, false, 'manager', 7, '{keys_collected}')
    ON CONFLICT (template_id, code) DO NOTHING;

    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'owner_kyc',        'Owner identity verified', 1, true,  'staff', 0, '{}'),
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'ownership_proof',  'Ownership document on file', 2, true,  'staff', 2, '{}'),
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'mandate_signed',   'Management mandate signed', 3, true,  'manager', 3, '{owner_kyc,ownership_proof}'),
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'payout_account',   'Payout account added and verified', 4, true,  'accountant', 3, '{owner_kyc}'),
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'tax_facts',        'Deductor class and landlord residency recorded', 5, true, 'accountant', 3, '{mandate_signed}'),
      ('d8000000-0000-0000-0000-000000000003', platform_org, 'portfolio_loaded', 'Properties and units loaded', 6, false, 'staff', 5, '{mandate_signed}')
    ON CONFLICT (template_id, code) DO NOTHING;

    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'portfolio_listed',    'Portfolio and live tenancies listed', 1, false, 'manager', -7, '{}'),
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'deposits_reconciled', 'Deposits held reconciled and confirmed', 2, true, 'accountant', -3, '{portfolio_listed}'),
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'documents_handed',    'Agreements and documents transferred', 3, true, 'manager', 0, '{portfolio_listed}'),
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'keys_transferred',    'Keys and access transferred', 4, true, 'manager', 0, '{documents_handed}'),
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'tenants_informed',    'Tenants told who to contact', 5, false, 'staff', 1, '{keys_transferred}'),
      ('d8000000-0000-0000-0000-000000000004', platform_org, 'open_tickets',        'Open maintenance tickets handed over', 6, false, 'manager', 0, '{portfolio_listed}')
    ON CONFLICT (template_id, code) DO NOTHING;

    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'intent_confirmed', 'Both sides confirm the tenancy continues', 1, false, 'manager', -45, '{}'),
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'rent_agreed',      'Revised rent agreed', 2, true,  'manager', -30, '{intent_confirmed}'),
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'agreement_drawn',  'Successor agreement drawn', 3, true,  'manager', -14, '{rent_agreed}'),
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'agreement_signed', 'Successor agreement signed', 4, true,  'manager', -7, '{agreement_drawn}'),
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'stamp_duty',       'Stamp duty paid on the successor', 5, true,  'manager', -3, '{agreement_signed}'),
      ('d8000000-0000-0000-0000-000000000005', platform_org, 'deposit_topped_up','Deposit topped up to the revised rent', 6, false, 'accountant', 0, '{rent_agreed}')
    ON CONFLICT (template_id, code) DO NOTHING;

    -- A bed, a warden and a guardian to inform. No dilapidation, no GST.
    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'notice_acknowledged','Notice acknowledged and end date confirmed', 1, false, 'warden', -15, '{}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'guardian_informed',  'Guardian informed of the departure', 2, false, 'warden', -7, '{notice_acknowledged}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'bed_inspection',     'Bed and locker inspected', 3, true,  'warden', 0, '{}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'keys_collected',     'Room key and locker key collected', 4, true,  'warden', 0, '{bed_inspection}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'mess_settled',       'Mess and utility charges settled', 5, true,  'accountant', 2, '{bed_inspection}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'deposit_settled',    'Deposit returned or applied', 6, true,  'accountant', 5, '{mess_settled,keys_collected}'),
      ('d8000000-0000-0000-0000-000000000006', platform_org, 'bed_released',       'Bed released for reallocation', 7, false, 'warden', 1, '{keys_collected}')
    ON CONFLICT (template_id, code) DO NOTHING;

    -- A dilapidation schedule, a GST position and a fit-out to reinstate.
    INSERT INTO checklist_template_steps
        (template_id, tenant_id, code, title, position, blocking, owner_role, due_offset_days, depends_on)
    VALUES
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'notice_acknowledged','Notice acknowledged and end date confirmed', 1, false, 'manager', -90, '{}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'dilapidation',       'Dilapidation schedule agreed', 2, true,  'manager', -30, '{notice_acknowledged}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'fitout_reinstated',  'Fit-out reinstated to the agreed condition', 3, true, 'manager', -7, '{dilapidation}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'exit_inspection',    'Exit inspection with photographs', 4, true,  'field_agent', 0, '{fitout_reinstated}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'meter_readings',     'Closing meter readings recorded', 5, true,  'field_agent', 0, '{exit_inspection}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'keys_collected',     'Keys and access cards collected', 6, true,  'field_agent', 0, '{exit_inspection}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'gst_position',       'Final GST invoice raised and position closed', 7, true, 'accountant', 5, '{meter_readings}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'dues_settled',       'Outstanding rent and charges settled', 8, true,  'accountant', 5, '{gst_position}'),
      ('d8000000-0000-0000-0000-000000000007', platform_org, 'deposit_settled',    'Deposit returned or applied', 9, true,  'accountant', 10, '{dues_settled,dilapidation}')
    ON CONFLICT (template_id, code) DO NOTHING;

    -- Check the graphs now rather than at commit: ALTER TABLE refuses to run while a
    -- deferred trigger is still pending, so leaving them until commit would leave
    -- these two tables NO FORCE — row-level security off, quietly, for everybody.
    SET CONSTRAINTS checklist_template_steps_sound IMMEDIATE;

    ALTER TABLE checklist_templates      FORCE ROW LEVEL SECURITY;
    ALTER TABLE checklist_template_steps FORCE ROW LEVEL SECURITY;
END
$$;

-- ---------------------------------------------------------------------------
-- privileges
-- ---------------------------------------------------------------------------

GRANT EXECUTE ON FUNCTION checklist_delegated_read(uuid) TO dwellm8_app;

GRANT SELECT, INSERT, UPDATE ON
    checklist_templates, checklist_template_steps, checklists, checklist_tasks
    TO dwellm8_maintenance;
GRANT SELECT ON checklist_progress, checklist_stalled TO dwellm8_maintenance;

-- The lease module's role, because the gate above runs as whoever is closing the
-- tenancy. Without this the trigger raises "permission denied for table
-- checklist_tasks" on every termination once the lease module holds its own role.
GRANT SELECT ON checklists, checklist_tasks TO dwellm8_lease;
GRANT SELECT ON checklist_progress TO dwellm8_lease, dwellm8_notify, dwellm8_property;

-- These four tables are created after 180's blanket grant, so they arrive with
-- whatever ALTER DEFAULT PRIVILEGES said — which includes DELETE. Two locks, as
-- everywhere else: the RESTRICTIVE policy refuses it and the privilege is withheld,
-- so a session never reaches the policy at all.
REVOKE DELETE ON checklist_templates, checklist_template_steps,
                 checklists, checklist_tasks FROM dwellm8_app;
GRANT DELETE ON checklist_templates, checklist_template_steps,
                checklists, checklist_tasks TO dwellm8_purge;

-- A view is a table to GRANT ... ON ALL TABLES, and a progress count is not
-- writable however convincingly the privilege list claims otherwise.
REVOKE INSERT, UPDATE, DELETE ON checklist_progress, checklist_stalled FROM dwellm8_app;
