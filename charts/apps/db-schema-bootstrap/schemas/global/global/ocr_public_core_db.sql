CREATE TYPE ocr_job_status AS ENUM ('accepted', 'inspecting', 'processing', 'validating', 'cancelling', 'cancelled', 'rejected', 'partial', 'review_required', 'completed');
CREATE TYPE ocr_upload_status AS ENUM ('reserved', 'uploaded', 'inspecting', 'accepted', 'rejected', 'expired');

CREATE TABLE ocr_uploads (
    upload_id TEXT PRIMARY KEY CHECK (upload_id ~ '^upl_[A-Za-z0-9_]{1,64}$'),
    tenant_id TEXT NOT NULL CHECK (tenant_id ~ '^ten_[A-Za-z0-9_]{1,64}$'),
    product_id TEXT NOT NULL CHECK (product_id ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
    idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 128),
    request_digest TEXT NOT NULL CHECK (request_digest ~ '^sha256:[a-f0-9]{64}$'),
    object_bucket TEXT NOT NULL CHECK (length(object_bucket) BETWEEN 3 AND 63),
    object_name TEXT NOT NULL CHECK (length(object_name) BETWEEN 1 AND 1024),
    expected_content_type TEXT NOT NULL CHECK (expected_content_type IN ('application/pdf', 'image/jpeg', 'image/png', 'image/tiff', 'image/webp')),
    expected_content_length BIGINT NOT NULL CHECK (expected_content_length BETWEEN 1 AND 104857600),
    expected_digest TEXT NOT NULL CHECK (expected_digest ~ '^sha256:[a-f0-9]{64}$'),
    status ocr_upload_status NOT NULL DEFAULT 'reserved',
    expires_at TIMESTAMPTZ NOT NULL,
    object_generation BIGINT CHECK (object_generation > 0),
    verified_content_type TEXT CHECK (verified_content_type IN ('application/pdf', 'image/jpeg', 'image/png', 'image/tiff', 'image/webp')),
    verified_content_length BIGINT CHECK (verified_content_length BETWEEN 1 AND 104857600),
    verified_digest TEXT CHECK (verified_digest ~ '^sha256:[a-f0-9]{64}$'),
    uploaded_at TIMESTAMPTZ,
    source_bucket TEXT CHECK (length(source_bucket) BETWEEN 3 AND 63),
    source_object_name TEXT CHECK (length(source_object_name) BETWEEN 1 AND 1024),
    source_object_generation BIGINT CHECK (source_object_generation > 0),
    source_digest TEXT CHECK (source_digest ~ '^sha256:[a-f0-9]{64}$'),
    source_content_length BIGINT CHECK (source_content_length BETWEEN 1 AND 104857600),
    accepted_at TIMESTAMPTZ,
    inspection_attempts INTEGER NOT NULL DEFAULT 0 CHECK (inspection_attempts BETWEEN 0 AND 10),
    inspection_lease_owner TEXT CHECK (length(inspection_lease_owner) BETWEEN 1 AND 128),
    inspection_lease_expires_at TIMESTAMPTZ,
    rejection_reason TEXT CHECK (rejection_reason IN ('inspection_attempts_exhausted', 'malware_detected', 'invalid_document', 'parser_limits_exceeded', 'password_required', 'source_conflict')),
    parser_page_count INTEGER CHECK (parser_page_count BETWEEN 1 AND 300),
    parser_maximum_page_pixels BIGINT CHECK (parser_maximum_page_pixels BETWEEN 1 AND 100000000),
    parser_total_page_pixels BIGINT CHECK (parser_total_page_pixels BETWEEN 1 AND 1000000000),
    parser_profile TEXT CHECK (length(parser_profile) BETWEEN 1 AND 64),
    parser_version TEXT CHECK (length(parser_version) BETWEEN 1 AND 64),
    parser_page_geometries JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, tenant_id, idempotency_key),
    UNIQUE (object_bucket, object_name),
    UNIQUE (upload_id, product_id, tenant_id)
);

CREATE TABLE ocr_jobs (
    job_id TEXT PRIMARY KEY CHECK (job_id ~ '^job_[A-Za-z0-9_]{1,64}$'),
    tenant_id TEXT NOT NULL CHECK (tenant_id ~ '^ten_[A-Za-z0-9_]{1,64}$'),
    product_id TEXT NOT NULL CHECK (product_id ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
    idempotency_key TEXT NOT NULL CHECK (length(idempotency_key) BETWEEN 1 AND 128),
    request_digest TEXT NOT NULL CHECK (request_digest ~ '^sha256:[a-f0-9]{64}$'),
    upload_id TEXT CHECK (upload_id ~ '^upl_[A-Za-z0-9_]{1,64}$'),
    webhook_subscription_id TEXT CHECK (webhook_subscription_id ~ '^whs_[A-Za-z0-9_]{1,64}$'),
    extraction_schema_id TEXT,
    extraction_schema_version TEXT,
    status ocr_job_status NOT NULL DEFAULT 'accepted',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (product_id, tenant_id, idempotency_key),
    UNIQUE (job_id, product_id, tenant_id),
    CONSTRAINT ocr_jobs_extraction_schema_shape CHECK ((extraction_schema_id IS NULL AND extraction_schema_version IS NULL) OR (extraction_schema_id IS NOT NULL AND extraction_schema_version IS NOT NULL AND length(extraction_schema_id) BETWEEN 1 AND 128 AND length(extraction_schema_version) BETWEEN 1 AND 64)),
    FOREIGN KEY (upload_id, product_id, tenant_id) REFERENCES ocr_uploads (upload_id, product_id, tenant_id) ON DELETE RESTRICT
);

CREATE TABLE ocr_results (
    job_id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    document_id TEXT NOT NULL CHECK (document_id ~ '^doc_[A-Za-z0-9_]{1,64}$'),
    document_version TEXT NOT NULL CHECK (document_version ~ '^sha256:[a-f0-9]{64}$'),
    object_bucket TEXT NOT NULL CHECK (length(object_bucket) BETWEEN 3 AND 222),
    object_name TEXT NOT NULL CHECK (length(object_name) BETWEEN 1 AND 1024),
    object_generation BIGINT NOT NULL CHECK (object_generation > 0),
    object_digest TEXT NOT NULL CHECK (object_digest ~ '^sha256:[a-f0-9]{64}$'),
    content_type TEXT NOT NULL DEFAULT 'application/json' CHECK (content_type = 'application/json'),
    content_length BIGINT NOT NULL CHECK (content_length BETWEEN 1 AND 16777216),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (job_id, product_id, tenant_id) REFERENCES ocr_jobs (job_id, product_id, tenant_id) ON DELETE RESTRICT
);

CREATE TABLE ocr_outbox (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    job_id TEXT NOT NULL REFERENCES ocr_jobs(job_id) ON DELETE RESTRICT,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ,
    delivery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (delivery_attempts BETWEEN 0 AND 20),
    delivery_lease_owner TEXT CHECK (length(delivery_lease_owner) BETWEEN 1 AND 128),
    delivery_lease_expires_at TIMESTAMPTZ,
    dead_lettered_at TIMESTAMPTZ
);

CREATE TABLE ocr_upload_outbox (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    upload_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    published_at TIMESTAMPTZ,
    FOREIGN KEY (upload_id, product_id, tenant_id) REFERENCES ocr_uploads (upload_id, product_id, tenant_id) ON DELETE RESTRICT
);

CREATE TABLE ocr_page_workflows (
    job_id TEXT PRIMARY KEY,
    product_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    workflow_schema_version SMALLINT NOT NULL DEFAULT 1 CHECK (workflow_schema_version = 1),
    revision BIGINT NOT NULL DEFAULT 0 CHECK (revision >= 0),
    checkpoint JSONB NOT NULL CHECK (jsonb_typeof(checkpoint) = 'object' AND octet_length(checkpoint::text) BETWEEN 1 AND 262144),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    FOREIGN KEY (job_id, product_id, tenant_id) REFERENCES ocr_jobs (job_id, product_id, tenant_id) ON DELETE RESTRICT
);

CREATE TABLE ocr_page_artifacts (
    job_id TEXT NOT NULL,
    product_id TEXT NOT NULL,
    tenant_id TEXT NOT NULL,
    page_number INTEGER NOT NULL CHECK (page_number BETWEEN 1 AND 300),
    attempt SMALLINT NOT NULL CHECK (attempt BETWEEN 1 AND 10),
    activity_key TEXT NOT NULL CHECK (length(activity_key) BETWEEN 1 AND 160),
    object_bucket TEXT NOT NULL CHECK (length(object_bucket) BETWEEN 3 AND 222),
    object_name TEXT NOT NULL CHECK (length(object_name) BETWEEN 1 AND 1024),
    object_generation BIGINT NOT NULL CHECK (object_generation > 0),
    object_digest TEXT NOT NULL CHECK (object_digest ~ '^sha256:[a-f0-9]{64}$'),
    content_length BIGINT NOT NULL CHECK (content_length BETWEEN 1 AND 16777216),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (job_id, page_number),
    UNIQUE (job_id, activity_key),
    FOREIGN KEY (job_id, product_id, tenant_id) REFERENCES ocr_jobs (job_id, product_id, tenant_id) ON DELETE RESTRICT
);

CREATE TABLE ocr_work_scopes (
    product_id TEXT NOT NULL CHECK (product_id ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
    tenant_id TEXT NOT NULL CHECK (tenant_id ~ '^ten_[A-Za-z0-9_]{1,64}$'),
    upload_pending BOOLEAN NOT NULL DEFAULT false,
    dispatch_pending BOOLEAN NOT NULL DEFAULT false,
    lease_owner TEXT CHECK (length(lease_owner) BETWEEN 1 AND 128),
    lease_expires_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, tenant_id)
);

CREATE INDEX ocr_uploads_scope_created_idx ON ocr_uploads (product_id, tenant_id, created_at DESC, upload_id DESC);
ALTER TABLE ocr_jobs ADD COLUMN IF NOT EXISTS extraction_schema_id TEXT, ADD COLUMN IF NOT EXISTS extraction_schema_version TEXT;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'ocr_jobs_extraction_schema_shape') THEN
    ALTER TABLE ocr_jobs ADD CONSTRAINT ocr_jobs_extraction_schema_shape CHECK ((extraction_schema_id IS NULL AND extraction_schema_version IS NULL) OR (extraction_schema_id IS NOT NULL AND extraction_schema_version IS NOT NULL AND length(extraction_schema_id) BETWEEN 1 AND 128 AND length(extraction_schema_version) BETWEEN 1 AND 64));
  END IF;
END $$;

CREATE INDEX ocr_jobs_scope_created_idx ON ocr_jobs (product_id, tenant_id, created_at DESC, job_id DESC);
CREATE INDEX ocr_jobs_upload_scope_idx ON ocr_jobs (product_id, tenant_id, upload_id) WHERE upload_id IS NOT NULL;
CREATE INDEX ocr_results_document_version_idx ON ocr_results (product_id, tenant_id, document_id, document_version);
CREATE INDEX ocr_outbox_claimable_idx ON ocr_outbox (product_id, tenant_id, event_id) WHERE published_at IS NULL AND dead_lettered_at IS NULL;
CREATE INDEX ocr_upload_outbox_unpublished_idx ON ocr_upload_outbox (event_id) WHERE published_at IS NULL;
CREATE INDEX ocr_work_scopes_lease_idx ON ocr_work_scopes (lease_expires_at, updated_at, product_id, tenant_id);

CREATE OR REPLACE FUNCTION ocr_register_work_scope(scope_product_id TEXT, scope_tenant_id TEXT, work_kind TEXT) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  INSERT INTO public.ocr_work_scopes (product_id, tenant_id, upload_pending, dispatch_pending)
  SELECT scope_product_id, scope_tenant_id, work_kind = 'upload', work_kind = 'dispatch'
  WHERE work_kind IN ('upload', 'dispatch')
  ON CONFLICT (product_id, tenant_id) DO UPDATE SET upload_pending = public.ocr_work_scopes.upload_pending OR excluded.upload_pending, dispatch_pending = public.ocr_work_scopes.dispatch_pending OR excluded.dispatch_pending, updated_at = now()
$$;
CREATE OR REPLACE FUNCTION ocr_set_work_scope_pending(scope_product_id TEXT, scope_tenant_id TEXT, work_kind TEXT, is_pending BOOLEAN) RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  UPDATE public.ocr_work_scopes SET upload_pending = CASE WHEN work_kind = 'upload' THEN is_pending ELSE upload_pending END, dispatch_pending = CASE WHEN work_kind = 'dispatch' THEN is_pending ELSE dispatch_pending END, updated_at = now() WHERE product_id = scope_product_id AND tenant_id = scope_tenant_id AND work_kind IN ('upload', 'dispatch')
$$;
CREATE OR REPLACE FUNCTION ocr_claim_work_scopes(claim_owner TEXT, claim_limit INTEGER) RETURNS TABLE (product_id TEXT, tenant_id TEXT) LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
BEGIN
  IF claim_owner !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' OR claim_limit NOT BETWEEN 1 AND 100 THEN RAISE EXCEPTION 'invalid work scope claim'; END IF;
  RETURN QUERY WITH candidates AS (SELECT scopes.product_id, scopes.tenant_id FROM public.ocr_work_scopes AS scopes WHERE (scopes.lease_owner = claim_owner OR scopes.lease_expires_at IS NULL OR scopes.lease_expires_at <= now()) AND (scopes.upload_pending OR scopes.dispatch_pending) ORDER BY scopes.updated_at, scopes.product_id, scopes.tenant_id FOR UPDATE SKIP LOCKED LIMIT claim_limit), claimed AS (UPDATE public.ocr_work_scopes AS scopes SET lease_owner = claim_owner, lease_expires_at = now() + interval '5 minutes', updated_at = now() FROM candidates WHERE scopes.product_id = candidates.product_id AND scopes.tenant_id = candidates.tenant_id RETURNING scopes.product_id, scopes.tenant_id) SELECT claimed.product_id, claimed.tenant_id FROM claimed;
END;
$$;
CREATE OR REPLACE FUNCTION ocr_release_work_scope(scope_product_id TEXT, scope_tenant_id TEXT, claim_owner TEXT) RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, public AS $$
  UPDATE public.ocr_work_scopes SET lease_owner = NULL, lease_expires_at = NULL, updated_at = now() WHERE product_id = scope_product_id AND tenant_id = scope_tenant_id AND lease_owner = claim_owner AND lease_expires_at > now() RETURNING true
$$;

DO $$ DECLARE table_name TEXT; BEGIN
  FOREACH table_name IN ARRAY ARRAY['ocr_uploads', 'ocr_jobs', 'ocr_results', 'ocr_outbox', 'ocr_upload_outbox', 'ocr_page_workflows', 'ocr_page_artifacts'] LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', table_name);
    EXECUTE format('CREATE POLICY %I ON %I USING (tenant_id = current_setting(''app.tenant_id'', true) AND product_id = current_setting(''app.product_id'', true)) WITH CHECK (tenant_id = current_setting(''app.tenant_id'', true) AND product_id = current_setting(''app.product_id'', true))', table_name || '_scope', table_name);
  END LOOP;
END $$;

DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ocr_public_core') THEN
    GRANT CONNECT ON DATABASE ocr_public_core_db TO ocr_public_core;
    GRANT USAGE ON SCHEMA public TO ocr_public_core;
    GRANT SELECT, INSERT, UPDATE, DELETE ON ocr_uploads, ocr_jobs, ocr_results, ocr_outbox, ocr_upload_outbox, ocr_page_workflows, ocr_page_artifacts TO ocr_public_core;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ocr_public_core;
    GRANT EXECUTE ON FUNCTION ocr_claim_work_scopes(TEXT, INTEGER), ocr_release_work_scope(TEXT, TEXT, TEXT), ocr_register_work_scope(TEXT, TEXT, TEXT), ocr_set_work_scope_pending(TEXT, TEXT, TEXT, BOOLEAN) TO ocr_public_core;
  END IF;
END $$;

DO $sandbox_migration$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'ocr_uploads' AND column_name = 'object_version') THEN
    EXECUTE $sandbox_sql$
set lock_timeout = '5s';
set statement_timeout = '30s';

-- Expand only: legacy readers/writers retain numeric GCS generations.
alter table ocr_uploads
    add column object_version text check (length(object_version) between 1 and 1024 and object_version ~ '^[!-~]+$' and object_version <> 'null'),
    add column source_object_version text check (length(source_object_version) between 1 and 1024 and source_object_version ~ '^[!-~]+$' and source_object_version <> 'null');
alter table ocr_results
    add column object_version text check (length(object_version) between 1 and 1024 and object_version ~ '^[!-~]+$' and object_version <> 'null'),
    alter column object_generation drop not null,
    add constraint ocr_results_version_present check (object_version is not null or object_generation is not null);
alter table ocr_page_artifacts
    add column object_version text check (length(object_version) between 1 and 1024 and object_version ~ '^[!-~]+$' and object_version <> 'null'),
    alter column object_generation drop not null,
    add constraint ocr_page_artifacts_version_present check (object_version is not null or object_generation is not null);

create function ocr_sync_object_version() returns trigger language plpgsql as $$
begin
    if new.object_version is null then
        new.object_version := new.object_generation::text;
    elsif new.object_version ~ '^[1-9][0-9]{0,18}$'
        and length(new.object_version) <= 19
        and new.object_version::numeric <= 9223372036854775807 then
        if new.object_generation is not null and new.object_generation::text <> new.object_version then
            raise exception 'inconsistent object version';
        end if;
        new.object_generation := new.object_version::bigint;
    elsif new.object_generation is not null then
        raise exception 'inconsistent object version';
    end if;
    return new;
end;
$$;

create function ocr_sync_source_version() returns trigger language plpgsql as $$
begin
    if new.source_object_version is null then
        new.source_object_version := new.source_object_generation::text;
    elsif new.source_object_version ~ '^[1-9][0-9]{0,18}$'
        and length(new.source_object_version) <= 19
        and new.source_object_version::numeric <= 9223372036854775807 then
        if new.source_object_generation is not null and new.source_object_generation::text <> new.source_object_version then
            raise exception 'inconsistent source version';
        end if;
        new.source_object_generation := new.source_object_version::bigint;
    elsif new.source_object_generation is not null then
        raise exception 'inconsistent source version';
    end if;
    return new;
end;
$$;

create trigger ocr_uploads_version_sync before insert or update on ocr_uploads
    for each row execute function ocr_sync_object_version();
create trigger ocr_uploads_source_version_sync before insert or update on ocr_uploads
    for each row execute function ocr_sync_source_version();
create trigger ocr_results_version_sync before insert or update on ocr_results
    for each row execute function ocr_sync_object_version();
create trigger ocr_page_artifacts_version_sync before insert or update on ocr_page_artifacts
    for each row execute function ocr_sync_object_version();

alter table ocr_uploads drop constraint if exists ocr_uploads_verification_complete;
alter table ocr_uploads add constraint ocr_uploads_verification_complete check (
    (status in ('reserved', 'expired') and object_generation is null and object_version is null
        and verified_content_type is null and verified_content_length is null
        and verified_digest is null and uploaded_at is null)
    or
    (status in ('uploaded', 'inspecting', 'accepted', 'rejected')
        and coalesce(object_version, object_generation::text) is not null
        and verified_content_type is not null and verified_content_length is not null
        and verified_digest is not null and uploaded_at is not null
        and verified_content_type = expected_content_type
        and verified_content_length = expected_content_length
        and verified_digest = expected_digest)
) not valid;
alter table ocr_uploads validate constraint ocr_uploads_verification_complete;

alter table ocr_uploads drop constraint if exists ocr_uploads_accepted_source_complete;
alter table ocr_uploads add constraint ocr_uploads_accepted_source_complete check (
    (status = 'accepted' and source_bucket is not null and source_object_name is not null
        and coalesce(source_object_version, source_object_generation::text) is not null
        and source_digest = verified_digest and source_content_length = verified_content_length
        and accepted_at is not null)
    or
    (status <> 'accepted' and source_bucket is null and source_object_name is null
        and source_object_generation is null and source_object_version is null
        and source_digest is null and source_content_length is null and accepted_at is null)
) not valid;
alter table ocr_uploads validate constraint ocr_uploads_accepted_source_complete;
alter table ocr_uploads drop constraint ocr_uploads_source_bucket_check;
alter table ocr_uploads add constraint ocr_uploads_source_bucket_check
    check (char_length(source_bucket) between 3 and 222) not valid;
alter table ocr_uploads validate constraint ocr_uploads_source_bucket_check;
alter table ocr_uploads drop constraint ocr_uploads_object_bucket_check;
alter table ocr_uploads add constraint ocr_uploads_object_bucket_check
    check (char_length(object_bucket) between 3 and 222) not valid;
alter table ocr_uploads validate constraint ocr_uploads_object_bucket_check;

$sandbox_sql$;
  END IF;
END $sandbox_migration$;
REVOKE CONNECT ON DATABASE ocr_public_core_db FROM PUBLIC;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
