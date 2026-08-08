-- ===========================================================================
-- The managers a firm employs, and the workload each one carries (#353)
-- ===========================================================================
--
-- Chapter 100 already says a person may act for an organisation, and with what
-- coarse role. That is the tenancy boundary and it stays exactly as coarse as
-- it is. This chapter is the employment beside it: who they are to the firm,
-- what the firm calls their job, which properties are theirs, and when they
-- work.
--
-- The split matters. organisation_members answers "may this sign-in act here",
-- which authentication needs on every request. staff_members answers "what is
-- this person's designation and salary", which almost nothing needs and which
-- carries payroll data. Putting the second in the first would put a salary on
-- the hot path of every authorisation check.

-- ---------------------------------------------------------------------------
-- roles the firm defines for itself
-- ---------------------------------------------------------------------------
--
-- A firm does not think in five roles; it thinks in "Senior Property Manager"
-- and "Field Executive". So the name is the firm's, and what it may do is a
-- subset of chapter 010's delegation vocabulary — the same closed list, because
-- a role that could grant something the firm itself cannot do would be a way
-- around the mandate.
--
-- property_limit is the reason this table exists rather than a text column on
-- the member: the cap is a property of the job, not of the person. A firm
-- raising its field executives from five to eight changes one row.
CREATE TABLE IF NOT EXISTS staff_roles (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id      uuid NOT NULL REFERENCES organisations(id),
    name           citext NOT NULL CHECK (btrim(name) <> ''),
    permissions    text[] NOT NULL,
    -- How many properties somebody in this job may hold at once. The point of
    -- the feature: a manager with forty properties maintains none of them.
    property_limit int NOT NULL DEFAULT 6 CHECK (property_limit BETWEEN 1 AND 50),
    -- Retired rather than deleted: the people who held it keep pointing here.
    retired_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT staff_roles_name_unique UNIQUE (tenant_id, name),
    CONSTRAINT staff_roles_perms CHECK (
        cardinality(permissions) > 0 AND permissions <@ ARRAY[
            'property.read',    'property.write',
            'lease.read',       'lease.write',
            'money.read',       'money.collect', 'money.payout',
            'maintenance.read', 'maintenance.write',
            'document.read',    'document.write',
            'community.read',   'community.write'
        ]::text[])
);

COMMENT ON TABLE staff_roles IS
    '#353. A job the firm defines, carrying a subset of chapter 010''s permission vocabulary and a cap on how many properties it may hold.';

ALTER TABLE staff_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_roles FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_roles_tenant_isolation ON staff_roles;
CREATE POLICY staff_roles_tenant_isolation ON staff_roles
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS staff_roles_resident_denied ON staff_roles;
CREATE POLICY staff_roles_resident_denied ON staff_roles AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS staff_roles_no_delete ON staff_roles;
CREATE POLICY staff_roles_no_delete ON staff_roles AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON staff_roles TO dwellm8_identity;
GRANT SELECT ON staff_roles TO dwellm8_property, dwellm8_lease, dwellm8_maintenance;
GRANT DELETE ON staff_roles TO dwellm8_purge;

-- ---------------------------------------------------------------------------
-- the employment record
-- ---------------------------------------------------------------------------
--
-- One row per person the firm employs. party_id is the same person identity
-- chapter 100 uses, so a sub-manager who is also a tenant somewhere is one
-- person with two memberships, not two people.
--
-- On the identifiers, which is the part that has to be got right:
--
--   PAN      masked, exactly as manager_profiles.pan_masked is. The firm needs
--            to know it holds one; it never needs the digits back.
--   Aadhaar  not here, in any form. Chapter 070's kyc_verifications already
--            holds an Aadhaar check against a party, with a masked reference, a
--            provider transaction and the consent artefact DPDP requires — all
--            of which an employment record would have to grow to hold one
--            honestly. A second home for the same identifier is the one that
--            ends up holding the number.
--   salary   payroll. Minor units like every other amount in this schema, and
--            granted separately below: the people who run the firm read it,
--            colleagues do not.
CREATE TABLE IF NOT EXISTS staff_members (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    party_id        uuid NOT NULL,
    role_id         uuid REFERENCES staff_roles(id),

    full_name       text NOT NULL CHECK (btrim(full_name) <> ''),
    -- The firm's own reference, on the payslip and the ID card.
    employee_code   citext,
    designation     text,

    email           citext,
    phone           text CHECK (phone IS NULL OR phone ~ '^\+[1-9][0-9]{7,14}$'),

    employment_type text NOT NULL DEFAULT 'full_time' CHECK (employment_type IN (
                        'full_time', 'part_time', 'contract', 'intern')),
    joined_on       date NOT NULL DEFAULT current_date,
    exited_on       date,

    -- Masked like every other identifier of its class. ADR-0013 §2.
    pan_masked      text CHECK (pan_masked IS NULL OR pan_masked ~ '^X+[0-9A-Z]{4}$'),

    salary_minor    bigint CHECK (salary_minor IS NULL OR salary_minor >= 0),
    salary_currency char(3) NOT NULL DEFAULT 'INR',
    pay_frequency   text NOT NULL DEFAULT 'monthly' CHECK (pay_frequency IN (
                        'monthly', 'fortnightly', 'weekly', 'daily')),

    emergency_name  text,
    emergency_phone text CHECK (emergency_phone IS NULL OR emergency_phone ~ '^\+[1-9][0-9]{7,14}$'),

    -- invited  — the record exists, the person has not signed in yet.
    -- active   — working, and assignable.
    -- suspended— still employed, temporarily holds nothing.
    -- exited   — left. Their assignments are closed, their history is not.
    state           text NOT NULL DEFAULT 'invited' CHECK (state IN (
                        'invited', 'active', 'suspended', 'exited')),

    -- Overrides the role's cap for one person, for the senior who genuinely
    -- carries more. NULL means the role decides, which is the normal case.
    property_limit  int CHECK (property_limit IS NULL OR property_limit BETWEEN 1 AND 50),

    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,

    CONSTRAINT staff_members_one_per_party UNIQUE (tenant_id, party_id),
    CONSTRAINT staff_members_code_unique   UNIQUE (tenant_id, employee_code),
    CONSTRAINT staff_members_exit_after_joining CHECK (
        exited_on IS NULL OR exited_on >= joined_on),
    -- Somebody who has left has a leaving date, and somebody who has not, has not.
    CONSTRAINT staff_members_exit_is_dated CHECK (
        (state = 'exited') = (exited_on IS NOT NULL)),
    -- A contact route is what an invitation is sent down; a record with neither
    -- can never become a sign-in.
    CONSTRAINT staff_members_reachable CHECK (email IS NOT NULL OR phone IS NOT NULL)
);

COMMENT ON TABLE staff_members IS
    '#353. The employment record of somebody a firm employs. Identity checks live in kyc_verifications, not here (ADR-0013 §2); salary is granted separately from the rest.';

CREATE INDEX IF NOT EXISTS staff_members_active_idx
    ON staff_members (tenant_id, state) WHERE state <> 'exited';

ALTER TABLE staff_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_members FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_members_tenant_isolation ON staff_members;
CREATE POLICY staff_members_tenant_isolation ON staff_members
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A renter has no business reading their manager's payroll.
DROP POLICY IF EXISTS staff_members_resident_denied ON staff_members;
CREATE POLICY staff_members_resident_denied ON staff_members AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- Somebody who left is history: the assignments and the audit rows point here.
DROP POLICY IF EXISTS staff_members_no_delete ON staff_members;
CREATE POLICY staff_members_no_delete ON staff_members AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON staff_members TO dwellm8_identity;
-- Deliberately narrow: the modules that route work to a person need the name
-- and the state, and reach them through the assignment below.
GRANT SELECT ON staff_members TO dwellm8_property, dwellm8_maintenance;
GRANT DELETE ON staff_members TO dwellm8_purge;

-- ---------------------------------------------------------------------------
-- which properties are whose
-- ---------------------------------------------------------------------------
--
-- Effective dated rather than overwritten, for the reason every other
-- membership here is: the question after a dispute is who was responsible for
-- that building *then*.
CREATE TABLE IF NOT EXISTS staff_assignments (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The firm. Its staff are its own, so this row stays in its tenant even
    -- though the property it names belongs to the owner.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    staff_id      uuid NOT NULL REFERENCES staff_members(id),
    property_id   uuid NOT NULL REFERENCES properties(id),
    -- Whose property it is, which is the grantor of the mandate that lets the
    -- firm touch it at all. Without it the policy below could not ask whether
    -- this firm may manage this building, and a firm could put its staff
    -- against any property id it could guess. Equal to tenant_id when the firm
    -- manages its own (#268).
    owner_tenant_id uuid NOT NULL REFERENCES organisations(id),

    valid_from    date NOT NULL DEFAULT current_date,
    valid_to      date,
    validity      daterange GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,

    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,

    -- Equal ends the window the day it opened: rows are never deleted, so a
    -- same-day correction has to be expressible.
    CONSTRAINT staff_assignments_window CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

COMMENT ON TABLE staff_assignments IS
    '#353. The property one manager is responsible for, for a window. Capped by staff_assignments_within_cap: a warning in application code is not a cap.';

-- One manager per property at a time. A building with two people responsible
-- has nobody responsible.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'staff_assignments_one_manager') THEN
        ALTER TABLE staff_assignments ADD CONSTRAINT staff_assignments_one_manager
            EXCLUDE USING gist (tenant_id WITH =, property_id WITH =, validity WITH &&);
    END IF;
END
$$;

CREATE INDEX IF NOT EXISTS staff_assignments_staff_idx
    ON staff_assignments (tenant_id, staff_id, valid_from DESC);

-- The cap, enforced where it cannot be forgotten.
--
-- In the database rather than the service because two managers assigning the
-- same person concurrently both read a count below the limit and both write —
-- the check and the insert have to be one statement under one lock, and that is
-- what a constraint trigger is. The limit is the person's override, else their
-- role's, else the default a role carries.
CREATE OR REPLACE FUNCTION staff_assignment_within_cap() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    cap  int;
    held int;
    who  text;
BEGIN
    SELECT COALESCE(m.property_limit, r.property_limit, 6), m.full_name
      INTO cap, who
      FROM staff_members m
      LEFT JOIN staff_roles r ON r.id = m.role_id
     WHERE m.id = NEW.staff_id;

    SELECT count(*) INTO held
      FROM staff_assignments a
     WHERE a.staff_id = NEW.staff_id
       AND (a.valid_to IS NULL OR a.valid_to > current_date);

    IF held > cap THEN
        RAISE EXCEPTION 'staff_assignments_over_cap: % already holds % properties, the most this role allows', who, cap
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS staff_assignments_within_cap ON staff_assignments;
CREATE CONSTRAINT TRIGGER staff_assignments_within_cap
    AFTER INSERT OR UPDATE ON staff_assignments
    FOR EACH ROW EXECUTE FUNCTION staff_assignment_within_cap();

ALTER TABLE staff_assignments ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_assignments FORCE  ROW LEVEL SECURITY;

-- Two conditions, not one: the row is this firm's, *and* the firm holds the
-- property. Passing property_id to is_delegated is what stops a mandate scoped
-- to two flats being used to staff the owner's whole portfolio (999, rule 5).
DROP POLICY IF EXISTS staff_assignments_tenant_isolation ON staff_assignments;
CREATE POLICY staff_assignments_tenant_isolation ON staff_assignments
    USING      (is_platform_session() OR (tenant_id = current_tenant_id()
                AND (owner_tenant_id = current_tenant_id()
                     OR is_delegated(owner_tenant_id, property_id, 'property.read'))))
    WITH CHECK (is_platform_session() OR (tenant_id = current_tenant_id()
                AND (owner_tenant_id = current_tenant_id()
                     OR is_delegated(owner_tenant_id, property_id, 'property.write'))));

DROP POLICY IF EXISTS staff_assignments_resident_denied ON staff_assignments;
CREATE POLICY staff_assignments_resident_denied ON staff_assignments AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS staff_assignments_no_delete ON staff_assignments;
CREATE POLICY staff_assignments_no_delete ON staff_assignments AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON staff_assignments TO dwellm8_identity, dwellm8_property;
GRANT SELECT ON staff_assignments TO dwellm8_lease, dwellm8_maintenance;
GRANT DELETE ON staff_assignments TO dwellm8_purge;

-- ---------------------------------------------------------------------------
-- when they work
-- ---------------------------------------------------------------------------
--
-- A weekly rota, not a calendar: the question this answers is "may a viewing be
-- offered at 4pm on Thursday", and that is the same answer every Thursday.
-- One-off absence is leave, which is a different feature and not this one.
CREATE TABLE IF NOT EXISTS staff_shifts (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES organisations(id),
    staff_id    uuid NOT NULL REFERENCES staff_members(id),

    -- ISO-8601: Monday is 1, Sunday is 7. Postgres's own dow puts Sunday at 0,
    -- which reads as a bug every time somebody sorts by it.
    weekday     int NOT NULL CHECK (weekday BETWEEN 1 AND 7),
    starts_at   time NOT NULL,
    ends_at     time NOT NULL,

    created_at  timestamptz NOT NULL DEFAULT now(),

    -- A shift ending before it starts is a typo. Overnight cover is two rows,
    -- one on each day, which is also how it is paid.
    CONSTRAINT staff_shifts_window CHECK (ends_at > starts_at),
    CONSTRAINT staff_shifts_no_duplicate UNIQUE (staff_id, weekday, starts_at)
);

COMMENT ON TABLE staff_shifts IS
    '#353. A weekly working window, so a viewing is not offered for somebody who is off. Overnight cover is two rows.';

CREATE INDEX IF NOT EXISTS staff_shifts_rota_idx
    ON staff_shifts (tenant_id, staff_id, weekday);

ALTER TABLE staff_shifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_shifts FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS staff_shifts_tenant_isolation ON staff_shifts;
CREATE POLICY staff_shifts_tenant_isolation ON staff_shifts
    USING      (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS staff_shifts_resident_denied ON staff_shifts;
CREATE POLICY staff_shifts_resident_denied ON staff_shifts AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- A rota is edited, so a dropped shift is genuinely gone rather than history.
DROP POLICY IF EXISTS staff_shifts_no_delete ON staff_shifts;
CREATE POLICY staff_shifts_no_delete ON staff_shifts AS RESTRICTIVE FOR DELETE
    USING (tenant_id = current_tenant_id() OR sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON staff_shifts TO dwellm8_identity;
GRANT SELECT ON staff_shifts TO dwellm8_property, dwellm8_maintenance;
GRANT DELETE ON staff_shifts TO dwellm8_purge;
