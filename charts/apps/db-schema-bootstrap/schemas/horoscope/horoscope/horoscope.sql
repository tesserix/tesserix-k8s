-- =============================================================================
-- Horoscope DB Bootstrap — permissions + reference data seed
-- Idempotent: safe to run repeatedly via the db-schema-bootstrap CronJob
-- Tables created by GORM AutoMigrate at app startup; this file handles:
--   1. Schema-level permissions (so future GORM-created tables inherit access)
--   2. Reference data: zodiac_signs lookup + geocode_cache
--   3. Per-user computed natal chart cache (charts table)
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permissions — grant horoscope user full access to public schema
-- ---------------------------------------------------------------------------
GRANT ALL ON SCHEMA public TO horoscope;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES   TO horoscope;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO horoscope;
GRANT ALL ON ALL TABLES    IN SCHEMA public TO horoscope;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO horoscope;

-- ---------------------------------------------------------------------------
-- 2. Required extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";   -- gen_random_uuid()

-- ---------------------------------------------------------------------------
-- 3. Reference table: zodiac_signs
--    Static lookup for the 12 tropical signs. Mirrors backend/internal/zodiac.
--    Seeded idempotently via ON CONFLICT.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS zodiac_signs (
    slug         VARCHAR(16)  PRIMARY KEY,
    name         VARCHAR(32)  NOT NULL,
    glyph        VARCHAR(4)   NOT NULL,
    element      VARCHAR(8)   NOT NULL,
    modality     VARCHAR(16)  NOT NULL,
    polarity     VARCHAR(16)  NOT NULL,
    ruler        VARCHAR(32)  NOT NULL,
    start_month  SMALLINT     NOT NULL,
    start_day    SMALLINT     NOT NULL,
    end_month    SMALLINT     NOT NULL,
    end_day      SMALLINT     NOT NULL,
    date_range   VARCHAR(64)  NOT NULL,
    tagline      TEXT         NOT NULL,
    traits       TEXT[]       NOT NULL DEFAULT '{}',
    lucky_numbers SMALLINT[]  NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

INSERT INTO zodiac_signs (slug, name, glyph, element, modality, polarity, ruler,
    start_month, start_day, end_month, end_day, date_range, tagline, traits, lucky_numbers)
VALUES
    ('aries',       'Aries',       '♈', 'Fire',  'Cardinal', 'Positive', 'Mars',     3, 21, 4, 19, 'Mar 21 – Apr 19', 'First through the door.',         ARRAY['Bold','Pioneering','Direct','Spirited'],         ARRAY[1,9,19]::smallint[]),
    ('taurus',      'Taurus',      '♉', 'Earth', 'Fixed',    'Negative', 'Venus',    4, 20, 5, 20, 'Apr 20 – May 20', 'Slow and certain wins.',          ARRAY['Grounded','Sensual','Patient','Devoted'],        ARRAY[2,6,24]::smallint[]),
    ('gemini',      'Gemini',      '♊', 'Air',   'Mutable',  'Positive', 'Mercury',  5, 21, 6, 20, 'May 21 – Jun 20', 'Two minds, one mood.',            ARRAY['Curious','Quick','Social','Adaptive'],           ARRAY[3,5,14]::smallint[]),
    ('cancer',      'Cancer',      '♋', 'Water', 'Cardinal', 'Negative', 'Moon',     6, 21, 7, 22, 'Jun 21 – Jul 22', 'Home is a feeling.',              ARRAY['Tender','Intuitive','Loyal','Protective'],       ARRAY[2,7,11]::smallint[]),
    ('leo',         'Leo',         '♌', 'Fire',  'Fixed',    'Positive', 'Sun',      7, 23, 8, 22, 'Jul 23 – Aug 22', 'Born to be seen.',                ARRAY['Generous','Radiant','Theatrical','Warm'],        ARRAY[1,5,19]::smallint[]),
    ('virgo',       'Virgo',       '♍', 'Earth', 'Mutable',  'Negative', 'Mercury',  8, 23, 9, 22, 'Aug 23 – Sep 22', 'Detail is devotion.',             ARRAY['Discerning','Methodical','Helpful','Refined'],   ARRAY[5,14,23]::smallint[]),
    ('libra',       'Libra',       '♎', 'Air',   'Cardinal', 'Positive', 'Venus',    9, 23, 10,22, 'Sep 23 – Oct 22', 'Beauty is balance.',              ARRAY['Charming','Fair','Aesthetic','Diplomatic'],      ARRAY[6,15,24]::smallint[]),
    ('scorpio',     'Scorpio',     '♏', 'Water', 'Fixed',    'Negative', 'Pluto',    10,23, 11,21, 'Oct 23 – Nov 21', 'Still water, deep current.',       ARRAY['Magnetic','Penetrating','Resolute','Private'],   ARRAY[4,13,21]::smallint[]),
    ('sagittarius', 'Sagittarius', '♐', 'Fire',  'Mutable',  'Positive', 'Jupiter',  11,22, 12,21, 'Nov 22 – Dec 21', 'The horizon is the point.',        ARRAY['Adventurous','Honest','Optimistic','Free'],      ARRAY[3,9,22]::smallint[]),
    ('capricorn',   'Capricorn',   '♑', 'Earth', 'Cardinal', 'Negative', 'Saturn',   12,22, 1, 19, 'Dec 22 – Jan 19', 'Climb, then climb again.',         ARRAY['Disciplined','Ambitious','Wry','Enduring'],      ARRAY[8,10,26]::smallint[]),
    ('aquarius',    'Aquarius',    '♒', 'Air',   'Fixed',    'Positive', 'Uranus',   1, 20, 2, 18, 'Jan 20 – Feb 18', 'The future, already arriving.',    ARRAY['Inventive','Independent','Idealistic','Detached'], ARRAY[4,7,11]::smallint[]),
    ('pisces',      'Pisces',      '♓', 'Water', 'Mutable',  'Negative', 'Neptune',  2, 19, 3, 20, 'Feb 19 – Mar 20', 'Two fish, one tide.',              ARRAY['Dreamy','Compassionate','Fluid','Artistic'],     ARRAY[3,12,18]::smallint[])
ON CONFLICT (slug) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4. geocode_cache — shared cache of Nominatim lookups across instances.
--    Reduces upstream calls so we stay well under OSM's 1 req/sec policy.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS geocode_cache (
    query        VARCHAR(256) PRIMARY KEY,
    display_name TEXT         NOT NULL,
    latitude     DOUBLE PRECISION NOT NULL,
    longitude    DOUBLE PRECISION NOT NULL,
    country      VARCHAR(128),
    osm_id       BIGINT,
    payload      JSONB        NOT NULL DEFAULT '{}'::jsonb,
    fetched_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_geocode_cache_fetched_at
    ON geocode_cache (fetched_at DESC);

-- ---------------------------------------------------------------------------
-- 5. charts — cached natal chart per user (one row per user, upserted).
--    Keyed by users.uid (the GORM-managed primary key). Stored as JSONB so
--    the schema can evolve as we add house systems / aspects without
--    schema migrations.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS charts (
    uid          VARCHAR(128) PRIMARY KEY,
    chart        JSONB        NOT NULL,
    accuracy     VARCHAR(32)  NOT NULL DEFAULT 'approximate-mvp',
    computed_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_charts_computed_at
    ON charts (computed_at DESC);

-- ---------------------------------------------------------------------------
-- 6. horoscope_cache — caches upstream horoscope-app-api responses across
--    pods (in-memory cache continues to serve hot reads).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS horoscope_cache (
    sign        VARCHAR(16)  NOT NULL,
    period      VARCHAR(16)  NOT NULL,    -- daily | weekly | monthly
    day_key     VARCHAR(16)  NOT NULL,    -- YYYY-MM-DD or 'TODAY'/'WEEK'/'MONTH'
    body        JSONB        NOT NULL,
    fetched_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    PRIMARY KEY (sign, period, day_key)
);

CREATE INDEX IF NOT EXISTS idx_horoscope_cache_period_fetched
    ON horoscope_cache (period, fetched_at DESC);

-- ---------------------------------------------------------------------------
-- 7. users — additive columns added by GORM AutoMigrate; explicit ALTERs here
--    keep the schema deterministic across the bootstrap CronJob runs.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables
               WHERE table_schema = 'public' AND table_name = 'users') THEN
        ALTER TABLE users ADD COLUMN IF NOT EXISTS birth_timezone VARCHAR(64);
        ALTER TABLE users ADD COLUMN IF NOT EXISTS tradition VARCHAR(16) DEFAULT 'western';
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 8. reading_cache — Claude-generated personalised readings, hash-keyed so
--    duplicate prompts hit cache instead of the API.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reading_cache (
    hash        VARCHAR(64)  PRIMARY KEY,
    uid         VARCHAR(128) NOT NULL,
    period      VARCHAR(16)  NOT NULL, -- daily | weekly | monthly | chart
    tradition   VARCHAR(16)  NOT NULL,
    source      VARCHAR(32)  NOT NULL, -- claude | fallback
    body        TEXT         NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reading_cache_uid       ON reading_cache (uid);
CREATE INDEX IF NOT EXISTS idx_reading_cache_period    ON reading_cache (period);
CREATE INDEX IF NOT EXISTS idx_reading_cache_created   ON reading_cache (created_at DESC);

-- ---------------------------------------------------------------------------
-- Final permissions sweep — ensure newly-created tables are accessible.
-- ---------------------------------------------------------------------------
GRANT ALL ON ALL TABLES    IN SCHEMA public TO horoscope;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO horoscope;
