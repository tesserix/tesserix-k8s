-- ===========================================================================
-- document_templates — the agreements a firm issues, and the kind of the
-- documents it holds (#341, #339)
-- ===========================================================================
-- The .docx itself lives in the app's GCS bucket, same as documents: this
-- table is the record that it exists, which kind of instrument it is, and
-- whether it is the platform's version or a firm's revision of it.
--
-- is_default marks the platform library, on checklist_templates' model: those
-- rows belong to the platform organisation, are readable by any signed-in
-- organisation and writable only by a platform session. A firm that never
-- edits a template keeps receiving the platform one, including its later
-- corrections.

CREATE TABLE IF NOT EXISTS document_templates (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    is_default    boolean NOT NULL DEFAULT false,

    kind          text NOT NULL CHECK (kind IN (
                      'management_agreement', 'onboarding_checklist',
                      'rent_agreement', 'lease_deed', 'power_of_attorney')),
    -- The instruments are jurisdictional: stamp duty, registration and the
    -- witness requirement are state law, and 'IN' is the national baseline.
    jurisdiction  char(2) NOT NULL DEFAULT 'IN',

    name          text NOT NULL CHECK (btrim(name) <> ''),
    version       int NOT NULL DEFAULT 1 CHECK (version > 0),

    object_path   text NOT NULL UNIQUE CHECK (btrim(object_path) <> ''),
    filename      text NOT NULL CHECK (btrim(filename) <> ''),
    content_type  text NOT NULL CHECK (btrim(content_type) <> ''),

    -- Declared, so generation can refuse an unknown placeholder rather than
    -- printing "{{owner_name}}" into a document somebody signs.
    merge_fields  text[] NOT NULL DEFAULT '{}',

    published_at  timestamptz,
    -- A revision supersedes rather than replaces: what was issued last year is
    -- what last year's signature was against.
    superseded_at timestamptz,

    uploaded_by   text NOT NULL CHECK (btrim(uploaded_by) <> ''),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT document_templates_superseded_after_published CHECK (
        superseded_at IS NULL OR published_at IS NOT NULL)
);

COMMENT ON TABLE document_templates IS
    '#341. One instrument per organisation, kind and jurisdiction. is_default marks the platform library.';

-- One live template per organisation, kind and jurisdiction. Two live
-- management agreements is two answers to what the firm actually issues.
CREATE UNIQUE INDEX IF NOT EXISTS document_templates_live_idx
    ON document_templates (tenant_id, kind, jurisdiction)
    WHERE superseded_at IS NULL;

CREATE INDEX IF NOT EXISTS document_templates_resolve_idx
    ON document_templates (kind, jurisdiction, tenant_id)
    WHERE superseded_at IS NULL AND published_at IS NOT NULL;

-- A superseded row is evidence of what was issued, so only its lifecycle dates
-- may move afterwards. Rewriting the object behind an issued instrument is the
-- failure this exists to stop.
CREATE OR REPLACE FUNCTION document_templates_are_immutable() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.tenant_id IS DISTINCT FROM OLD.tenant_id
       OR NEW.kind IS DISTINCT FROM OLD.kind
       OR NEW.jurisdiction IS DISTINCT FROM OLD.jurisdiction
       OR NEW.version IS DISTINCT FROM OLD.version
       OR NEW.object_path IS DISTINCT FROM OLD.object_path
       OR NEW.merge_fields IS DISTINCT FROM OLD.merge_fields THEN
        RAISE EXCEPTION 'a document template is superseded, not edited: write a new version'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.updated_at := now();
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS document_templates_immutable ON document_templates;
CREATE TRIGGER document_templates_immutable
    BEFORE UPDATE ON document_templates
    FOR EACH ROW EXECUTE FUNCTION document_templates_are_immutable();

ALTER TABLE document_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE document_templates FORCE  ROW LEVEL SECURITY;

-- Read your own and the library; write only your own, and never a default —
-- otherwise a firm could publish a clause into every other firm's agreements.
DROP POLICY IF EXISTS document_templates_tenant_isolation ON document_templates;
CREATE POLICY document_templates_tenant_isolation ON document_templates
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR (is_default AND current_tenant_id() IS NOT NULL))
    WITH CHECK ((tenant_id = current_tenant_id() AND NOT is_default)
           OR is_platform_session());

DROP POLICY IF EXISTS document_templates_no_delete ON document_templates;
CREATE POLICY document_templates_no_delete ON document_templates AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- ADR-0029. A renter signs an agreement; they do not browse the firm's stock
-- of blank instruments.
DROP POLICY IF EXISTS document_templates_resident_denied ON document_templates;
CREATE POLICY document_templates_resident_denied ON document_templates AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

GRANT SELECT, INSERT, UPDATE ON document_templates TO dwellm8_property;
GRANT SELECT ON document_templates TO dwellm8_identity, dwellm8_lease;
GRANT DELETE ON document_templates TO dwellm8_purge;

-- ---------------------------------------------------------------------------
-- what a stored document is
-- ---------------------------------------------------------------------------
-- Until now every upload was an untyped blob, so "is the title deed on file"
-- could not be asked (#339). ALTER rather than a rewrite of 300_documents.sql,
-- which is already applied everywhere.
ALTER TABLE documents ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE documents ADD COLUMN IF NOT EXISTS template_id uuid REFERENCES document_templates(id);

-- NOT VALID: enforced for every new write, never revalidated against the rows
-- that predate the vocabulary — which also keeps the half-hourly replay from
-- scanning the table.
ALTER TABLE documents DROP CONSTRAINT IF EXISTS documents_kind_known;
ALTER TABLE documents ADD CONSTRAINT documents_kind_known CHECK (kind IS NULL OR kind IN (
    -- The owner's right to let (PMA 8.1, checklist §B).
    'title_deed', 'mother_deed', 'tax_receipt', 'encumbrance_certificate',
    'khata_patta', 'occupancy_certificate', 'society_noc', 'lender_noc',
    'power_of_attorney',
    -- What the firm and the owner signed, and what the tenant signed.
    'management_agreement', 'rent_agreement', 'lease_deed',
    -- Condition and handover.
    'inspection_report', 'utility_bill', 'insurance_policy', 'floor_plan',
    'other')) NOT VALID;

CREATE INDEX IF NOT EXISTS documents_kind_idx
    ON documents (property_id, kind) WHERE kind IS NOT NULL;

-- ---------------------------------------------------------------------------
-- the default library
-- ---------------------------------------------------------------------------
-- The India instruments every firm starts from. Written inside the same
-- NO FORCE window the checklist library uses and for the same reason: the
-- bootstrap connects as the table owner with no app.tenant_id, so every policy
-- here would otherwise evaluate false.
--
-- object_path names where the .docx is expected in the bucket; the file itself
-- is uploaded out of band, and a template whose object is missing fails at
-- download rather than silently issuing an empty agreement.
DO $$
DECLARE
    platform_org constant uuid := '00000000-0000-0000-0000-0000000000d8';
BEGIN
    ALTER TABLE document_templates NO FORCE ROW LEVEL SECURITY;

    INSERT INTO document_templates
        (id, tenant_id, is_default, kind, jurisdiction, name, object_path, filename,
         content_type, merge_fields, published_at, uploaded_by)
    VALUES
      ('d8100000-0000-0000-0000-000000000001', platform_org, true, 'management_agreement', 'IN',
       'Property management agreement — India',
       'platform/templates/in/property-management-agreement-v1.docx',
       'Property-Management-Agreement-INDIA-TEMPLATE.docx',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       '{owner_name,owner_address,owner_pan,manager_name,manager_address,manager_rera,
         property_address,property_description,term_months,commencement_date,
         management_fee_pct,repair_ceiling,sale_notice_months,execution_place,execution_date}',
       now(), 'platform'),
      ('d8100000-0000-0000-0000-000000000002', platform_org, true, 'onboarding_checklist', 'IN',
       'Owner and manager onboarding checklist — India',
       'platform/templates/in/owner-manager-onboarding-checklist-v1.docx',
       'Owner-Manager-Onboarding-CHECKLIST-INDIA.docx',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       '{owner_name,property_address,manager_name,prepared_on}',
       now(), 'platform'),
      ('d8100000-0000-0000-0000-000000000003', platform_org, true, 'rent_agreement', 'IN',
       'Rent agreement, eleven months — India',
       'platform/templates/in/rent-agreement-11-months-v1.docx',
       '1-Rent-Agreement-11-months-INDIA.docx',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       '{landlord_name,landlord_address,tenant_name,tenant_address,property_address,
         rent_amount,deposit_amount,commencement_date,term_months,notice_days,
         execution_place,execution_date}',
       now(), 'platform'),
      ('d8100000-0000-0000-0000-000000000004', platform_org, true, 'lease_deed', 'IN',
       'Registered lease deed, twelve to eighteen months — India',
       'platform/templates/in/lease-deed-registered-v1.docx',
       '2-Lease-Deed-REGISTERED-12-18-months-INDIA.docx',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       '{lessor_name,lessor_address,lessee_name,lessee_address,property_address,
         rent_amount,deposit_amount,commencement_date,term_months,
         stamp_duty_amount,registration_office,execution_place,execution_date}',
       now(), 'platform'),
      ('d8100000-0000-0000-0000-000000000005', platform_org, true, 'power_of_attorney', 'IN',
       'Limited power of attorney — India',
       'platform/templates/in/power-of-attorney-limited-v1.docx',
       '3-Power-of-Attorney-LIMITED-INDIA.docx',
       'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
       '{principal_name,principal_address,attorney_name,attorney_address,
         property_address,powers_granted,valid_from,valid_to,
         execution_place,execution_date}',
       now(), 'platform')
    ON CONFLICT (id) DO NOTHING;

    ALTER TABLE document_templates FORCE ROW LEVEL SECURITY;
END
$$;
