-- ===========================================================================
-- what a property is like — description, features, and what is nearby (#354)
-- ===========================================================================
-- The record could say where a building is and what it costs, and nothing
-- about what living there is like. A renter asks the other question first.
--
-- Building-level facts sit on properties, flat-level ones on units, and the
-- places nearby get their own table because there are many of them and each
-- carries a distance. None of it is denormalised onto listings yet — that is
-- #355, and belongs with the renter-facing view that will read it.

-- ---------------------------------------------------------------------------
-- the building
-- ---------------------------------------------------------------------------
ALTER TABLE properties ADD COLUMN IF NOT EXISTS about     text;
ALTER TABLE properties ADD COLUMN IF NOT EXISTS amenities text[] NOT NULL DEFAULT '{}';

-- A vocabulary rather than free text: a renter filters on "has a lift", and
-- filtering on prose written by four hundred managers is not a feature.
-- NOT VALID so the 30-minute re-apply never rescans the table.
ALTER TABLE properties DROP CONSTRAINT IF EXISTS properties_amenities_known;
ALTER TABLE properties ADD CONSTRAINT properties_amenities_known CHECK (
    amenities <@ ARRAY[
        'lift', 'power_backup', 'security', 'cctv', 'gated', 'visitor_parking',
        'water_supply_24x7', 'borewell', 'rainwater_harvesting', 'sewage_treatment',
        'gym', 'swimming_pool', 'clubhouse', 'play_area', 'park', 'jogging_track',
        'community_hall', 'temple', 'shops_in_complex', 'waste_collection',
        'fire_safety', 'intercom', 'solar', 'ev_charging'
    ]::text[])
    NOT VALID;

COMMENT ON COLUMN properties.about IS
    '#354. The building and its neighbourhood in the manager''s own words.';

-- ---------------------------------------------------------------------------
-- the flat
-- ---------------------------------------------------------------------------
ALTER TABLE units ADD COLUMN IF NOT EXISTS about           text;
ALTER TABLE units ADD COLUMN IF NOT EXISTS features        text[] NOT NULL DEFAULT '{}';
ALTER TABLE units ADD COLUMN IF NOT EXISTS bathrooms       int;
ALTER TABLE units ADD COLUMN IF NOT EXISTS balconies       int;
ALTER TABLE units ADD COLUMN IF NOT EXISTS covered_parking int;
ALTER TABLE units ADD COLUMN IF NOT EXISTS facing          text;
ALTER TABLE units ADD COLUMN IF NOT EXISTS furnishing      text;

ALTER TABLE units DROP CONSTRAINT IF EXISTS units_counts_sane;
ALTER TABLE units ADD CONSTRAINT units_counts_sane CHECK (
    (bathrooms       IS NULL OR bathrooms       BETWEEN 0 AND 20)
AND (balconies       IS NULL OR balconies       BETWEEN 0 AND 20)
AND (covered_parking IS NULL OR covered_parking BETWEEN 0 AND 20))
    NOT VALID;

ALTER TABLE units DROP CONSTRAINT IF EXISTS units_facing_known;
ALTER TABLE units ADD CONSTRAINT units_facing_known CHECK (
    facing IS NULL OR facing IN (
        'north', 'south', 'east', 'west',
        'north_east', 'north_west', 'south_east', 'south_west'))
    NOT VALID;

-- Three states, because "semi furnished" is what half the market advertises
-- and reducing it to a boolean loses the answer people ask for.
ALTER TABLE units DROP CONSTRAINT IF EXISTS units_furnishing_known;
ALTER TABLE units ADD CONSTRAINT units_furnishing_known CHECK (
    furnishing IS NULL OR furnishing IN ('unfurnished', 'semi_furnished', 'fully_furnished'))
    NOT VALID;

ALTER TABLE units DROP CONSTRAINT IF EXISTS units_features_known;
ALTER TABLE units ADD CONSTRAINT units_features_known CHECK (
    features <@ ARRAY[
        'modular_kitchen', 'chimney', 'wardrobes', 'false_ceiling', 'air_conditioning',
        'geyser', 'piped_gas', 'water_purifier', 'washing_machine', 'refrigerator',
        'microwave', 'sofa', 'beds', 'dining_table', 'study', 'servant_room',
        'store_room', 'pooja_room', 'private_terrace', 'garden', 'balcony_covered',
        'inverter', 'internet', 'pet_friendly', 'wheelchair_access'
    ]::text[])
    NOT VALID;

-- ---------------------------------------------------------------------------
-- what is nearby
-- ---------------------------------------------------------------------------
--
-- Distance is stored, not computed: the manager knows the walk is 700 metres
-- along the road, and the straight line between two geocodes does not.
CREATE TABLE IF NOT EXISTS property_places (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- The owner's tenant, as on properties. A firm reaches these through its
    -- mandate, exactly as it reaches the property itself.
    tenant_id     uuid NOT NULL REFERENCES organisations(id),
    property_id   uuid NOT NULL,

    category      text NOT NULL CHECK (category IN (
                      'school', 'college', 'childcare', 'coaching',
                      'hospital', 'clinic', 'pharmacy',
                      'metro', 'bus', 'railway', 'airport',
                      'market', 'mall', 'supermarket', 'restaurant',
                      'park', 'gym', 'bank', 'atm',
                      'place_of_worship', 'police', 'fire_station', 'petrol', 'other')),
    name          text NOT NULL CHECK (btrim(name) <> ''),
    -- Metres, so a 400 m walk does not become 0.4 and then 0. Capped at 50 km:
    -- past that it is not nearby, it is the same city.
    distance_m    int NOT NULL CHECK (distance_m > 0 AND distance_m <= 50000),
    travel_mode   text NOT NULL DEFAULT 'walk' CHECK (travel_mode IN ('walk', 'drive', 'transit')),
    -- What a parent filters on for a school — board, level, government or
    -- private, co-ed. Free-form because every category tags differently and a
    -- per-category vocabulary would be twenty CHECKs nobody maintains.
    tags          text[] NOT NULL DEFAULT '{}',
    note          text,
    position      int NOT NULL DEFAULT 0,

    -- A school that closes stops being shown without the record losing that it
    -- was once advertised.
    state         text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'retired')),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT property_places_property_fkey FOREIGN KEY (property_id, tenant_id)
        REFERENCES properties (id, tenant_id)
);

COMMENT ON TABLE property_places IS
    '#354. Named places near a property, with the distance to each. Entered by the manager: what is nearby is a claim they make, not a geocoding result.';

-- One entry per place. Retired rows are excluded so a closed school can be
-- re-added under the same name when it reopens.
CREATE UNIQUE INDEX IF NOT EXISTS property_places_once
    ON property_places (tenant_id, property_id, category, lower(btrim(name)))
    WHERE state = 'active';
CREATE INDEX IF NOT EXISTS property_places_nearest_idx
    ON property_places (property_id, category, distance_m) WHERE state = 'active';

ALTER TABLE property_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE property_places FORCE  ROW LEVEL SECURITY;

-- Same shape as documents_tenant_isolation: a property-scoped grant reaches
-- the places on that property, not the whole portfolio (999, rule 5).
DROP POLICY IF EXISTS property_places_tenant_isolation ON property_places;
CREATE POLICY property_places_tenant_isolation ON property_places
    USING      (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, property_id, 'property.read'))
    WITH CHECK (tenant_id = current_tenant_id() OR is_platform_session()
                OR is_delegated(tenant_id, property_id, 'property.write'));

-- ADR-0029. A renter reads what is nearby from the public listing (#355), not
-- from here — this table also carries the buildings they do not live in.
DROP POLICY IF EXISTS property_places_resident_denied ON property_places;
CREATE POLICY property_places_resident_denied ON property_places AS RESTRICTIVE
    USING (NOT is_resident_session()) WITH CHECK (NOT is_resident_session());

DROP POLICY IF EXISTS property_places_no_delete ON property_places;
CREATE POLICY property_places_no_delete ON property_places AS RESTRICTIVE FOR DELETE
    USING (sandbox_purge_permitted(tenant_id));

GRANT SELECT, INSERT, UPDATE ON property_places TO dwellm8_property;
GRANT SELECT ON property_places TO dwellm8_lease;
GRANT DELETE ON property_places TO dwellm8_purge;
