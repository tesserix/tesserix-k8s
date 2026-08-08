-- ===========================================================================
-- taking things back out: retirement, and closing a firm (#356)
-- ===========================================================================
-- A property onboarded by mistake, a bed in a room that was knocked through,
-- an owner whose mandate ended — none of them could be taken off the book, and
-- a manager could not close their own firm at all.
--
-- The ledger is append-only (ADR-0021), so this is retirement rather than
-- deletion: the row stays, its state says it is over, and it leaves the lists.
-- What the chapter adds is the two things retirement needs and did not have —
-- somewhere to record when and why, and the guards that stop a manager
-- retiring a building somebody is living in.

-- ---------------------------------------------------------------------------
-- when, and why
-- ---------------------------------------------------------------------------
ALTER TABLE properties ADD COLUMN IF NOT EXISTS retired_at     timestamptz;
ALTER TABLE properties ADD COLUMN IF NOT EXISTS retired_reason text;
ALTER TABLE units      ADD COLUMN IF NOT EXISTS retired_at     timestamptz;
ALTER TABLE units      ADD COLUMN IF NOT EXISTS retired_reason text;
ALTER TABLE beds       ADD COLUMN IF NOT EXISTS retired_at     timestamptz;
ALTER TABLE beds       ADD COLUMN IF NOT EXISTS retired_reason text;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS closed_at     timestamptz;
ALTER TABLE organisations ADD COLUMN IF NOT EXISTS closed_reason text;

-- A bed leaves the board the way a place does, rather than by deletion: who
-- slept where is the letting history of the building.
ALTER TABLE beds DROP CONSTRAINT IF EXISTS beds_state_check;
ALTER TABLE beds DROP CONSTRAINT IF EXISTS beds_state_known;
ALTER TABLE beds ADD CONSTRAINT beds_state_known CHECK (
    state IN ('vacant', 'reserved', 'occupied', 'notice', 'retired'))
    NOT VALID;

COMMENT ON COLUMN properties.retired_at IS
    '#356. When the building left the book. The row stays: its leases, its ledger and its documents still have to be readable.';

-- ---------------------------------------------------------------------------
-- what may not be retired
-- ---------------------------------------------------------------------------
-- A tenancy that has been signed but not yet started counts as live. Somebody
-- is moving in on the strength of it, and the building has to still be there.
CREATE OR REPLACE FUNCTION lease_is_live(row_state text) RETURNS boolean
    LANGUAGE sql IMMUTABLE PARALLEL SAFE AS
$$
    SELECT row_state IN ('pending_signature', 'active', 'in_notice', 'renewed')
$$;

CREATE OR REPLACE FUNCTION properties_retire_needs_vacancy() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.state = 'active' OR OLD.state <> 'active' THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM leases l
                WHERE l.property_id = NEW.id AND lease_is_live(l.state)) THEN
        RAISE EXCEPTION 'a building somebody is living in cannot be retired'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.retired_at := coalesce(NEW.retired_at, now());
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS properties_retire_needs_vacancy ON properties;
CREATE TRIGGER properties_retire_needs_vacancy BEFORE UPDATE ON properties
    FOR EACH ROW EXECUTE FUNCTION properties_retire_needs_vacancy();

CREATE OR REPLACE FUNCTION units_retire_needs_vacancy() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.state = 'active' OR OLD.state <> 'active' THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM leases l
                WHERE l.unit_id = NEW.id AND lease_is_live(l.state)) THEN
        RAISE EXCEPTION 'a home somebody is living in cannot be retired'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.retired_at := coalesce(NEW.retired_at, now());
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS units_retire_needs_vacancy ON units;
CREATE TRIGGER units_retire_needs_vacancy BEFORE UPDATE ON units
    FOR EACH ROW EXECUTE FUNCTION units_retire_needs_vacancy();

-- A bed carries its lease on the row, so its guard needs no lookup.
CREATE OR REPLACE FUNCTION beds_retire_needs_vacancy() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.state <> 'retired' OR OLD.state = 'retired' THEN
        RETURN NEW;
    END IF;
    IF NEW.lease_id IS NOT NULL THEN
        RAISE EXCEPTION 'a bed somebody sleeps in cannot be retired'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.retired_at := coalesce(NEW.retired_at, now());
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS beds_retire_needs_vacancy ON beds;
CREATE TRIGGER beds_retire_needs_vacancy BEFORE UPDATE ON beds
    FOR EACH ROW EXECUTE FUNCTION beds_retire_needs_vacancy();

-- ---------------------------------------------------------------------------
-- closing the firm itself
-- ---------------------------------------------------------------------------
-- The manager's own account is the last thing to go, and it may only go once
-- the book behind it is empty: no live tenancy anywhere, and no mandate from
-- an owner still standing. Otherwise closing an organisation would strand a
-- tenant whose rent has nowhere to be paid to.
CREATE OR REPLACE FUNCTION organisations_close_needs_an_empty_book() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.state <> 'closed' OR OLD.state = 'closed' THEN
        RETURN NEW;
    END IF;
    IF EXISTS (SELECT 1 FROM leases l
                WHERE l.tenant_id = NEW.id AND lease_is_live(l.state)) THEN
        RAISE EXCEPTION 'a firm with a live tenancy cannot be closed'
            USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM delegation_grants g
                WHERE (g.tenant_id = NEW.id OR g.grantee_org_id = NEW.id)
                  AND g.revoked_at IS NULL
                  AND (g.valid_to IS NULL OR g.valid_to > now())) THEN
        RAISE EXCEPTION 'a firm still acting under a mandate cannot be closed'
            USING ERRCODE = 'check_violation';
    END IF;
    NEW.closed_at := coalesce(NEW.closed_at, now());
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS organisations_close_needs_an_empty_book ON organisations;
CREATE TRIGGER organisations_close_needs_an_empty_book BEFORE UPDATE ON organisations
    FOR EACH ROW EXECUTE FUNCTION organisations_close_needs_an_empty_book();

COMMENT ON COLUMN organisations.closed_at IS
    '#356. A closed firm keeps its history and signs its people out. Starting again is a new organisation, never a revived one.';
