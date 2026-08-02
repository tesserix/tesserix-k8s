-- ===========================================================================
-- listing media (#136)
-- ===========================================================================

-- Photographs on a listing. The object lives in GCS (dwellm8-find-assets,
-- org-prefixed paths, platform/blob); this table is what turns a bucket into
-- an authorisation boundary: which listing a photo belongs to, in what order,
-- which one is the cover, and whether moderation has taken it down.
--
-- Public delivery is the API's act, not a bucket ACL: a guest receives
-- short-lived signed URLs, and only for the live media of a live, published
-- listing. An unpublished listing's photographs are as private as the flat.

CREATE TABLE IF NOT EXISTS listing_media (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),

    object_path   text NOT NULL,
    content_type  text NOT NULL CHECK (content_type IN ('image/jpeg', 'image/png', 'image/webp')),

    -- Ordering is deliberate: position 0 is the cover, and reordering is an
    -- update to these integers, not a re-upload.
    position      int NOT NULL DEFAULT 0 CHECK (position BETWEEN 0 AND 23),

    -- Moderation (#136's takedown): live serves, reported queues, removed is
    -- gone from public delivery immediately and audited by the columns below.
    state         text NOT NULL DEFAULT 'live' CHECK (state IN ('live', 'reported', 'removed')),
    reported_at   timestamptz,
    removed_at    timestamptz,
    removed_reason text,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT listing_media_removed_shape CHECK (
        (state = 'removed') = (removed_at IS NOT NULL)),
    -- One row per object: a re-record of the same upload is idempotent.
    CONSTRAINT listing_media_object_unique UNIQUE (listing_id, object_path)
);

COMMENT ON TABLE listing_media IS
    '#136. A photo''s membership, order and moderation state; the bytes live in GCS and a guest only ever gets a short-lived signed URL for live media of a live listing.';

CREATE INDEX IF NOT EXISTS listing_media_listing_idx
    ON listing_media (listing_id, position) WHERE state <> 'removed';
CREATE INDEX IF NOT EXISTS listing_media_reported_idx
    ON listing_media (tenant_id, reported_at) WHERE state = 'reported';

ALTER TABLE listing_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_media FORCE  ROW LEVEL SECURITY;

-- Tenant isolation plus the platform session for the anonymous read path —
-- like enquiries, not like listings: no public branch (assertion 17), a
-- guest's photo URLs are minted by the API through the platform session.
DROP POLICY IF EXISTS listing_media_tenant_isolation ON listing_media;
CREATE POLICY listing_media_tenant_isolation ON listing_media
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- Closed to renter sessions from birth (ADR-0029; the 220 loop ran already).
DROP POLICY IF EXISTS listing_media_resident_denied ON listing_media;
CREATE POLICY listing_media_resident_denied ON listing_media AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- Removed media rows are the takedown audit; they do not get deleted.
DROP POLICY IF EXISTS listing_media_no_delete ON listing_media;
CREATE POLICY listing_media_no_delete ON listing_media AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON listing_media TO dwellm8_discovery, dwellm8_property;
