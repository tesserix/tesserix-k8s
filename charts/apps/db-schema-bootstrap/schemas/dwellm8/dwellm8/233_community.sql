-- ===========================================================================
-- community — the tenancy conversation and the gate (#246)
-- ===========================================================================

-- Two things a renter does that are neither money nor maintenance: talk to
-- whoever manages the place, and tell the gate who is coming. Both hang off
-- the lease, both carry the delegation quad so a managing firm's mandate
-- reaches them, and both open to the resident scope — they are the renter's
-- own records.

-- One thread per lease. No edit and no delete: what was said to a tenant, and
-- when, is exactly the kind of record a dispute reaches for.
CREATE TABLE IF NOT EXISTS lease_messages (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),
    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,

    sender        text NOT NULL CHECK (sender IN ('resident', 'manager', 'system')),
    sender_party_id uuid,
    body          text NOT NULL CHECK (btrim(body) <> ''),
    created_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT lease_messages_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT lease_messages_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    -- A resident message names its author; the constraint is what makes the
    -- resident-scope WITH CHECK below unforgeable rather than advisory.
    CONSTRAINT lease_messages_resident_named
        CHECK (sender <> 'resident' OR sender_party_id IS NOT NULL)
);

COMMENT ON TABLE lease_messages IS
    '#246. The tenancy conversation, on the record. Append-only.';

CREATE INDEX IF NOT EXISTS lease_messages_lease_idx
    ON lease_messages (tenant_id, lease_id, created_at);

-- A gate pass: who the renter expects, for what window, under which code.
-- The guard's side arrives with the gate leg; until then the pass is still
-- the renter's instruction, recorded before anyone stands at the gate.
CREATE TABLE IF NOT EXISTS gate_passes (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),
    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    created_by_party_id uuid NOT NULL,

    name          text NOT NULL CHECK (btrim(name) <> ''),
    kind          text NOT NULL CHECK (kind IN ('guest', 'delivery', 'cab', 'help')),
    code          text NOT NULL CHECK (code ~ '^[0-9]{4}$'),
    valid_from    timestamptz NOT NULL DEFAULT now(),
    valid_to      timestamptz,

    state         text NOT NULL DEFAULT 'expected' CHECK (state IN (
                      'expected', 'cancelled', 'arrived', 'inside', 'left', 'denied')),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT gate_passes_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT gate_passes_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT gate_passes_window CHECK (valid_to IS NULL OR valid_to > valid_from)
);

COMMENT ON TABLE gate_passes IS
    '#246. Who the renter expects at the gate. The gate sees a name and a flat, never a phone number.';

CREATE INDEX IF NOT EXISTS gate_passes_lease_idx
    ON gate_passes (tenant_id, lease_id, created_at DESC);

ALTER TABLE lease_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE lease_messages FORCE  ROW LEVEL SECURITY;
ALTER TABLE gate_passes    ENABLE ROW LEVEL SECURITY;
ALTER TABLE gate_passes    FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS lease_messages_tenant_isolation ON lease_messages;
CREATE POLICY lease_messages_tenant_isolation ON lease_messages
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'community.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'community.write'));

DROP POLICY IF EXISTS gate_passes_tenant_isolation ON gate_passes;
CREATE POLICY gate_passes_tenant_isolation ON gate_passes
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'community.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'community.write'));

-- ADR-0029: both tables open to the renter on their own lease — reads narrow
-- to it, and the only writes a renter may make are a message they authored
-- and a pass they created. 220's allowlist names both tables.
DROP POLICY IF EXISTS lease_messages_resident_scope ON lease_messages;
CREATE POLICY lease_messages_resident_scope ON lease_messages AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, lease_id))
    WITH CHECK (NOT is_resident_session()
           OR (sender = 'resident'
               AND sender_party_id = current_resident_party_id()
               AND resident_holds_lease(tenant_id, lease_id)));

DROP POLICY IF EXISTS gate_passes_resident_scope ON gate_passes;
CREATE POLICY gate_passes_resident_scope ON gate_passes AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, lease_id))
    WITH CHECK (NOT is_resident_session()
           OR (created_by_party_id = current_resident_party_id()
               AND resident_holds_lease(tenant_id, lease_id)));

-- The conversation is immutable; a pass may change state but never vanish.
DROP POLICY IF EXISTS lease_messages_no_update ON lease_messages;
CREATE POLICY lease_messages_no_update ON lease_messages AS RESTRICTIVE FOR UPDATE
    USING (false) WITH CHECK (false);
DROP POLICY IF EXISTS lease_messages_no_delete ON lease_messages;
CREATE POLICY lease_messages_no_delete ON lease_messages AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS gate_passes_no_delete ON gate_passes;
CREATE POLICY gate_passes_no_delete ON gate_passes AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT ON lease_messages TO dwellm8_community;
GRANT SELECT, INSERT, UPDATE ON gate_passes TO dwellm8_community;

REVOKE DELETE ON lease_messages, gate_passes FROM dwellm8_app;
REVOKE UPDATE ON lease_messages FROM dwellm8_app, dwellm8_community;
GRANT DELETE ON lease_messages, gate_passes TO dwellm8_purge;
