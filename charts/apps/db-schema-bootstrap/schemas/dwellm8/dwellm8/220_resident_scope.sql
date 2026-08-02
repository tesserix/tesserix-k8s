-- ===========================================================================
-- the resident scope (ADR-0029)
-- ===========================================================================

-- A tenant reading their own tenancy is not a small organisation.
--
-- Every policy above answers one question: which *organisation* may see this
-- row. That is the right boundary for a landlord and the wrong one for a
-- renter — a renter scoped to their landlord's organisation would read every
-- other tenant of that landlord, which is a worse leak than the cross-tenant
-- one ADR-0003 exists to prevent, because it looks like the system working.
--
-- So a resident request carries a second setting, app.resident_party_id, and
-- every table narrows a second time. Three properties make it safe:
--
--   1. **Deny by default.** The loop at the foot of this section puts a
--      RESTRICTIVE deny on every row-level-secured table that is not on the
--      allowlist below. A table added by a future ADR is closed to residents
--      before anybody thinks about it, which is the opposite of how the
--      hazard usually arrives.
--   2. **The narrowing is the database's**, not a WHERE clause in Go. ADR-0003's
--      argument applies unchanged: a forgotten filter must be impossible rather
--      than discouraged, and the filter that would be forgotten here is the one
--      separating two tenants of the same landlord.
--   3. **It only ever narrows.** Every predicate is `NOT is_resident_session()
--      OR …`, so an owner, a manager, a delegated firm and the platform session
--      are unaffected — this section cannot widen anything.
--
-- The organisation scope still applies on top: a resident session is scoped to
-- exactly one organisation at a time, and a resident with leases under two
-- landlords is two scoped reads, never one query across both. That is what
-- keeps the two landlords from learning of each other.

-- current_resident_party_id() and is_resident_session() are declared with the
-- other session helpers, at the top of this file, because the delegated-read
-- guard on lease_parties calls them long before this section runs.

-- The one question the resident scope turns on: is this lease one this person
-- is a tenant of?
--
-- It reads lease_parties under the caller's own row-level security, which is
-- not a weakness but the second lock — and it does not recurse, because the
-- policy on lease_parties below is a direct comparison rather than another call
-- to this function.
--
-- `retired_at IS NULL` and no validity check, deliberately. A tenancy that
-- ended is still the tenant's own history: the story this exists for is a
-- renter proving what they paid, and a receipt that disappears the day the
-- lease ends is a receipt that is missing exactly when it is needed. A retired
-- row is a correction — somebody recorded the wrong person — and that one must
-- stop granting access immediately.
CREATE OR REPLACE FUNCTION resident_holds_lease(row_tenant uuid, row_lease uuid)
    RETURNS boolean LANGUAGE sql STABLE PARALLEL SAFE AS
$$
    SELECT NOT is_resident_session()
        OR (row_lease IS NOT NULL AND EXISTS (
                SELECT 1 FROM lease_parties lp
                 WHERE lp.lease_id  = row_lease
                   AND lp.tenant_id = row_tenant
                   AND lp.party_id  = current_resident_party_id()
                   AND lp.role      = 'tenant'
                   AND lp.retired_at IS NULL))
$$;

COMMENT ON FUNCTION resident_holds_lease(uuid, uuid) IS
    'ADR-0029. Whether the resident this session acts as is a tenant of this lease. True for every non-resident session, so it only ever narrows.';

GRANT EXECUTE ON FUNCTION current_resident_party_id() TO dwellm8_app, dwellm8_platform;
GRANT EXECUTE ON FUNCTION is_resident_session()       TO dwellm8_app, dwellm8_platform;
GRANT EXECUTE ON FUNCTION resident_holds_lease(uuid, uuid) TO dwellm8_app, dwellm8_platform;

-- The tenancy itself, and the terms of it. Read-only: a renter does not write a
-- lease, and the WITH CHECK says so rather than relying on a privilege.
DROP POLICY IF EXISTS leases_resident_scope ON leases;
CREATE POLICY leases_resident_scope ON leases AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, id))
    WITH CHECK (NOT is_resident_session());

-- Their own row only, not the whole party list. A co-tenant's party id is not
-- something the payment screen needs, and this is the table resident_holds_lease
-- reads — so a direct comparison here is also what keeps that function from
-- recursing into its own policy.
DROP POLICY IF EXISTS lease_parties_resident_scope ON lease_parties;
CREATE POLICY lease_parties_resident_scope ON lease_parties AS RESTRICTIVE
    USING (NOT is_resident_session() OR party_id = current_resident_party_id())
    WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS rent_schedule_resident_scope ON rent_schedule;
CREATE POLICY rent_schedule_resident_scope ON rent_schedule AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, lease_id))
    WITH CHECK (NOT is_resident_session());

-- An entry that names no lease is invisible to a resident. That is most of the
-- ledger — payouts, platform fees, settlements — and none of it is theirs.
DROP POLICY IF EXISTS journal_entries_resident_scope ON journal_entries;
CREATE POLICY journal_entries_resident_scope ON journal_entries AS RESTRICTIVE
    USING (resident_holds_lease(tenant_id, lease_id))
    WITH CHECK (NOT is_resident_session());

-- A posting has no lease of its own, so it is judged by whose balance it moves.
-- The counterpart lines of a resident's own invoice — rent_income, credited to
-- the owner — are correctly hidden by this: what the tenant owes is theirs to
-- see, what the landlord earns is not.
DROP POLICY IF EXISTS ledger_postings_resident_scope ON ledger_postings;
CREATE POLICY ledger_postings_resident_scope ON ledger_postings AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR (party_kind = 'tenant' AND party_id = current_resident_party_id()))
    WITH CHECK (NOT is_resident_session());

-- The one table a resident writes. Both halves are constrained: the payer must
-- be them, and the lease must be one of theirs — which also refuses a payment
-- naming no lease at all, because resident_holds_lease() is false for NULL.
DROP POLICY IF EXISTS payments_resident_scope ON payments;
CREATE POLICY payments_resident_scope ON payments AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR (payer_kind = 'tenant'
               AND payer_id = current_resident_party_id()
               AND resident_holds_lease(tenant_id, lease_id)))
    WITH CHECK (NOT is_resident_session()
           OR (payer_kind = 'tenant'
               AND payer_id = current_resident_party_id()
               AND resident_holds_lease(tenant_id, lease_id)));

-- The flat they live in and the building it is in — the lease summary needs a
-- name for both. Reached through `leases`, which this section has already
-- narrowed, so no second copy of the tenancy rule appears here.
DROP POLICY IF EXISTS units_resident_scope ON units;
CREATE POLICY units_resident_scope ON units AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.unit_id = units.id))
    WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS properties_resident_scope ON properties;
CREATE POLICY properties_resident_scope ON properties AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.property_id = properties.id))
    WITH CHECK (NOT is_resident_session());

-- Who to pay, by name. A renter with two landlords sees two names and nothing
-- that connects them, which is the edge case the story names.
DROP POLICY IF EXISTS organisations_resident_scope ON organisations;
CREATE POLICY organisations_resident_scope ON organisations AS RESTRICTIVE
    USING (NOT is_resident_session()
           OR EXISTS (SELECT 1 FROM leases l WHERE l.tenant_id = organisations.id))
    WITH CHECK (NOT is_resident_session());

-- Everything else is closed.
--
-- Column-driven rather than a list, for the reason assertions 6 and 16 give: a
-- guard that covers the tables its author had in mind decays with the next
-- migration, and the decay here is a renter reading a table nobody remembered
-- to think about. The allowlist is the argument; anything absent from it is
-- denied, including tables this file has not seen yet.
DO $$
DECLARE
    opened text[] := ARRAY[
        'leases', 'lease_parties', 'rent_schedule', 'journal_entries',
        'ledger_postings', 'payments', 'units', 'properties', 'organisations',
        -- 232: a renter's own repair requests. The scoped policies live in
        -- that chapter; naming the tables here keeps this loop from
        -- overwriting them with a deny on the next replay.
        'tickets', 'ticket_events'];
    tbl text;
BEGIN
    -- The bootstrap replays every 30 minutes; a NOTICE per absent policy per
    -- table is thirty lines of log saying nothing happened.
    PERFORM set_config('client_min_messages', 'warning', true);

    FOR tbl IN
        SELECT c.relname
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
           AND c.relname <> ALL (opened)
         ORDER BY c.relname
    LOOP
        EXECUTE format('DROP POLICY IF EXISTS %I ON %I', tbl || '_resident_denied', tbl);
        EXECUTE format(
            'CREATE POLICY %I ON %I AS RESTRICTIVE '
            'USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session())',
            tbl || '_resident_denied', tbl);
    END LOOP;
END
$$;

