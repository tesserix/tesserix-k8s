-- 229: saved searches (#144). A prospect's own criteria, platform-held like
-- the shortlist, with the watermark that stops an alert repeating itself.

CREATE TABLE IF NOT EXISTS saved_searches (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    prospect_id    uuid NOT NULL REFERENCES prospects(id),
    city           text NOT NULL,
    locality       text,
    max_rent_minor bigint  CHECK (max_rent_minor IS NULL OR max_rent_minor > 0),
    bedrooms       integer CHECK (bedrooms IS NULL OR (bedrooms >= 0 AND bedrooms <= 20)),
    alerts_enabled boolean NOT NULL DEFAULT true,
    -- The no-resend promise: an alert covers listings published after this,
    -- and viewing the results advances it.
    last_seen_at   timestamptz NOT NULL DEFAULT now(),
    created_at     timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE saved_searches IS
    '#144. Survives sign-up the same way the shortlist does: the prospect row is kept, not replaced.';

-- Saving the same criteria twice is the same search.
CREATE UNIQUE INDEX IF NOT EXISTS saved_searches_dedupe
    ON saved_searches (prospect_id, city, coalesce(locality, ''),
                       coalesce(max_rent_minor, 0), coalesce(bedrooms, -1));

ALTER TABLE saved_searches ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_searches FORCE  ROW LEVEL SECURITY;

-- A prospect belongs to nobody: platform sessions only, like prospects itself.
DROP POLICY IF EXISTS saved_searches_platform_only ON saved_searches;
CREATE POLICY saved_searches_platform_only ON saved_searches
    USING (is_platform_session()) WITH CHECK (is_platform_session());

-- Closed to renter sessions from birth (ADR-0029; the 220 loop ran already).
DROP POLICY IF EXISTS saved_searches_resident_denied ON saved_searches;
CREATE POLICY saved_searches_resident_denied ON saved_searches AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

GRANT SELECT, INSERT, UPDATE, DELETE ON saved_searches TO dwellm8_discovery;
