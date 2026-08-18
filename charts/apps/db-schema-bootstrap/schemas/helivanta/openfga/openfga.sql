-- OpenFGA's datastore. OpenFGA owns and migrates its own schema — a
-- migrate Job applied in Task 6 — so this file only hands the role its
-- database. The bootstrap creates the database from this directory's file
-- name; the `openfga` role is a CNPG managed role, so it may not exist yet
-- on a fresh sync.
--
-- Deliberately unguarded, unlike the sibling helivanta.sql's hms_app grants.
-- A `pg_roles` existence guard was here previously and was removed: if
-- `openfga` doesn't exist yet, an unguarded GRANT fails LOUDLY — the
-- bootstrap script's error grep catches it, the Job reports failure, and the
-- CronJob's next tick (30m) retries once CNPG has reconciled the role. A
-- guard instead makes the grants silently no-op while the Job still reports
-- SUCCESS, leaving OpenFGA with a database it cannot write to and no error
-- anywhere — the weaker failure mode. Loud-and-self-healing beats
-- quiet-and-wrong here.
GRANT CONNECT, CREATE, TEMP ON DATABASE openfga TO openfga;
GRANT USAGE, CREATE ON SCHEMA public TO openfga;
