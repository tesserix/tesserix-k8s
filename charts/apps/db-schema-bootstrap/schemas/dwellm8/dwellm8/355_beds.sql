-- ===========================================================================
-- Beds, for a hostel or a PG where the bed is what is let (#299, #345)
-- ===========================================================================
--
-- No rooms table: chapter 020 already lets a unit be `unit_kind = 'room'`
-- under a parent unit, so a room is a unit and the sharing figure is the
-- count of beds in it. What is genuinely new is the bed.
--
-- A bed is the lettable thing, so it carries its own rent and points at the
-- lease that holds it. That reuses the rent schedule, the ledger and the
-- collections path rather than growing a second money model beside them.

CREATE TABLE IF NOT EXISTS beds (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id   uuid NOT NULL REFERENCES organisations(id),
    property_id uuid NOT NULL,
    -- The room. Its floor and its parent flat come from units, not from here.
    unit_id     uuid NOT NULL REFERENCES units(id),
    label       citext NOT NULL,
    rent_amount_minor bigint NOT NULL DEFAULT 0 CHECK (rent_amount_minor >= 0),
    state       text NOT NULL DEFAULT 'vacant' CHECK (state IN (
                    'vacant', 'reserved', 'occupied', 'notice')),
    lease_id    uuid REFERENCES leases(id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT beds_label_unique UNIQUE (unit_id, label),
    -- An occupied or noticed bed without a lease is rent nobody is billed for.
    CONSTRAINT beds_held_under_a_lease CHECK (
        state NOT IN ('occupied', 'notice') OR lease_id IS NOT NULL)
);

COMMENT ON TABLE beds IS
    '#299. A bed in a room, the lettable unit of a hostel or PG. Sharing is the
     count of beds in the room; the floor is the room''s.';

CREATE INDEX IF NOT EXISTS beds_property_idx ON beds (tenant_id, property_id, unit_id);
CREATE INDEX IF NOT EXISTS beds_lease_idx ON beds (lease_id) WHERE lease_id IS NOT NULL;

-- One bed may be held by one lease at a time. A partial unique index rather
-- than a constraint: the vacant beds all carry a null lease.
CREATE UNIQUE INDEX IF NOT EXISTS beds_one_lease_per_bed
    ON beds (lease_id) WHERE lease_id IS NOT NULL;

ALTER TABLE beds ENABLE ROW LEVEL SECURITY;
ALTER TABLE beds FORCE  ROW LEVEL SECURITY;

-- The delegation quad (230, assertion 5/6): a firm managing this property
-- under a mandate reads and writes its beds, and nobody else's.
DROP POLICY IF EXISTS beds_tenant_isolation ON beds;
CREATE POLICY beds_tenant_isolation ON beds
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.write'));

-- Closed to renter sessions (ADR-0029; the 220 loop ran already, so this
-- chapter writes its own deny under the name that loop would have used).
DROP POLICY IF EXISTS beds_resident_denied ON beds;
CREATE POLICY beds_resident_denied ON beds AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- Who slept where is the letting history of the property.
DROP POLICY IF EXISTS beds_no_delete ON beds;
CREATE POLICY beds_no_delete ON beds AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON beds TO dwellm8_property;
GRANT SELECT ON beds TO dwellm8_lease, dwellm8_app;
GRANT DELETE ON beds TO dwellm8_purge;
