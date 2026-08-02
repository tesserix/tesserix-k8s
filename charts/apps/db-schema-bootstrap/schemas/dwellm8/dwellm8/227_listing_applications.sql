-- ===========================================================================
-- listing applications (#142)
-- ===========================================================================

-- The formal step between "we spoke" and "here is your lease": an applicant
-- proposes terms, the owner accepts or declines with a reason, and acceptance
-- is what mints the lease draft with everything carried over. Two rules the
-- schema owns outright: one live application per prospect per listing, and
-- one accepted application per unit — the second acceptance is blocked
-- naming the first, which is the story's failure scenario verbatim.
--
-- Declined applicants are not kept indefinitely: retain_until is stamped at
-- decline, and the platform's retention sweep may delete the row once it
-- passes — the one sanctioned deletion outside a sandbox purge, carried by
-- the DELETE policy below until #213's matrix refines the window.

CREATE TABLE IF NOT EXISTS listing_applications (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),
    -- The delegation quad (ADR-0009): a firm's mandate reviews applications
    -- the way it runs the unit itself.
    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    prospect_id   uuid NOT NULL REFERENCES prospects(id),
    enquiry_id    uuid REFERENCES enquiries(id),

    state         text NOT NULL DEFAULT 'submitted' CHECK (state IN (
                      'submitted', 'under_review', 'accepted', 'declined', 'withdrawn')),

    -- What the applicant proposes. offer_minor NULL means the asking rent.
    move_in       date NOT NULL,
    term_months   int NOT NULL DEFAULT 11 CHECK (term_months BETWEEN 1 AND 60),
    offer_minor   bigint CHECK (offer_minor IS NULL OR offer_minor > 0),
    note          text,

    -- The decision, and what it produced.
    decline_reason text,
    decided_at     timestamptz,
    lease_id       uuid,

    -- The retention clock for a declined applicant (#213 pending; 180 days is
    -- the working default the sweep honours).
    retain_until   date,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT applications_decline_shape CHECK (
        (state = 'declined') = (decline_reason IS NOT NULL)),
    CONSTRAINT applications_decided_shape CHECK (
        (state IN ('accepted', 'declined')) = (decided_at IS NOT NULL)),
    CONSTRAINT applications_accept_names_lease CHECK (
        state <> 'accepted' OR lease_id IS NOT NULL),
    CONSTRAINT applications_retention_is_declines CHECK (
        retain_until IS NULL OR state = 'declined'),
    CONSTRAINT applications_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT applications_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT applications_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id)
);

COMMENT ON TABLE listing_applications IS
    '#142. The formal step between enquiry and lease. One accepted per unit is the index below; a declined row lives only to retain_until.';

-- One open application per prospect per listing; applying twice is the same
-- application, and a fresh one is possible after withdrawal or decision.
CREATE UNIQUE INDEX IF NOT EXISTS applications_one_open_per_prospect
    ON listing_applications (listing_id, prospect_id)
    WHERE state IN ('submitted', 'under_review');

-- The story's failure scenario: a second acceptance for the same unit is
-- blocked, and the application layer names the first from this index's
-- violation.
CREATE UNIQUE INDEX IF NOT EXISTS applications_one_accepted_per_unit
    ON listing_applications (unit_id) WHERE state = 'accepted';

CREATE INDEX IF NOT EXISTS applications_owner_idx
    ON listing_applications (tenant_id, state, created_at);
CREATE INDEX IF NOT EXISTS applications_prospect_idx
    ON listing_applications (prospect_id, created_at);
CREATE INDEX IF NOT EXISTS applications_retention_idx
    ON listing_applications (retain_until) WHERE state = 'declined';

-- The verification point, the funnel's one rule: applying for a tenancy is
-- contact, and contact needs a verified phone.
CREATE OR REPLACE FUNCTION applications_need_a_verified_prospect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prospects p
                    WHERE p.id = NEW.prospect_id AND p.verified_at IS NOT NULL) THEN
        RAISE EXCEPTION 'application % is from an unverified prospect: browsing needs no account, '
                        'and applying to live in somebody''s flat needs a verified phone number',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS applications_verification_point ON listing_applications;
CREATE TRIGGER applications_verification_point
    BEFORE INSERT ON listing_applications
    FOR EACH ROW EXECUTE FUNCTION applications_need_a_verified_prospect();

ALTER TABLE listing_applications ENABLE ROW LEVEL SECURITY;
ALTER TABLE listing_applications FORCE  ROW LEVEL SECURITY;

DROP POLICY IF EXISTS listing_applications_tenant_isolation ON listing_applications;
CREATE POLICY listing_applications_tenant_isolation ON listing_applications
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, NULL, 'property.write'));

-- Closed to renter sessions from birth (ADR-0029; the 220 loop ran already).
DROP POLICY IF EXISTS listing_applications_resident_denied ON listing_applications;
CREATE POLICY listing_applications_resident_denied ON listing_applications AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

-- Deletion is the retention promise, not a convenience: a sandbox purge, or
-- the platform sweep removing a declined applicant whose clock has passed.
-- Everything else is refused however the privileges evolve.
DROP POLICY IF EXISTS listing_applications_no_delete ON listing_applications;
CREATE POLICY listing_applications_no_delete ON listing_applications AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id)
           OR (is_platform_session() AND state = 'declined'
               AND retain_until IS NOT NULL AND retain_until <= CURRENT_DATE));

GRANT SELECT, INSERT, UPDATE ON listing_applications TO dwellm8_discovery, dwellm8_property;
GRANT DELETE ON listing_applications TO dwellm8_platform;
