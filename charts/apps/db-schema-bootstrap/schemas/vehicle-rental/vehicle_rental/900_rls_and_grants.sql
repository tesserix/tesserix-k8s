-- ===========================================================================
-- 900 RLS and grants — last, so every table exists to be covered
-- ===========================================================================
--
-- Every tenant-owned table gets the same treatment, applied by loop rather than
-- by hand: ENABLE plus FORCE row level security, and one policy comparing
-- tenant_id to current_tenant_id().
--
-- FORCE is the half people forget. Without it the table owner — which is the
-- migration role, and any role that inherits it — reads every tenant's rows,
-- and the isolation holds only for roles nobody actually connects as.
--
-- A table gains RLS by having a tenant_id column. Adding a table in a later
-- chapter therefore protects it automatically; forgetting to list it here
-- cannot leave it open.

DO $$
DECLARE
    t record;
BEGIN
    FOR t IN
        SELECT c.relname AS table_name, n.nspname AS schema_name
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
        WHERE c.relkind = 'r'
          AND NOT a.attisdropped
          AND n.nspname IN ('identity','catalog','pricing','availability','booking',
                            'handover','payments','kyc','telematics','maintenance',
                            'incidents','partners','trips','storefront','support',
                            'audit','financial_archive')
          -- Partitions inherit the parent's policies; covering them separately
          -- would create one redundant policy per month, forever.
          AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = c.oid)
    LOOP
        EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', t.schema_name, t.table_name);
        EXECUTE format('ALTER TABLE %I.%I FORCE  ROW LEVEL SECURITY', t.schema_name, t.table_name);
        EXECUTE format('DROP POLICY IF EXISTS tenant_isolation ON %I.%I', t.schema_name, t.table_name);
        EXECUTE format(
            'CREATE POLICY tenant_isolation ON %I.%I
                 USING (tenant_id = current_tenant_id() OR is_platform_scope())
                 WITH CHECK (tenant_id = current_tenant_id() OR is_platform_scope())',
            t.schema_name, t.table_name);
    END LOOP;
END
$$;

-- identity.tenant is the exception, and deliberately so: onboarding creates a
-- tenant row before any tenant context exists, so the platform role must be
-- able to insert without app.tenant_id being set. The USING half still scopes
-- reads to the caller's own tenant.
DROP POLICY IF EXISTS tenant_isolation ON identity.tenant;
DROP POLICY IF EXISTS tenant_self_read ON identity.tenant;
CREATE POLICY tenant_self_read ON identity.tenant
    FOR SELECT USING (id = current_tenant_id() OR is_platform_scope());
DROP POLICY IF EXISTS tenant_platform_write ON identity.tenant;
CREATE POLICY tenant_platform_write ON identity.tenant
    FOR ALL USING (is_platform_scope()) WITH CHECK (is_platform_scope());

-- --- grants ----------------------------------------------------------------

GRANT USAGE ON SCHEMA identity, catalog, pricing, availability, booking, handover,
                      payments, kyc, telematics, maintenance, incidents, partners,
                      trips, storefront, support, audit, financial_archive
    TO vehicle_rental_app, vehicle_rental_platform_role, vehicle_rental_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA
    identity, catalog, pricing, availability, booking, handover, payments, kyc,
    telematics, maintenance, incidents, partners, trips, storefront, support
    TO vehicle_rental_app;

GRANT SELECT, INSERT ON ALL TABLES IN SCHEMA audit, financial_archive
    TO vehicle_rental_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA
    identity, catalog, pricing, availability, booking, handover, payments, kyc,
    telematics, maintenance, incidents, partners, trips, storefront, support,
    audit, financial_archive
    TO vehicle_rental_platform_role;

-- Reporting reads everything and writes nothing. It is not exempt from RLS, so
-- an analyst still sees one tenant per connection unless a platform-role
-- transaction opts out — the credential is narrower, not a side door.
GRANT SELECT ON ALL TABLES IN SCHEMA
    identity, catalog, pricing, availability, booking, handover, payments, kyc,
    telematics, maintenance, incidents, partners, trips, storefront, support,
    audit, financial_archive
    TO vehicle_rental_readonly;

-- Append-only means append-only. These three are the record of what happened;
-- a correction is a new row, never an edit to an old one.
REVOKE UPDATE, DELETE ON audit.entry              FROM vehicle_rental_app, vehicle_rental_platform_role;
REVOKE UPDATE, DELETE ON payments.ledger_entry    FROM vehicle_rental_app, vehicle_rental_platform_role;
REVOKE UPDATE, DELETE ON booking.booking_event    FROM vehicle_rental_app, vehicle_rental_platform_role;

-- Tables created by a later replay of this schema must land with the same
-- grants, or a new table silently works for the owner and 42501s for the app.
DO $$
DECLARE
    s text;
BEGIN
    FOREACH s IN ARRAY ARRAY[
        'identity','catalog','pricing','availability','booking','handover',
        'payments','kyc','telematics','maintenance','incidents','partners',
        'trips','storefront','support'
    ] LOOP
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES IN SCHEMA %I
                 GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES
                 TO vehicle_rental_app, vehicle_rental_platform_role', s);
    END LOOP;
    FOREACH s IN ARRAY ARRAY['audit','financial_archive'] LOOP
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES IN SCHEMA %I
                 GRANT SELECT, INSERT ON TABLES TO vehicle_rental_app', s);
    END LOOP;
    FOREACH s IN ARRAY ARRAY[
        'identity','catalog','pricing','availability','booking','handover',
        'payments','kyc','telematics','maintenance','incidents','partners',
        'trips','storefront','support','audit','financial_archive'
    ] LOOP
        EXECUTE format(
            'ALTER DEFAULT PRIVILEGES IN SCHEMA %I
                 GRANT SELECT ON TABLES TO vehicle_rental_readonly', s);
    END LOOP;
END
$$;

-- The two login roles are created by CNPG's managed.roles, not here — creating
-- them would fight the operator every reconcile. This only hands them their
-- membership, and only once they exist.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vehicle_rental_api') THEN
        GRANT vehicle_rental_app TO vehicle_rental_api;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vehicle_rental_platform') THEN
        GRANT vehicle_rental_platform_role TO vehicle_rental_platform;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vehicle_rental_reporting') THEN
        GRANT vehicle_rental_readonly TO vehicle_rental_reporting;
    END IF;
END
$$;

-- --- assertions ------------------------------------------------------------
-- These fail the bootstrap loudly rather than letting a violated invariant sit
-- in production until it is a support ticket.

DO $$
DECLARE
    unprotected text;
BEGIN
    SELECT string_agg(format('%s.%s', n.nspname, c.relname), ', ')
      INTO unprotected
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid AND a.attname = 'tenant_id'
     WHERE c.relkind = 'r'
       AND NOT a.attisdropped
       AND NOT EXISTS (SELECT 1 FROM pg_inherits WHERE inhrelid = c.oid)
       AND n.nspname NOT IN ('pg_catalog','information_schema')
       AND NOT (c.relrowsecurity AND c.relforcerowsecurity);

    IF unprotected IS NOT NULL THEN
        RAISE EXCEPTION 'tables carry tenant_id without forced RLS: %', unprotected;
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'reservation_no_overlap' AND contype = 'x'
    ) THEN
        RAISE EXCEPTION 'availability.reservation has no exclusion constraint — double-booking is possible';
    END IF;
END
$$;

-- RLS is only a boundary while no connecting role can step over or around it.
-- Both halves matter: BYPASSRLS ignores the policies, and table ownership lets
-- a role turn them off with one ALTER TABLE.
DO $$
DECLARE
    offender text;
BEGIN
    SELECT string_agg(rolname, ', ') INTO offender
      FROM pg_roles
     WHERE rolcanlogin
       AND rolname LIKE 'vehicle\_rental%'
       AND (rolbypassrls OR rolsuper);
    IF offender IS NOT NULL THEN
        RAISE EXCEPTION 'login roles exempt from RLS: %', offender;
    END IF;

    FOREACH offender IN ARRAY ARRAY['vehicle_rental_api','vehicle_rental_reporting'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = offender)
           AND pg_has_role(offender, 'vehicle_rental', 'MEMBER') THEN
            RAISE EXCEPTION '% inherits the owner role and can disable RLS', offender;
        END IF;
    END LOOP;
END
$$;

-- Reporting is a read credential. If it ever gains a write, it stops being the
-- safe thing to hand an analyst and becomes a second API role.
DO $$
DECLARE
    writable text;
BEGIN
    SELECT string_agg(DISTINCT format('%s.%s', table_schema, table_name), ', ')
      INTO writable
      FROM information_schema.role_table_grants
     WHERE grantee = 'vehicle_rental_readonly'
       AND privilege_type IN ('INSERT','UPDATE','DELETE','TRUNCATE');
    IF writable IS NOT NULL THEN
        RAISE EXCEPTION 'vehicle_rental_readonly can write: %', writable;
    END IF;
END
$$;
