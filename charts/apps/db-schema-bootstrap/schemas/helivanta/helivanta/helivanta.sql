-- Grants only. The `helivanta` database and its owner role already exist
-- (CNPG Cluster bootstrap); Helivanta's own schema is applied separately by
-- `backend/cmd/migrate` (slice 1b), not by this chart. This file mirrors
-- what `dev/init-db.sql` in the helivanta repo does locally for `hms_app`,
-- so the runtime role gets the same read/write grants in prod that it has
-- in dev.
--
-- The owner role renamed hms -> helivanta (D9); the application role did
-- not. `ALTER DEFAULT PRIVILEGES FOR ROLE` must name `helivanta`, not `hms`
-- — naming the wrong role here silently produces tables `hms_app` cannot
-- read, which only surfaces as a permission error on the first API request.
GRANT USAGE ON SCHEMA public TO hms_app;
ALTER DEFAULT PRIVILEGES FOR ROLE helivanta IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO hms_app;
ALTER DEFAULT PRIVILEGES FOR ROLE helivanta IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO hms_app;
