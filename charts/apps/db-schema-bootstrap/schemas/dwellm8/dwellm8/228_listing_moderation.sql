-- 228: listing moderation (#143). A suspended state moderation alone can lift,
-- and the report columns the queue reads. No new tables: the listings policies
-- from 160 already scope every row here.

ALTER TABLE listings ADD COLUMN IF NOT EXISTS reported_at timestamptz;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS report_count integer NOT NULL DEFAULT 0;
ALTER TABLE listings ADD COLUMN IF NOT EXISTS suspended_reason text;

-- Rebuild the state check with 'suspended'. Drop-and-add keeps the replay
-- idempotent; the constraint is cheap to revalidate at this cardinality.
ALTER TABLE listings DROP CONSTRAINT IF EXISTS listings_state_check;
ALTER TABLE listings ADD CONSTRAINT listings_state_check CHECK (state IN (
    'draft', 'live', 'paused', 'let', 'withdrawn', 'suspended'));

-- A suspension records why; owner-driven states carry no moderation reason.
ALTER TABLE listings DROP CONSTRAINT IF EXISTS listings_suspended_has_reason;
ALTER TABLE listings ADD CONSTRAINT listings_suspended_has_reason CHECK (
    state <> 'suspended' OR suspended_reason IS NOT NULL);

-- A suspended listing still holds the unit's advertising slot: reinstatement
-- must not race a second advert for the same flat.
DROP INDEX IF EXISTS listings_one_live_per_unit;
CREATE UNIQUE INDEX IF NOT EXISTS listings_one_live_per_unit
    ON listings (tenant_id, unit_id) WHERE state IN ('live', 'paused', 'suspended');

CREATE INDEX IF NOT EXISTS listings_moderation_queue_idx
    ON listings (tenant_id, reported_at) WHERE reported_at IS NOT NULL OR state = 'suspended';
