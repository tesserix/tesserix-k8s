-- ============================================================================
-- Dwellm8 — the whole schema for the dwellm8 database.
--
-- The bootstrap chart's contract is one .sql file per DATABASE, named after it
-- (db_name=$(basename "$sql_file" .sql)). Four files here meant four
-- databases, so the modules are sections of this one file instead.
--
-- Unlike the frozen pg_dump snapshots this chart was built for, every
-- statement below is idempotent by construction and safe to replay — which is
-- why dwellm8 sets applySchemaToExistingDatabases: true. Nothing here is
-- managed by an ORM at runtime, so there is no AutoMigrate to fight.
--
-- Sections:
--   1. Extensions and per-module roles
--   2. Tenancy — organisations, audit trail, RLS
--   3. Property, block and unit — the tree everything else hangs from
--   4. Ledger — chart of accounts, immutable postings, derived balances
--   5. Application and platform roles
--   6. Data migrations — after the roles, or they silently touch nothing
--   7. Assertions that fail the bootstrap if the model is violated
-- ============================================================================


-- ===========================================================================
-- extensions and roles
-- ===========================================================================

-- Dwellm8 — extensions, and the roles that make ADR-0001's ownership rule real.
--
-- One writer per table is a review rule until the database enforces it. Each
-- module gets a role; the API connects as dwellm8_app, which is a member of
-- all of them, and a future extracted module connects as its own role only.
--
-- Idempotent: this file is replayed by the bootstrap CronJob every 30 minutes.

CREATE EXTENSION IF NOT EXISTS "pgcrypto";      -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS "citext";        -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS "btree_gist";    -- exclusion constraints for effective dating

DO $$
DECLARE
    module_role text;
BEGIN
    FOREACH module_role IN ARRAY ARRAY[
        'dwellm8_identity', 'dwellm8_property', 'dwellm8_lease', 'dwellm8_money',
        'dwellm8_maintenance', 'dwellm8_community', 'dwellm8_discovery', 'dwellm8_notify'
    ] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = module_role) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', module_role);
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_app') THEN
        CREATE ROLE dwellm8_app NOLOGIN;
    END IF;
END
$$;

-- The monolith holds every module role. When a module is extracted per
-- ADR-0001 §6, it drops to its own role and this membership is revoked.
GRANT dwellm8_identity, dwellm8_property, dwellm8_lease, dwellm8_money,
      dwellm8_maintenance, dwellm8_community, dwellm8_discovery, dwellm8_notify
   TO dwellm8_app;

GRANT dwellm8_app TO dwellm8;

