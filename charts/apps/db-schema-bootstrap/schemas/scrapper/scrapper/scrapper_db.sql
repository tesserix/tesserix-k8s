-- =============================================================================
-- Social Media Scrapper — DB Bootstrap
-- Idempotent: safe to run repeatedly via the db-schema-bootstrap CronJob
-- =============================================================================
--
-- Tables themselves are created/owned by the application:
--   • src/models/database.py   — scrape_jobs, profiles, reports, products, settings
--   • src/models/campaigns.py  — campaigns, connected_accounts
-- via SQLAlchemy `Base.metadata.create_all` at startup. This bootstrap script
-- handles the bits SQLAlchemy can't:
--   1. Permissions on the schema for the runtime role
--   2. Indexes the ORM doesn't declare (perf)
--   3. Reference seeds (default products)
--
-- Every statement is idempotent (IF NOT EXISTS / ON CONFLICT DO NOTHING).
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 1. Permissions — give the `scrapper` runtime role full access to public
-- ---------------------------------------------------------------------------
GRANT ALL ON SCHEMA public TO scrapper;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO scrapper;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO scrapper;

GRANT ALL ON ALL TABLES IN SCHEMA public TO scrapper;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO scrapper;

-- ---------------------------------------------------------------------------
-- 2. Indexes the ORM doesn't already declare
--    Wrapped in DO blocks so they're skipped cleanly if the table is missing
--    (i.e. before scrapper-api has booted for the first time).
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'profiles') THEN
    -- profiles.scraped_at descending — most "recent profiles" lookups
    CREATE INDEX IF NOT EXISTS ix_profiles_scraped_at_desc
      ON profiles (scraped_at DESC);
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'campaigns') THEN
    CREATE INDEX IF NOT EXISTS ix_campaigns_status        ON campaigns (status);
    CREATE INDEX IF NOT EXISTS ix_campaigns_scheduled_at  ON campaigns (scheduled_at);
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'connected_accounts') THEN
    -- platform is already UNIQUE, but a partial index on is_active speeds up
    -- the "active accounts only" query in the publishers registry.
    CREATE INDEX IF NOT EXISTS ix_connected_accounts_active
      ON connected_accounts (platform) WHERE is_active = true;
  END IF;

  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'scrape_jobs') THEN
    CREATE INDEX IF NOT EXISTS ix_scrape_jobs_status_created
      ON scrape_jobs (status, created_at DESC);
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- 3. Reference seed — default products (Marktly + FanZone)
--    The application also seeds these at startup; this is a safety net so
--    a fresh DB with no app boot still has the catalogue available.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'products') THEN
    INSERT INTO products (id, slug, name, product_type, description, target_keywords, is_active, created_at, updated_at)
    VALUES
      (gen_random_uuid()::text, 'marktly',  'Marktly',  'marketplace',
       'Online marketplace for buying and selling products, deals, and local business support',
       '["marketplace","deals","local business","sale","shopping"]'::json,
       true, NOW(), NOW()),
      (gen_random_uuid()::text, 'fanzone',  'FanZone',  'sports-fan-platform',
       'Cricket and sports fan platform — quizzes, predictions, fantasy leagues, fan communities',
       '["cricket","ipl","fantasy sports","sports fan","prediction","quiz"]'::json,
       true, NOW(), NOW())
    ON CONFLICT (slug) DO NOTHING;
  END IF;
END
$$;
