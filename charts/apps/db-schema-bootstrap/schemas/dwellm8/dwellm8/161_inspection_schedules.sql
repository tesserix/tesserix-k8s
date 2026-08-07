-- ===========================================================================
-- inspection schedules (#330)
-- ===========================================================================

-- A recurring viewing time: "Saturdays at 10:00, four people, from the 1st".
--
-- The schedule is a pattern; inspection_slots stays the unit of booking, and
-- the pattern materialises rows into it for a rolling horizon. Booking against
-- a rule computed on the fly would leave the capacity race with nothing to
-- arbitrate — the slots' `booked <= capacity` CHECK is that arbiter and it
-- needs a row to hold.
--
-- The time is stored as a local wall clock plus an IANA zone, never as an
-- instant. Saturdays at ten must stay Saturdays at ten when the clocks change.
CREATE TABLE IF NOT EXISTS inspection_schedules (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),

    -- 0 = Sunday, as Go's time.Weekday counts.
    weekdays      smallint[] NOT NULL,
    start_time    time NOT NULL,
    zone          text NOT NULL DEFAULT 'Asia/Kolkata',
    duration_mins int NOT NULL DEFAULT 30 CHECK (duration_mins BETWEEN 10 AND 240),
    capacity      int NOT NULL DEFAULT 4 CHECK (capacity BETWEEN 1 AND 20),
    assigned_to   text,
    meeting_point text,

    starts_on     date NOT NULL,
    -- Open-ended is the normal case; the horizon job keeps it materialised.
    ends_on       date,

    state         text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'ended')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT inspection_schedules_days CHECK (
        cardinality(weekdays) BETWEEN 1 AND 7
        AND weekdays <@ ARRAY[0, 1, 2, 3, 4, 5, 6]::smallint[]),
    CONSTRAINT inspection_schedules_dates CHECK (ends_on IS NULL OR ends_on >= starts_on)
);

COMMENT ON TABLE inspection_schedules IS
    '#330. A recurring viewing time on a listing. Materialises inspection_slots for a rolling horizon; the slot, not the rule, is what a prospect books.';

CREATE INDEX IF NOT EXISTS inspection_schedules_listing_idx
    ON inspection_schedules (listing_id) WHERE state = 'active';

-- Which series a slot came from, and whether the manager has since moved or
-- cancelled that one occurrence. An overridden slot is never re-materialised
-- back into place — that flag is the whole memory of the exception.
ALTER TABLE inspection_slots ADD COLUMN IF NOT EXISTS schedule_id uuid REFERENCES inspection_schedules(id);
ALTER TABLE inspection_slots ADD COLUMN IF NOT EXISTS overridden boolean NOT NULL DEFAULT false;
-- A moved occurrence keeps its origin, so the series still knows the date is spoken for.
ALTER TABLE inspection_slots ADD COLUMN IF NOT EXISTS series_at timestamptz;

CREATE INDEX IF NOT EXISTS inspection_slots_schedule_idx
    ON inspection_slots (schedule_id, starts_at) WHERE schedule_id IS NOT NULL;
-- One slot per occurrence, whatever the override did to its time.
CREATE UNIQUE INDEX IF NOT EXISTS inspection_slots_one_per_occurrence
    ON inspection_slots (schedule_id, series_at) WHERE schedule_id IS NOT NULL;

ALTER TABLE inspection_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE inspection_schedules FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS inspection_schedules_tenant_isolation ON inspection_schedules;
CREATE POLICY inspection_schedules_tenant_isolation ON inspection_schedules
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

GRANT SELECT, INSERT, UPDATE ON inspection_schedules TO dwellm8_discovery, dwellm8_property;
