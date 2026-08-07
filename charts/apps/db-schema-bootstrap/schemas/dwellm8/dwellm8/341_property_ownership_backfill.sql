-- ===========================================================================
-- property ownership for the properties onboarded before it was recorded (#302)
-- ===========================================================================

-- Onboarding registered properties without ever writing property_ownership, so
-- the billing run refused every tenancy on them — it will not credit rent to a
-- party it had to guess. The application fix records ownership from now on;
-- this repairs what was already registered.
--
-- The owner is not invented: it is the member holding the owner role in the
-- organisation the property belongs to. Dated from the earliest tenancy on the
-- property, because a lease that began in March cannot be billed against
-- ownership that begins today. Properties whose organisation has no owner
-- member are left alone rather than attributed to somebody.
INSERT INTO property_ownership (tenant_id, property_id, owner_party_id, share_bps, valid_from)
SELECT p.tenant_id, p.id, m.party_id, 10000,
       LEAST(p.created_at::date, COALESCE(MIN(l.valid_from), p.created_at::date))
  FROM properties p
  JOIN LATERAL (
       SELECT om.party_id
         FROM organisation_members om
        WHERE om.tenant_id = p.tenant_id AND om.role = 'owner'
          AND om.validity @> current_date
        ORDER BY om.created_at
        LIMIT 1) m ON true
  LEFT JOIN leases l ON l.property_id = p.id
 WHERE NOT EXISTS (
       SELECT 1 FROM property_ownership o
        WHERE o.property_id = p.id AND o.retired_at IS NULL)
 GROUP BY p.tenant_id, p.id, p.created_at, m.party_id;
