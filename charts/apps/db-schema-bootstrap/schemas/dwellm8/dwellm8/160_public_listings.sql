-- ===========================================================================
-- public listings and prospects (ADR-0019)
-- ===========================================================================

-- The listing site is the only surface used by people who are not customers and may
-- never sign in. It is therefore the first read path in this schema that does not fail
-- closed, and that is the decision this section is about.
--
-- ADR-0003's rule is that current_tenant_id() is NULL when unset, so every policy denies
-- and an unscoped session sees nothing. An anonymous visitor is exactly an unscoped
-- session, so a public listing needs a branch that does not depend on a tenant — and
-- every such branch is a hole in the isolation model unless it is narrow enough to
-- reason about.
--
-- It is narrowed three ways, and all three matter:
--
--   1. One table. Only `listings` has a public branch, and assertion 17 refuses one
--      anywhere else. A future table that quietly becomes world-readable is the failure
--      this section is most likely to cause.
--   2. The row opts in. `published_at IS NOT NULL AND state = 'live'` — publication is an
--      act by the owner, not a default, and unpublishing removes the row from the public
--      view immediately.
--   3. The columns are the listing's own. A listing carries what a stranger may see: the
--      locality, the rent, the photographs. property_id and unit_id are present because
--      the product needs them, and they lead nowhere — every other table still denies an
--      unscoped session, so a uuid is opaque.

CREATE TABLE IF NOT EXISTS listings (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),

    property_id   uuid NOT NULL,
    unit_id       uuid NOT NULL,
    unit_parent_id uuid,

    state         text NOT NULL DEFAULT 'draft' CHECK (state IN (
                      'draft', 'live', 'paused', 'let', 'withdrawn')),
    -- Publication is an act, and an unpublished listing is invisible to a stranger even
    -- if its state says live. Two columns rather than one because "the owner published
    -- this" and "it is currently being advertised" are different facts: pausing keeps the
    -- publication history.
    published_at  timestamptz,

    -- What a stranger may see. Denormalised on purpose: an anonymous reader must not need
    -- to join to properties or units, because those deny.
    headline      text NOT NULL,
    locality      text NOT NULL,
    city          text NOT NULL,
    state_code    char(2) NOT NULL,
    -- Deliberately not the full address. A listing shows a locality until an inspection is
    -- booked, which is the industry norm and is also what stops the site being a map of
    -- which flats are empty.
    rent_minor    bigint NOT NULL CHECK (rent_minor > 0),
    deposit_minor bigint NOT NULL DEFAULT 0 CHECK (deposit_minor >= 0),
    currency      char(3) NOT NULL DEFAULT 'INR' CHECK (currency = 'INR'),
    bedrooms      int CHECK (bedrooms IS NULL OR bedrooms BETWEEN 0 AND 20),
    carpet_area_sqft numeric(10,2) CHECK (carpet_area_sqft IS NULL OR carpet_area_sqft > 0),
    available_from date,

    -- What a search engine may index. Robots are told no for anything but a live,
    -- published listing, and the column exists so that decision is data rather than a
    -- template condition somebody edits.
    indexable     boolean NOT NULL DEFAULT true,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT listings_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id),
    CONSTRAINT listings_unit_fkey FOREIGN KEY (unit_id, tenant_id)
        REFERENCES units (id, tenant_id),
    CONSTRAINT listings_unit_property_fkey FOREIGN KEY (unit_id, property_id)
        REFERENCES units (id, property_id),
    CONSTRAINT listings_amount_representable CHECK (rent_minor <= 9007199254740991),
    -- A live listing is published. The reverse is not required: a paused listing keeps its
    -- publication date, which is what makes pausing different from withdrawing.
    CONSTRAINT listings_live_is_published CHECK (state <> 'live' OR published_at IS NOT NULL)
);

COMMENT ON TABLE listings IS
    'ADR-0019. The only publicly readable table in this schema. A row is visible to a stranger only when its owner published it and it is live.';

-- One live listing per unit. Two adverts for the same flat at different rents is the
-- thing a prospect screenshots.
CREATE UNIQUE INDEX IF NOT EXISTS listings_one_live_per_unit
    ON listings (tenant_id, unit_id) WHERE state IN ('live', 'paused');
-- The search query: live listings in a city, by rent.
CREATE INDEX IF NOT EXISTS listings_search_idx
    ON listings (city, locality, rent_minor) WHERE state = 'live' AND published_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS listings_owner_idx ON listings (tenant_id, state);

-- A prospect: somebody who is not a customer and may never be one.
--
-- Identified the way ADR-0021 identifies a demo visitor, and for the same reason — an
-- opaque token, stored hashed, because a database copy must not hand out somebody's
-- browsing history. Shortlisting is anonymous, so the token is all there is until the
-- verification point.
CREATE TABLE IF NOT EXISTS prospects (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- No tenant_id. A prospect belongs to nobody: they are browsing the whole site, and
    -- attributing them to the first owner whose listing they opened would be wrong and
    -- would leak their interest in the others. Assertion 12 requires this table's writes
    -- to be platform-only, which they are.
    token_hash      bytea NOT NULL UNIQUE CHECK (length(token_hash) = 32),

    -- The verification point. NULL until the prospect books an inspection or makes an
    -- enquiry, which is the moment a phone number is required.
    verified_at     timestamptz,
    -- The masked-calling provider's reference for this person, and the masked form for
    -- display. The raw number is never here: the provider holds it, we hold a token, and
    -- neither party's number can leak from this database because it is not in it.
    contact_ref     text,
    contact_masked  text CHECK (contact_masked IS NULL OR contact_masked ~ '^[X*]{6}[0-9]{4}$'),

    -- Where they end up, if they sign up. The edge case the story names: a prospect who
    -- signs up must not lose their shortlist or enquiry history, so the prospect row is
    -- kept and pointed at the party rather than replaced.
    converted_party_id uuid,
    converted_at    timestamptz,

    created_at      timestamptz NOT NULL DEFAULT now(),
    last_seen_at    timestamptz NOT NULL DEFAULT now(),

    -- Verification is a package: the timestamp, the provider reference and the masked
    -- form arrive together or not at all. A half-verified prospect is one that can be
    -- called and not displayed, or displayed and not called.
    CONSTRAINT prospects_verification_shape CHECK (
        (verified_at IS NULL) = (contact_ref IS NULL)
        AND (verified_at IS NULL) = (contact_masked IS NULL)),
    CONSTRAINT prospects_conversion_shape CHECK (
        (converted_at IS NULL) = (converted_party_id IS NULL)),
    -- Signing up requires having verified: an account is built on a verified contact.
    CONSTRAINT prospects_conversion_needs_verification CHECK (
        converted_at IS NULL OR verified_at IS NOT NULL)
);

COMMENT ON TABLE prospects IS
    'ADR-0019. Somebody browsing who may never sign in. No raw phone number: the masked-calling provider holds it and this holds a reference.';

CREATE INDEX IF NOT EXISTS prospects_converted_idx
    ON prospects (converted_party_id) WHERE converted_party_id IS NOT NULL;

-- The shortlist, once a prospect has a record. Before that it is local state in the
-- browser, which is what makes browsing genuinely anonymous.
CREATE TABLE IF NOT EXISTS prospect_shortlist (
    prospect_id   uuid NOT NULL REFERENCES prospects(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),
    added_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (prospect_id, listing_id)
);

COMMENT ON TABLE prospect_shortlist IS
    'ADR-0019. Survives sign-up, because the prospect row is kept and pointed at the party rather than replaced.';

-- An enquiry or an inspection booking: the point at which a prospect becomes visible to
-- an owner.
CREATE TABLE IF NOT EXISTS enquiries (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The owner's organisation. An enquiry is the first row in this funnel that belongs
    -- to somebody, which is why it is the first one with ordinary tenancy.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    listing_id    uuid NOT NULL REFERENCES listings(id),
    prospect_id   uuid NOT NULL REFERENCES prospects(id),

    kind          text NOT NULL CHECK (kind IN ('enquiry', 'inspection', 'callback')),
    state         text NOT NULL DEFAULT 'new' CHECK (state IN (
                      'new', 'owner_responded', 'scheduled', 'completed', 'closed', 'spam')),
    message       text,
    scheduled_for timestamptz,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    -- An inspection has a time. An enquiry does not.
    CONSTRAINT enquiries_inspection_is_scheduled CHECK (
        kind <> 'inspection' OR state <> 'scheduled' OR scheduled_for IS NOT NULL)
);

COMMENT ON TABLE enquiries IS
    'ADR-0019. The verification point: making one requires a verified prospect, enforced by a trigger.';

CREATE INDEX IF NOT EXISTS enquiries_listing_idx ON enquiries (listing_id, created_at);
CREATE INDEX IF NOT EXISTS enquiries_owner_idx ON enquiries (tenant_id, state, created_at);
CREATE INDEX IF NOT EXISTS enquiries_prospect_idx ON enquiries (prospect_id, created_at);

-- The verification point, enforced rather than documented. Browsing and shortlisting are
-- anonymous; making contact is not.
CREATE OR REPLACE FUNCTION enquiries_need_a_verified_prospect() RETURNS trigger
    LANGUAGE plpgsql AS
$$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM prospects p
                    WHERE p.id = NEW.prospect_id AND p.verified_at IS NOT NULL) THEN
        RAISE EXCEPTION 'enquiry % is from an unverified prospect: browsing and shortlisting need '
                        'no account, and making contact needs a verified phone number — which is '
                        'the only thing standing between an owner and a thousand fake enquiries',
            NEW.id USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS enquiries_verification_point ON enquiries;
CREATE TRIGGER enquiries_verification_point
    BEFORE INSERT ON enquiries
    FOR EACH ROW EXECUTE FUNCTION enquiries_need_a_verified_prospect();

-- Contact protection. Neither number is exposed, ever, and the bridge is what connects
-- them.
--
-- The story's edge case is that neither party's number may be exposed before both have
-- engaged. This goes further, because it is cheaper to go further: neither number is in
-- this database at all. The masked-calling provider holds both and this holds two
-- references, so there is nothing here to expose at any point.
--
-- What the constraint below enforces is the timing: a bridge exists only once the owner
-- has responded, so a prospect cannot dial an owner off the back of an unanswered enquiry.
CREATE TABLE IF NOT EXISTS contact_bridges (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    enquiry_id    uuid NOT NULL UNIQUE REFERENCES enquiries(id),

    -- The provider's handle for the connection. Never a number.
    provider      text NOT NULL,
    provider_ref  text NOT NULL,
    -- What each side sees, which is the provider's proxy number.
    proxy_masked  text NOT NULL CHECK (proxy_masked ~ '^[X*]{6}[0-9]{4}$'),

    opened_at     timestamptz NOT NULL DEFAULT now(),
    expires_at    timestamptz NOT NULL,

    CONSTRAINT contact_bridges_window CHECK (expires_at > opened_at)
);

COMMENT ON TABLE contact_bridges IS
    'ADR-0019. A masked connection between an owner and a prospect. Neither number is in this database — the provider holds both.';

CREATE INDEX IF NOT EXISTS contact_bridges_expiry_idx ON contact_bridges (expires_at);

-- Both sides must have engaged. The prospect engaged by making the enquiry; the owner
-- engages by responding, and until they do there is nobody to connect them to.
CREATE OR REPLACE FUNCTION contact_bridges_need_mutual_engagement() RETURNS trigger
    LANGUAGE plpgsql AS
$$
DECLARE
    enquiry_state text;
BEGIN
    SELECT state INTO enquiry_state FROM enquiries WHERE id = NEW.enquiry_id;
    IF enquiry_state IS NULL OR enquiry_state IN ('new', 'spam', 'closed') THEN
        RAISE EXCEPTION 'contact bridge % is for an enquiry in state %: a connection is opened once '
                        'both sides have engaged, and an unanswered enquiry is one side',
            NEW.id, coalesce(enquiry_state, 'missing') USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS contact_bridges_mutual ON contact_bridges;
CREATE TRIGGER contact_bridges_mutual
    BEFORE INSERT ON contact_bridges
    FOR EACH ROW EXECUTE FUNCTION contact_bridges_need_mutual_engagement();

ALTER TABLE listings           ENABLE ROW LEVEL SECURITY;
ALTER TABLE listings           FORCE  ROW LEVEL SECURITY;
ALTER TABLE prospects          ENABLE ROW LEVEL SECURITY;
ALTER TABLE prospects          FORCE  ROW LEVEL SECURITY;
ALTER TABLE prospect_shortlist ENABLE ROW LEVEL SECURITY;
ALTER TABLE prospect_shortlist FORCE  ROW LEVEL SECURITY;
ALTER TABLE enquiries          ENABLE ROW LEVEL SECURITY;
ALTER TABLE enquiries          FORCE  ROW LEVEL SECURITY;
ALTER TABLE contact_bridges    ENABLE ROW LEVEL SECURITY;
ALTER TABLE contact_bridges    FORCE  ROW LEVEL SECURITY;

-- The one public read branch in this schema.
--
-- An unscoped session — which is what an anonymous visitor is — matches only the third
-- clause, so it sees live published listings and nothing else. The owner sees their own
-- whatever the state, and a delegated firm sees the ones for units it manages, because
-- advertising a flat is squarely what a management grant is for.
--
-- WITH CHECK has no public branch: publishing is a write, and a write always needs a
-- tenant. That asymmetry is the point — the hole is read-only by construction.
DROP POLICY IF EXISTS listings_public_read ON listings;
CREATE POLICY listings_public_read ON listings
    USING (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.read')
           OR (state = 'live' AND published_at IS NOT NULL))
    WITH CHECK (tenant_id = current_tenant_id()
           OR is_platform_session()
           OR is_delegated_unit(tenant_id, property_id, unit_id, unit_parent_id, 'property.write'));

-- A prospect belongs to nobody, so the row is the platform's. The site reads a prospect
-- by presenting its token, which the application resolves — never by scanning the table.
DROP POLICY IF EXISTS prospects_platform_only ON prospects;
CREATE POLICY prospects_platform_only ON prospects
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

DROP POLICY IF EXISTS prospect_shortlist_platform_only ON prospect_shortlist;
CREATE POLICY prospect_shortlist_platform_only ON prospect_shortlist
    USING (is_platform_session())
    WITH CHECK (is_platform_session());

-- An enquiry is the first row in this funnel that belongs to somebody: the owner whose
-- listing it is. Ordinary tenancy, and nothing else.
--
-- The first version had a delegated branch written as
-- `EXISTS (SELECT 1 FROM listings l WHERE l.id = listing_id)`, on the reasoning that a
-- firm which can see the listing may answer its enquiries. That was a leak, and the
-- isolation test found it: **listings is publicly readable**, so the subquery was true for
-- everybody, and an anonymous visitor could read every enquiry on every published listing
-- — names, messages and all.
--
-- The lesson generalises and is why it is written here rather than fixed quietly: once one
-- table is world-readable, any policy that reaches it through a subquery inherits that.
-- Assertion 17 cannot see this — the policy does mention current_tenant_id(), so it looks
-- correct — and a delegated branch on this table has to be written against the property,
-- which means denormalising it here. That is a later story; until then a management firm
-- reads enquiries through the owner's session.
DROP POLICY IF EXISTS enquiries_tenant_isolation ON enquiries;
CREATE POLICY enquiries_tenant_isolation ON enquiries
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

DROP POLICY IF EXISTS contact_bridges_tenant_isolation ON contact_bridges;
CREATE POLICY contact_bridges_tenant_isolation ON contact_bridges
    USING (tenant_id = current_tenant_id() OR is_platform_session())
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session());

-- A withdrawn listing is the record of what was advertised at what rent, which is what a
-- rent-control or misrepresentation complaint turns on. An enquiry likewise.
DROP POLICY IF EXISTS listings_no_delete ON listings;
CREATE POLICY listings_no_delete ON listings AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS enquiries_no_delete ON enquiries;
CREATE POLICY enquiries_no_delete ON enquiries AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));
DROP POLICY IF EXISTS contact_bridges_no_delete ON contact_bridges;
CREATE POLICY contact_bridges_no_delete ON contact_bridges AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON listings TO dwellm8_property, dwellm8_discovery;
GRANT SELECT, INSERT, UPDATE ON prospects, prospect_shortlist, enquiries, contact_bridges
    TO dwellm8_discovery;
GRANT SELECT ON listings TO dwellm8_lease, dwellm8_money, dwellm8_identity, dwellm8_notify;
GRANT SELECT, UPDATE ON enquiries TO dwellm8_property;
-- The purge grant for these tables is with the others, after dwellm8_purge is created:
-- this file is applied top to bottom and the role does not exist yet here.

