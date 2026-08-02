-- ===========================================================================
-- maintenance tickets — the repair request as a record (#245)
-- ===========================================================================

-- A resident raises it, the manager runs it, and both read the same row. The
-- resident-visible slice ships first; manager actions arrive with the Ops leg.
--
-- Liability is assessed, not defaulted: NULL means "not yet decided", and the
-- Live app renders exactly that rather than guessing owner-borne.

CREATE TABLE IF NOT EXISTS tickets (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    lease_id      uuid NOT NULL REFERENCES leases(id),
    -- The delegation quad (ADR-0009): a firm's maintenance mandate reaches the
    -- ticket the way it reaches the unit itself.
    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    raised_by_party_id uuid NOT NULL,

    category      text NOT NULL CHECK (category IN (
                      'plumbing', 'electrical', 'carpentry', 'appliance',
                      'pest_control', 'cleaning', 'common_area', 'other')),
    title         text NOT NULL CHECK (btrim(title) <> ''),
    body          text NOT NULL DEFAULT '',

    status        text NOT NULL DEFAULT 'open' CHECK (status IN (
                      'open', 'acknowledged', 'scheduled', 'in_progress',
                      'resolved', 'cancelled')),
    liability     text CHECK (liability IN ('owner', 'tenant', 'shared')),
    liability_reason text,
    slot          text,
    vendor        text,
    cost_minor    bigint CHECK (cost_minor IS NULL OR cost_minor >= 0),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT tickets_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT tickets_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT tickets_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id)
);

COMMENT ON TABLE tickets IS
    '#245. A maintenance request on one tenancy. Raised by the resident or the manager; liability NULL until somebody assesses it.';

CREATE INDEX IF NOT EXISTS tickets_lease_idx
    ON tickets (tenant_id, lease_id, created_at DESC);
CREATE INDEX IF NOT EXISTS tickets_open_idx
    ON tickets (tenant_id, status) WHERE status NOT IN ('resolved', 'cancelled');

-- The timeline. Append-only: what happened on a ticket is evidence in a
-- liability dispute, and evidence does not get edited.
CREATE TABLE IF NOT EXISTS ticket_events (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id  uuid NOT NULL REFERENCES organisations(id),
    ticket_id  uuid NOT NULL REFERENCES tickets(id),
    at         timestamptz NOT NULL DEFAULT now(),
    actor      text NOT NULL CHECK (actor IN ('resident', 'manager', 'system')),
    body       text NOT NULL CHECK (btrim(body) <> '')
);

COMMENT ON TABLE ticket_events IS
    '#245. What happened on a ticket, in order. Append-only — the timeline is the dispute record.';

CREATE INDEX IF NOT EXISTS ticket_events_ticket_idx
    ON ticket_events (ticket_id, at);

ALTER TABLE tickets       ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets       FORCE  ROW LEVEL SECURITY;
ALTER TABLE ticket_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE ticket_events FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tickets_tenant_isolation ON tickets;
CREATE POLICY tickets_tenant_isolation ON tickets
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'maintenance.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'maintenance.write'));

-- The delegated branch for ticket_events, guarded against the resident scope
-- the way checklist_delegated_read is, and for the same reason.
CREATE OR REPLACE FUNCTION ticket_delegated_read(row_ticket uuid)
    RETURNS boolean LANGUAGE plpgsql STABLE AS
$$
BEGIN
    IF is_resident_session() THEN
        RETURN false;
    END IF;
    RETURN EXISTS (
        SELECT 1 FROM tickets t
         WHERE t.id = row_ticket
           AND is_delegated_unit(t.tenant_id, t.property_id, t.unit_id, NULL, 'maintenance.read'));
END
$$;

COMMENT ON FUNCTION ticket_delegated_read(uuid) IS
    'ADR-0005 and ADR-0029. Whether a delegated firm may read this ticket''s timeline.';

GRANT EXECUTE ON FUNCTION ticket_delegated_read(uuid) TO dwellm8_app;

DROP POLICY IF EXISTS ticket_events_tenant_isolation ON ticket_events;
CREATE POLICY ticket_events_tenant_isolation ON ticket_events
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR ticket_delegated_read(ticket_id))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- ADR-0029, and the one place the resident scope *opens* rather than denies:
-- the ticket is the resident's own story on their own tenancy. Reads narrow to
-- their lease; the only write a renter may make is a ticket they raise
-- themselves. 220's allowlist names both tables, so the deny generator leaves
-- these policies as the rule.
DROP POLICY IF EXISTS tickets_resident_scope ON tickets;
CREATE POLICY tickets_resident_scope ON tickets AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, lease_id))
    WITH CHECK (NOT is_resident_session()
           OR (raised_by_party_id = current_resident_party_id()
               AND resident_holds_lease(tenant_id, lease_id)));

-- Reached through the ticket, which the policy above has already narrowed.
DROP POLICY IF EXISTS ticket_events_resident_scope ON ticket_events;
CREATE POLICY ticket_events_resident_scope ON ticket_events AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id))
    WITH CHECK (NOT is_resident_session()
           OR EXISTS (SELECT 1 FROM tickets t WHERE t.id = ticket_id));

-- No deletes outside a sandbox purge, both locks as everywhere: the policy
-- refuses and the privilege is withheld.
DROP POLICY IF EXISTS tickets_no_delete ON tickets;
CREATE POLICY tickets_no_delete ON tickets AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS ticket_events_no_delete ON ticket_events;
CREATE POLICY ticket_events_no_delete ON ticket_events AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

-- The timeline is also immutable, not merely undeletable.
DROP POLICY IF EXISTS ticket_events_no_update ON ticket_events;
CREATE POLICY ticket_events_no_update ON ticket_events AS RESTRICTIVE FOR UPDATE
    USING (false) WITH CHECK (false);

GRANT SELECT, INSERT, UPDATE ON tickets TO dwellm8_maintenance;
GRANT SELECT, INSERT ON ticket_events TO dwellm8_maintenance;

REVOKE DELETE ON tickets, ticket_events FROM dwellm8_app;
REVOKE UPDATE ON ticket_events FROM dwellm8_app, dwellm8_maintenance;
GRANT DELETE ON tickets, ticket_events TO dwellm8_purge;
