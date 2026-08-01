-- ===========================================================================
-- property, block and unit
-- ===========================================================================

-- ADR-0009. One hierarchy for a standalone house, a four-flat building, a
-- 240-flat society tower, a shop and a parking slot:
--
--   property  → block (optional) → unit → ancillary unit (parking, storage)
--
-- tenant_id is whoever holds the tree. For a landlord's own flats that is the
-- owner's organisation; for a society it is the society, and an individual flat
-- owner is a separate organisation that reaches their flat through a grant the
-- society issues. Ownership is therefore not tenancy — see ADR-0009's
-- consequences, which say plainly what that costs.

CREATE TABLE IF NOT EXISTS properties (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    -- The owner-facing short code. citext so 'GK-2' and 'gk-2' collide rather
    -- than becoming two buildings.
    code            citext NOT NULL,
    name            text NOT NULL,
    kind            text NOT NULL CHECK (kind IN (
                        'standalone', 'building', 'society', 'commercial', 'coliving', 'plot')),

    -- Indian addressing. Two-line street address, then the administrative
    -- hierarchy that every statutory form asks for in this order.
    address_line1   text NOT NULL,
    address_line2   text,
    locality        text NOT NULL,
    city            text NOT NULL,
    district        text,
    -- ISO 3166-2:IN subdivision code. Named state_code, not state, because
    -- `state` is this file's word for a lifecycle — organisations.state, and the
    -- column below. The collision is unfortunate; the naming is the mitigation.
    state_code      char(2) NOT NULL CHECK (state_code IN (
                        'AN','AP','AR','AS','BR','CH','CT','DH','DL','GA','GJ','HP',
                        'HR','JH','JK','KA','KL','LA','LD','MH','ML','MN','MP','MZ',
                        'NL','OR','PB','PY','RJ','SK','TG','TN','TR','UP','UT','WB')),
    -- Indian PIN codes never start with zero, which makes a leading-zero PIN a
    -- transcription error rather than a valid code.
    pin             char(6) NOT NULL CHECK (pin ~ '^[1-9][0-9]{5}$'),
    latitude        numeric(9,6) CHECK (latitude BETWEEN -90 AND 90),
    longitude       numeric(9,6) CHECK (longitude BETWEEN -180 AND 180),
    -- Geocoding is an assertion about the world and can be wrong or stale, so
    -- it records where it came from rather than pretending to be a fact.
    geocoded_at     timestamptz,
    geocode_source  text CHECK (geocode_source IN ('manual', 'provider', 'import')),

    -- External identifiers. Every one of these is issued by somebody else, so
    -- none is unique here: two flats can share an electricity meter, and a
    -- municipal id can be reassigned after a subdivision.
    municipal_tax_id        text,
    rera_id                 text,
    society_registration_no text,

    state           text NOT NULL DEFAULT 'active'
                    CHECK (state IN ('active', 'inactive', 'disposed')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT properties_code_unique UNIQUE (tenant_id, code),
    -- Redundant against the primary key, and load-bearing anyway: it is the
    -- target of the composite foreign keys below, which is how a block or a
    -- unit is prevented from attaching to another organisation's property.
    CONSTRAINT properties_tenant_id_unique UNIQUE (id, tenant_id)
);

COMMENT ON COLUMN properties.state_code IS
    'ISO 3166-2:IN subdivision code — MH, KA, DL. The GST numeric code is a lookup, not this column (ADR-0007).';

CREATE INDEX IF NOT EXISTS properties_tenant_idx ON properties (tenant_id, state);
CREATE INDEX IF NOT EXISTS properties_pin_idx    ON properties (pin);

-- A wing, a tower, a phase. Optional: a standalone house has none, and forcing
-- a synthetic "Block A" onto it is the special-casing this model exists to
-- avoid.
CREATE TABLE IF NOT EXISTS blocks (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    property_id     uuid NOT NULL,
    code            citext NOT NULL,
    name            text,
    floors          int CHECK (floors > 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT blocks_code_unique     UNIQUE (property_id, code),
    CONSTRAINT blocks_tenant_id_unique UNIQUE (id, tenant_id),
    -- Composite, not a plain reference to properties(id): this is what makes
    -- tenant_id agree with the parent's. A plain foreign key would let a
    -- delegated session hang a block off another organisation's property and
    -- keep its own tenant_id on the row, which every policy in this file would
    -- then read as its own.
    CONSTRAINT blocks_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id)
);

CREATE INDEX IF NOT EXISTS blocks_property_idx ON blocks (property_id);

-- The unit. Everything downstream — a lease, a due, a ticket, a meter — points
-- here.
--
-- Parking and storage are units with a parent, not a second table. A slot
-- allotted to flat 1204 carries parent_unit_id = that flat; an unallotted slot
-- has none. Reassignment is an UPDATE, and the history of who parked where is
-- not modelled — ADR-0009 says so out loud rather than implying otherwise.
CREATE TABLE IF NOT EXISTS units (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       uuid NOT NULL REFERENCES organisations(id),
    property_id     uuid NOT NULL,
    block_id        uuid,
    parent_unit_id  uuid,
    unit_kind       text NOT NULL CHECK (unit_kind IN (
                        'flat', 'floor', 'room', 'shop', 'office', 'desk', 'parking', 'storage')),
    -- '1204', 'P-31', 'Desk 7'. Unique within the property, which is the
    -- validation scenario in issue #10.
    code            citext NOT NULL,
    -- Signed: basements are floor -1, and a CHECK for > 0 here would be a bug
    -- reported from every tower with parking underneath it.
    floor           int,
    carpet_area_sqft  numeric(10,2) CHECK (carpet_area_sqft > 0),
    builtup_area_sqft numeric(10,2) CHECK (builtup_area_sqft > 0),
    -- The society's share certificate for this flat. Free text: the format is
    -- whatever the society's registrar used in 1987.
    share_certificate_no text,
    occupancy       text NOT NULL DEFAULT 'vacant' CHECK (occupancy IN (
                        'vacant', 'occupied', 'owner_occupied', 'locked', 'under_renovation')),
    electricity_consumer_no text,
    water_connection_no     text,
    state           text NOT NULL DEFAULT 'active'
                    CHECK (state IN ('active', 'inactive')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),

    -- Always false, and generated so that it cannot be set. It exists to be the
    -- second column of the foreign key below: referencing units(id,
    -- is_ancillary) with a column that is constantly false means the parent's
    -- is_ancillary must be false, so a parking slot cannot be parked on another
    -- parking slot. A trigger would do the same job and could be dropped
    -- without the schema noticing.
    parent_is_ancillary boolean NOT NULL GENERATED ALWAYS AS (false) STORED,
    is_ancillary        boolean NOT NULL GENERATED ALWAYS AS
                        (unit_kind IN ('parking', 'storage')) STORED,

    CONSTRAINT units_code_unique        UNIQUE (property_id, code),
    CONSTRAINT units_tenant_id_unique   UNIQUE (id, tenant_id),
    CONSTRAINT units_property_id_unique UNIQUE (id, property_id),
    CONSTRAINT units_ancillary_unique   UNIQUE (id, is_ancillary),

    CONSTRAINT units_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT units_block_fkey FOREIGN KEY (block_id, tenant_id)
        REFERENCES blocks (id, tenant_id),
    -- The parent lives in the same property...
    CONSTRAINT units_parent_fkey FOREIGN KEY (parent_unit_id, property_id)
        REFERENCES units (id, property_id),
    -- ...and is not itself an ancillary.
    CONSTRAINT units_parent_primary_fkey FOREIGN KEY (parent_unit_id, parent_is_ancillary)
        REFERENCES units (id, is_ancillary),

    CONSTRAINT units_no_self_parent CHECK (parent_unit_id <> id),
    -- Only an ancillary attaches to something. A flat with a parent would be a
    -- second hierarchy nobody downstream knows to walk.
    CONSTRAINT units_parent_only_ancillary CHECK (
        parent_unit_id IS NULL OR unit_kind IN ('parking', 'storage')),
    -- Built-up includes carpet by definition, so this ordering is arithmetic
    -- rather than policy. Dues computed from the wrong one are off by the walls.
    CONSTRAINT units_area_order CHECK (
        carpet_area_sqft IS NULL OR builtup_area_sqft IS NULL
        OR builtup_area_sqft >= carpet_area_sqft),
    -- A flat needs an area for area-based dues; a parking slot does not have
    -- one in any meaningful sense.
    CONSTRAINT units_lettable_has_area CHECK (
        unit_kind IN ('parking', 'storage') OR carpet_area_sqft IS NOT NULL)
);

COMMENT ON TABLE units IS
    'ADR-0009. Ancillaries (parking, storage) are units with parent_unit_id set, not a separate table.';
COMMENT ON COLUMN units.parent_is_ancillary IS
    'Constantly false. The second column of units_parent_primary_fkey, which is how a parent is required not to be an ancillary.';

CREATE INDEX IF NOT EXISTS units_property_idx ON units (property_id, unit_kind);
CREATE INDEX IF NOT EXISTS units_parent_idx   ON units (parent_unit_id) WHERE parent_unit_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS units_block_idx    ON units (block_id) WHERE block_id IS NOT NULL;

ALTER TABLE properties ENABLE ROW LEVEL SECURITY;
ALTER TABLE properties FORCE  ROW LEVEL SECURITY;
ALTER TABLE blocks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE blocks     FORCE  ROW LEVEL SECURITY;
ALTER TABLE units      ENABLE ROW LEVEL SECURITY;
ALTER TABLE units      FORCE  ROW LEVEL SECURITY;

-- The first genuinely property-scoped policy. ADR-0005 §4's template, with the
-- property being this row itself.
--
-- The write branch has a consequence worth stating: for a portfolio-scoped
-- grant with property.write, is_delegated() is true for a property id that does
-- not exist yet, so a firm can create buildings inside the owner's tenant. That
-- is what onboarding a portfolio on an owner's behalf requires. A
-- property-scoped grant cannot, because a new id matches no scope row.
DROP POLICY IF EXISTS properties_tenant_isolation ON properties;
CREATE POLICY properties_tenant_isolation ON properties
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, id, 'property.write'));

DROP POLICY IF EXISTS blocks_tenant_isolation ON blocks;
CREATE POLICY blocks_tenant_isolation ON blocks
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated(tenant_id, property_id, 'property.write'));

-- Unit granularity, not property granularity. is_delegated(tenant_id,
-- property_id, …) would satisfy assertion 5 and hand a firm holding one flat
-- every flat in the tower, which is precisely what ADR-0005's contract says a
-- grant must not do.
DROP POLICY IF EXISTS units_tenant_isolation ON units;
CREATE POLICY units_tenant_isolation ON units
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, id, parent_unit_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, id, parent_unit_id, 'property.write'));

-- The tree is the spine every ledger entry, lease and ticket hangs from. A
-- deleted unit orphans money; a deleted property orphans a grant scope that has
-- no foreign key to protect it. Correction is state = 'inactive'.
--
-- Two locks, as with the grants: the privilege is revoked further down, and this
-- refuses the statement even if some future migration hands it back. The table
-- owner (a DBA at a psql prompt) remains the deliberate escape hatch.
DROP POLICY IF EXISTS properties_no_delete ON properties;
CREATE POLICY properties_no_delete ON properties AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS blocks_no_delete ON blocks;
CREATE POLICY blocks_no_delete ON blocks AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS units_no_delete ON units;
CREATE POLICY units_no_delete ON units AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The reference ADR-0005 promised, as a trigger rather than a foreign key.
--
-- scope_id is polymorphic, so no single foreign key can constrain it — and the
-- check that matters is one a foreign key cannot express anyway: the target must
-- belong to the grantor. Otherwise an owner scopes a grant to a building they do
-- not own, and the firm reads it if it ever becomes theirs.
--
-- SECURITY INVOKER, so the lookup runs under the writer's own row-level
-- security. The grantor sees their own property and the scope is accepted;
-- anybody else sees nothing and gets the same refusal as a nonexistent id,
-- which is the correct answer to both questions.
CREATE OR REPLACE FUNCTION delegation_scope_target() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NEW.scope_kind = 'portfolio' THEN
        NEW.scope_property_id := NULL;
        RETURN NEW;
    END IF;

    IF NEW.scope_kind = 'property' THEN
        IF NOT EXISTS (SELECT 1 FROM properties p
                        WHERE p.id = NEW.scope_id AND p.tenant_id = NEW.tenant_id) THEN
            RAISE EXCEPTION 'grant scope names property % which is not the grantor''s', NEW.scope_id
                USING ERRCODE = 'foreign_key_violation';
        END IF;
        NEW.scope_property_id := NEW.scope_id;
        RETURN NEW;
    END IF;

    -- 'unit'. The containing property is stamped here so that is_delegated()
    -- never reads units from inside a policy.
    SELECT u.property_id INTO NEW.scope_property_id
      FROM units u
     WHERE u.id = NEW.scope_id AND u.tenant_id = NEW.tenant_id;
    IF NEW.scope_property_id IS NULL THEN
        RAISE EXCEPTION 'grant scope names unit % which is not the grantor''s', NEW.scope_id
            USING ERRCODE = 'foreign_key_violation';
    END IF;
    RETURN NEW;
END
$$;

COMMENT ON FUNCTION delegation_scope_target() IS
    'ADR-0009 §4. Validates a grant scope against the grantor''s own tree and stamps scope_property_id.';

DROP TRIGGER IF EXISTS delegation_grant_scopes_target ON delegation_grant_scopes;
CREATE TRIGGER delegation_grant_scopes_target
    BEFORE INSERT OR UPDATE OF scope_kind, scope_id ON delegation_grant_scopes
    FOR EACH ROW EXECUTE FUNCTION delegation_scope_target();

-- The property module writes the tree; every other module reads it, because
-- every other module's rows point into it. Same reasoning as the grants tables:
-- is_delegated_unit() runs under the caller's privileges, and a role without
-- SELECT would turn a policy into an error instead of an empty result.
GRANT SELECT, INSERT, UPDATE ON properties, blocks, units TO dwellm8_property;
GRANT SELECT ON properties, blocks, units TO dwellm8_identity, dwellm8_lease,
    dwellm8_money, dwellm8_maintenance, dwellm8_community, dwellm8_discovery,
    dwellm8_notify;
GRANT EXECUTE ON FUNCTION current_active_grant(uuid, text) TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;
GRANT EXECUTE ON FUNCTION is_delegated_unit(uuid, uuid, uuid, uuid, text) TO dwellm8_identity,
    dwellm8_property, dwellm8_lease, dwellm8_money, dwellm8_maintenance,
    dwellm8_community, dwellm8_discovery, dwellm8_notify;

