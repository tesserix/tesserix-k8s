-- ===========================================================================
-- activity notes — the human lines in the feed (#196)
-- ===========================================================================
-- The activity feed itself is the outbox read back; it owns no table. What a
-- feed of facts cannot carry is the aside a colleague leaves on a record —
-- "tenant travelling until the 12th, don't chase" — and that is this table.
--
-- visibility is who may read it: org stays on the landlord side, shared also
-- reaches the renter on that lease. An allowlist decision per note, made by
-- its author, defaulting closed.
CREATE TABLE IF NOT EXISTS activity_notes (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    subject_kind  text NOT NULL,
    subject_id    text NOT NULL,
    -- The session's principal. Text rather than a party uuid for the reason
    -- the outbox carries system actors today: until #229 lands a party uuid
    -- on the request principal, a label is what there is.
    author        text NOT NULL CHECK (btrim(author) <> ''),
    body          text NOT NULL CHECK (btrim(body) <> '' AND length(body) <= 4000),
    visibility    text NOT NULL DEFAULT 'org' CHECK (visibility IN ('org', 'shared')),
    noted_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT activity_notes_subject_present CHECK (btrim(subject_kind) <> '' AND btrim(subject_id) <> '')
);

CREATE INDEX IF NOT EXISTS activity_notes_subject_idx
    ON activity_notes (tenant_id, subject_kind, subject_id, noted_at DESC);

ALTER TABLE activity_notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE activity_notes FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS activity_notes_tenant_isolation ON activity_notes;
CREATE POLICY activity_notes_tenant_isolation ON activity_notes
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());
-- Append-only: a correction is another note, so history shows the correction
-- rather than losing the thing corrected — #196's edge case, structurally.
DROP POLICY IF EXISTS activity_notes_no_delete ON activity_notes;
CREATE POLICY activity_notes_no_delete ON activity_notes AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS activity_notes_no_update ON activity_notes;
CREATE POLICY activity_notes_no_update ON activity_notes AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON activity_notes TO dwellm8_community;
