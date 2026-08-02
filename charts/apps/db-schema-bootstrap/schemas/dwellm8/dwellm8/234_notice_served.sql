-- ===========================================================================
-- notice served — the announcement of an ending, recorded (#239)
-- ===========================================================================

-- ADR-0010 modelled in_notice from the start; these columns record the three
-- facts the state implies: when notice was served, by which side, and the
-- move-out day it names. Terminate later copies the reality into ended_on —
-- notice announces, ended_on records.

ALTER TABLE leases ADD COLUMN IF NOT EXISTS notice_served_on  date;
ALTER TABLE leases ADD COLUMN IF NOT EXISTS notice_served_by  text;
ALTER TABLE leases ADD COLUMN IF NOT EXISTS notice_move_out_on date;

ALTER TABLE leases DROP CONSTRAINT IF EXISTS leases_notice_served_by_kind;
ALTER TABLE leases ADD CONSTRAINT leases_notice_served_by_kind CHECK (
    notice_served_by IS NULL
    OR notice_served_by IN ('owner', 'tenant', 'system', 'platform'));

-- The state cannot be reached without the facts, same shape as
-- leases_termination_shape.
ALTER TABLE leases DROP CONSTRAINT IF EXISTS leases_notice_shape;
ALTER TABLE leases ADD CONSTRAINT leases_notice_shape CHECK (
    state <> 'in_notice'
    OR (notice_served_on IS NOT NULL AND notice_served_by IS NOT NULL
        AND notice_move_out_on IS NOT NULL));

-- A move-out on or before the day notice was served is not notice.
ALTER TABLE leases DROP CONSTRAINT IF EXISTS leases_notice_window;
ALTER TABLE leases ADD CONSTRAINT leases_notice_window CHECK (
    notice_move_out_on IS NULL
    OR (notice_served_on IS NOT NULL AND notice_move_out_on > notice_served_on));
