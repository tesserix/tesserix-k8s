-- ===========================================================================
-- documents — what got uploaded to GCS, and who may see it
-- ===========================================================================
-- The object itself lives in the app's GCS bucket (internal/platform/blob),
-- keyed by organisation under a per-app bucket for isolation. This table is
-- the only record that the object exists and which property it belongs to —
-- a bucket listing is not an authorization boundary, this row is.
--
-- Property-scoped, not lease-scoped: a fire NOC or an executed agreement
-- outlives the tenancy it was signed under, and the owner's document list is
-- read per property, not per lease.

CREATE TABLE IF NOT EXISTS documents (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    property_id   uuid NOT NULL,
    -- The GCS object path this row describes, e.g. "org/<tenant_id>/documents/<uuid>.pdf".
    -- Unique because two rows for one object would let one be deleted while
    -- the other still claims read access to it.
    object_path   text NOT NULL UNIQUE CHECK (btrim(object_path) <> ''),
    filename      text NOT NULL CHECK (btrim(filename) <> ''),
    content_type  text NOT NULL CHECK (btrim(content_type) <> ''),
    -- The session's principal. Text for the reason activity_notes.author is:
    -- until #229 lands a party uuid on the request principal, a label is
    -- what there is.
    uploaded_by   text NOT NULL CHECK (btrim(uploaded_by) <> ''),
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT documents_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS documents_property_idx ON documents (property_id, created_at DESC);

ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE  ROW LEVEL SECURITY;

-- Same shape as blocks_tenant_isolation: a property-scoped delegation grant
-- reaches the documents on that property, not the whole portfolio.
DROP POLICY IF EXISTS documents_tenant_isolation ON documents;
CREATE POLICY documents_tenant_isolation ON documents
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.write'));

-- A document row is a record that an upload happened; correcting it means
-- uploading again; sandbox purge is the only deletion path, same as
-- properties_no_delete.
DROP POLICY IF EXISTS documents_no_delete ON documents;
CREATE POLICY documents_no_delete ON documents AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS documents_no_update ON documents;
CREATE POLICY documents_no_update ON documents AS RESTRICTIVE FOR UPDATE USING (false);

GRANT SELECT, INSERT ON documents TO dwellm8_property;
