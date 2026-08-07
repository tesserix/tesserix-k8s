-- ===========================================================================
-- viewing requests, and the letting that ends them (#331, #332)
-- ===========================================================================

-- Two things a prospect can ask for that the published times do not cover: a
-- private viewing at a time of their own, and a video walkthrough instead of an
-- attendance. Both are enquiries — the kind widens, and the proposed times live
-- in their own table because there is more than one of them and they are
-- answered one at a time.

ALTER TABLE enquiries DROP CONSTRAINT IF EXISTS enquiries_kind_check;
ALTER TABLE enquiries DROP CONSTRAINT IF EXISTS enquiries_kind_vocabulary;
ALTER TABLE enquiries ADD CONSTRAINT enquiries_kind_vocabulary CHECK (
    kind IN ('enquiry', 'inspection', 'callback', 'online_inspection'))
    NOT VALID;

-- Where the video walkthrough happens. Withheld until the viewing is confirmed,
-- the way inspection_slots.meeting_point is: a link that anybody could read is a
-- room that anybody could join.
ALTER TABLE enquiries ADD COLUMN IF NOT EXISTS meeting_link text;

-- A scheduled viewing has a time, whichever kind it is.
ALTER TABLE enquiries DROP CONSTRAINT IF EXISTS enquiries_inspection_is_scheduled;
ALTER TABLE enquiries ADD CONSTRAINT enquiries_inspection_is_scheduled CHECK (
    kind NOT IN ('inspection', 'online_inspection')
    OR state <> 'scheduled' OR scheduled_for IS NOT NULL)
    NOT VALID;

-- The vocabulary widens for the letting (#332): a viewing called off because the
-- flat is taken is neither the owner changing their mind nor the prospect
-- dropping out, and the difference is what the next appraisal reads.
ALTER TABLE enquiries DROP CONSTRAINT IF EXISTS enquiries_outcome_vocabulary;
ALTER TABLE enquiries ADD CONSTRAINT enquiries_outcome_vocabulary CHECK (
    outcome IS NULL OR outcome IN ('interested', 'not_interested', 'applied',
        'prospect_no_show', 'staff_no_show', 'cancelled_by_prospect',
        'cancelled_by_owner', 'listing_let', 'declined_by_owner'))
    NOT VALID;

-- An outcome is a viewing's — except listing_let, which closes every kind of
-- live enquiry on the listing at once, so the pipeline stops showing work that
-- no longer exists.
ALTER TABLE enquiries DROP CONSTRAINT IF EXISTS enquiries_outcome_is_inspections;
ALTER TABLE enquiries ADD CONSTRAINT enquiries_outcome_is_inspections CHECK (
    outcome IS NULL
    OR (outcome_at IS NOT NULL
        AND (kind IN ('inspection', 'online_inspection') OR outcome = 'listing_let')))
    NOT VALID;

-- A time somebody put forward. Both sides propose into the same table: the
-- prospect asks, the owner may counter once, and whoever accepts turns the row
-- into a slot. State rather than deletion, because a declined time is the
-- record of what was asked for.
CREATE TABLE IF NOT EXISTS inspection_proposals (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    enquiry_id    uuid NOT NULL REFERENCES enquiries(id),
    proposed_by   text NOT NULL CHECK (proposed_by IN ('prospect', 'owner')),
    starts_at     timestamptz NOT NULL,
    duration_mins int NOT NULL DEFAULT 30 CHECK (duration_mins BETWEEN 10 AND 240),
    state         text NOT NULL DEFAULT 'open' CHECK (state IN (
                      'open', 'accepted', 'declined', 'superseded')),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT inspection_proposals_one_accepted UNIQUE (enquiry_id, starts_at)
);

COMMENT ON TABLE inspection_proposals IS
    '#331. A time proposed for a private or online viewing, by the prospect or countered by the owner. Accepting one materialises an inspection_slot.';

CREATE INDEX IF NOT EXISTS inspection_proposals_enquiry_idx
    ON inspection_proposals (enquiry_id, starts_at);

-- The spam ceiling, in the database because the pipeline is the thing being
-- protected and the application is not the only writer of this table. Two open
-- requests on one listing is the named limit (#331).
CREATE OR REPLACE FUNCTION enquiries_request_ceiling() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    open_requests int;
BEGIN
    IF NEW.kind NOT IN ('inspection', 'online_inspection') OR NEW.slot_id IS NOT NULL THEN
        RETURN NEW;
    END IF;
    SELECT count(*) INTO open_requests
      FROM enquiries
     WHERE prospect_id = NEW.prospect_id
       AND listing_id = NEW.listing_id
       AND slot_id IS NULL
       AND kind IN ('inspection', 'online_inspection')
       AND state IN ('new', 'owner_responded');
    IF open_requests >= 2 THEN
        RAISE EXCEPTION 'a prospect may hold two open viewing requests on one listing, no more'
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS enquiries_request_ceiling_point ON enquiries;
CREATE TRIGGER enquiries_request_ceiling_point
    BEFORE INSERT ON enquiries
    FOR EACH ROW EXECUTE FUNCTION enquiries_request_ceiling();

ALTER TABLE inspection_proposals ENABLE ROW LEVEL SECURITY;
ALTER TABLE inspection_proposals FORCE  ROW LEVEL SECURITY;

-- The owner's row, reached by the prospect through a platform session — the same
-- shape as the enquiry it hangs off, and for the same reason.
DROP POLICY IF EXISTS inspection_proposals_tenant_isolation ON inspection_proposals;
CREATE POLICY inspection_proposals_tenant_isolation ON inspection_proposals
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Closed to renter sessions from birth (ADR-0029; the 220 loop ran already).
DROP POLICY IF EXISTS inspection_proposals_resident_denied ON inspection_proposals;
CREATE POLICY inspection_proposals_resident_denied ON inspection_proposals AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- What was asked for and what was answered is the letting history of the unit.
DROP POLICY IF EXISTS inspection_proposals_no_delete ON inspection_proposals;
CREATE POLICY inspection_proposals_no_delete ON inspection_proposals AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON inspection_proposals TO dwellm8_discovery;
GRANT SELECT ON inspection_proposals TO dwellm8_property;

-- Sandbox purge (170): the deny policy above is what actually gates it.
GRANT DELETE ON inspection_proposals TO dwellm8_purge;
