-- =============================================================================
-- Guardix DB schema — multi-tenant safety platform
-- Idempotent: safe to run repeatedly via CronJob
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extensions + permissions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

GRANT ALL ON SCHEMA public TO guardix;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO guardix;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO guardix;
GRANT ALL ON ALL TABLES IN SCHEMA public TO guardix;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO guardix;

-- ---------------------------------------------------------------------------
-- 2. tenants — schools, care-homes, employers, hostels, events
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tenants (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            VARCHAR(64)  NOT NULL UNIQUE,
    name            VARCHAR(200) NOT NULL,
    type            VARCHAR(32)  NOT NULL DEFAULT 'school'
                    CHECK (type IN ('school','care_home','employer','hostel','event')),
    country         CHAR(2)      NOT NULL DEFAULT 'IN',
    address         VARCHAR(500),
    city            VARCHAR(120),
    state           VARCHAR(120),
    postcode        VARCHAR(20),
    contact_name    VARCHAR(200),
    contact_phone   VARCHAR(20),
    contact_email   VARCHAR(200),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_tenants_deleted_at ON tenants (deleted_at);
CREATE INDEX IF NOT EXISTS idx_tenants_type       ON tenants (type) WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- 3. school_classes — academic class within a tenant (year + section)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS school_classes (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   UUID         NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    name        VARCHAR(100) NOT NULL,
    grade       VARCHAR(32),
    section     VARCHAR(32),
    year        INTEGER,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_class_tenant       ON school_classes (tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_class_year         ON school_classes (year);
CREATE INDEX IF NOT EXISTS idx_class_deleted_at   ON school_classes (deleted_at);

-- ---------------------------------------------------------------------------
-- 4. subjects — the ward (student / patient / adult)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS subjects (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL REFERENCES tenants(id)        ON DELETE CASCADE,
    class_id        UUID                  REFERENCES school_classes(id) ON DELETE SET NULL,
    type            VARCHAR(16)  NOT NULL DEFAULT 'student'
                    CHECK (type IN ('student','patient','adult')),
    full_name       VARCHAR(200) NOT NULL,
    date_of_birth   DATE,
    photo_url       VARCHAR(1000),
    blood_group     VARCHAR(8),
    roll_number     VARCHAR(64),
    notes           VARCHAR(1000),
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_subject_tenant      ON subjects (tenant_id) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_subject_class       ON subjects (class_id);
CREATE INDEX IF NOT EXISTS idx_subject_roll_number ON subjects (roll_number);
CREATE INDEX IF NOT EXISTS idx_subject_deleted_at  ON subjects (deleted_at);

-- ---------------------------------------------------------------------------
-- 5. guardians — global parents/caregivers (cross-tenant)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS guardians (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone           VARCHAR(20)  NOT NULL UNIQUE,
    email           VARCHAR(200),
    full_name       VARCHAR(200) NOT NULL,
    photo_url       VARCHAR(1000),
    locale          VARCHAR(10)  NOT NULL DEFAULT 'en-IN',
    keycloak_sub    VARCHAR(100) UNIQUE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS idx_guardians_email      ON guardians (email);
CREATE INDEX IF NOT EXISTS idx_guardians_deleted_at ON guardians (deleted_at);

-- ---------------------------------------------------------------------------
-- 6. subject_guardians — m2m link with role + notify_tier
--    A guardian can be linked to many subjects across tenants.
--    Same (subject, guardian) pair appears at most once.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS subject_guardians (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL REFERENCES tenants(id)    ON DELETE CASCADE,
    subject_id      UUID         NOT NULL REFERENCES subjects(id)   ON DELETE CASCADE,
    guardian_id     UUID         NOT NULL REFERENCES guardians(id)  ON DELETE CASCADE,
    role            VARCHAR(16)  NOT NULL DEFAULT 'primary'
                    CHECK (role IN ('primary','secondary','emergency','pickup')),
    relationship    VARCHAR(64),
    notify_tier     VARCHAR(16)  NOT NULL DEFAULT 'primary'
                    CHECK (notify_tier IN ('primary','backup','informational')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_sg_subject_guardian
    ON subject_guardians (subject_id, guardian_id) WHERE deleted_at IS NULL;
-- RISK-MISUSE.md §2: at most one primary guardian per minor
CREATE UNIQUE INDEX IF NOT EXISTS uq_sg_one_primary_per_subject
    ON subject_guardians (subject_id) WHERE role = 'primary' AND deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_sg_tenant     ON subject_guardians (tenant_id);
CREATE INDEX IF NOT EXISTS idx_sg_guardian   ON subject_guardians (guardian_id);
CREATE INDEX IF NOT EXISTS idx_sg_deleted_at ON subject_guardians (deleted_at);

-- ---------------------------------------------------------------------------
-- 7. attendance_records — per subject, per date (manual / device-sourced)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attendance_records (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID         NOT NULL REFERENCES tenants(id)  ON DELETE CASCADE,
    subject_id      UUID         NOT NULL REFERENCES subjects(id) ON DELETE CASCADE,
    date            DATE         NOT NULL,
    status          VARCHAR(16)  NOT NULL
                    CHECK (status IN ('present','late','absent','excused')),
    source          VARCHAR(16)  NOT NULL DEFAULT 'manual'
                    CHECK (source IN ('manual','uhf','ble','lte','phone')),
    note            VARCHAR(500),
    marked_by_id    UUID,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    deleted_at      TIMESTAMPTZ
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_att_subject_date
    ON attendance_records (subject_id, date) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_att_tenant_date ON attendance_records (tenant_id, date);
CREATE INDEX IF NOT EXISTS idx_att_deleted_at  ON attendance_records (deleted_at);

-- ---------------------------------------------------------------------------
-- 8. updated_at trigger — keep updated_at fresh on UPDATE
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guardix_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY[
        'tenants','school_classes','subjects','guardians',
        'subject_guardians','attendance_records'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_%I_updated_at ON %I; '
            'CREATE TRIGGER trg_%I_updated_at '
            'BEFORE UPDATE ON %I '
            'FOR EACH ROW EXECUTE FUNCTION guardix_set_updated_at();',
            t, t, t, t
        );
    END LOOP;
END$$;

-- ---------------------------------------------------------------------------
-- 9. audit_log — append-only record of every mutation + sensitive read
--    Hardened against UPDATE/DELETE via row trigger (defense in depth on top
--    of RLS). Read access gated to super_admin via app + RLS policy.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_log (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    actor_id        UUID,
    actor_role      VARCHAR(32),
    tenant_id       UUID,
    action          VARCHAR(64)  NOT NULL,
    resource        VARCHAR(64)  NOT NULL,
    resource_id     UUID,
    request_id      VARCHAR(64),
    ip_address      VARCHAR(64),
    metadata        JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_audit_actor    ON audit_log (actor_id);
CREATE INDEX IF NOT EXISTS idx_audit_tenant   ON audit_log (tenant_id);
CREATE INDEX IF NOT EXISTS idx_audit_resource ON audit_log (resource, resource_id);
CREATE INDEX IF NOT EXISTS idx_audit_created  ON audit_log (created_at DESC);

CREATE OR REPLACE FUNCTION guardix_audit_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_no_update ON audit_log;
CREATE TRIGGER trg_audit_no_update BEFORE UPDATE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION guardix_audit_immutable();
DROP TRIGGER IF EXISTS trg_audit_no_delete ON audit_log;
CREATE TRIGGER trg_audit_no_delete BEFORE DELETE ON audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION guardix_audit_immutable();

-- ---------------------------------------------------------------------------
-- 10. Row Level Security — defense in depth on top of app-layer enforcement
--    Helpers for safe GUC reads (NULLIF avoids casting empty string to uuid).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION guardix_role() RETURNS TEXT
    LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('guardix.role', true), '')
$$;

CREATE OR REPLACE FUNCTION guardix_tenant_id() RETURNS UUID
    LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('guardix.tenant_id', true), '')::uuid
$$;

CREATE OR REPLACE FUNCTION guardix_guardian_id() RETURNS UUID
    LANGUAGE sql STABLE AS $$
    SELECT NULLIF(current_setting('guardix.guardian_id', true), '')::uuid
$$;

-- ENABLE + FORCE so even the table-owning role (guardix) is bound by policy.
-- DDL by the bootstrap CronJob is unaffected (RLS only filters DML).
DO $$
DECLARE
    t TEXT;
    tables TEXT[] := ARRAY[
        'tenants','school_classes','subjects',
        'subject_guardians','attendance_records','audit_log'
    ];
BEGIN
    FOREACH t IN ARRAY tables LOOP
        EXECUTE format('ALTER TABLE %I ENABLE  ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE   ROW LEVEL SECURITY', t);
    END LOOP;
END$$;

-- super_admin sees all; school_admin / class_teacher constrained to own tenant;
-- parent has no direct access to tenants table (use the m2m below).
DROP POLICY IF EXISTS p_tenants ON tenants;
CREATE POLICY p_tenants ON tenants
    USING (
        guardix_role() = 'super_admin'
        OR (id = guardix_tenant_id())
        OR EXISTS (
            SELECT 1 FROM subject_guardians sg
            JOIN subjects s ON s.id = sg.subject_id
            WHERE s.tenant_id = tenants.id
              AND sg.guardian_id = guardix_guardian_id()
              AND sg.deleted_at IS NULL
        )
    )
    WITH CHECK (guardix_role() = 'super_admin');

DROP POLICY IF EXISTS p_school_classes ON school_classes;
CREATE POLICY p_school_classes ON school_classes
    USING (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
    )
    WITH CHECK (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
    );

DROP POLICY IF EXISTS p_subjects ON subjects;
CREATE POLICY p_subjects ON subjects
    USING (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
        OR EXISTS (
            SELECT 1 FROM subject_guardians sg
            WHERE sg.subject_id = subjects.id
              AND sg.guardian_id = guardix_guardian_id()
              AND sg.deleted_at IS NULL
        )
    )
    WITH CHECK (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
    );

DROP POLICY IF EXISTS p_subject_guardians ON subject_guardians;
CREATE POLICY p_subject_guardians ON subject_guardians
    USING (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
        OR (guardix_role() = 'parent' AND guardian_id = guardix_guardian_id())
    )
    WITH CHECK (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
    );

DROP POLICY IF EXISTS p_attendance_records ON attendance_records;
CREATE POLICY p_attendance_records ON attendance_records
    USING (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
        OR (guardix_role() = 'parent' AND subject_id IN (
            SELECT subject_id FROM subject_guardians
            WHERE guardian_id = guardix_guardian_id()
              AND deleted_at IS NULL
        ))
    )
    WITH CHECK (
        guardix_role() = 'super_admin'
        OR tenant_id = guardix_tenant_id()
    );

-- audit_log: super_admin reads; everyone writes (subject to immutability trigger)
DROP POLICY IF EXISTS p_audit_select ON audit_log;
CREATE POLICY p_audit_select ON audit_log
    FOR SELECT
    USING (guardix_role() = 'super_admin');
DROP POLICY IF EXISTS p_audit_insert ON audit_log;
CREATE POLICY p_audit_insert ON audit_log
    FOR INSERT
    WITH CHECK (true);

-- guardians table is global and intentionally unscoped — app-layer gates it.
-- Phone-uniqueness + minimal columns make this acceptable for Phase 1.
