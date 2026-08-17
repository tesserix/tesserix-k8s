-- OpenFGA's datastore. OpenFGA owns and migrates its own schema — a
-- migrate Job applied in Task 6 — so this file only hands the role its
-- database. The bootstrap creates the database from this directory's file
-- name; the `openfga` role is a CNPG managed role, so it may not exist yet
-- on a fresh sync.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'openfga') THEN
        GRANT CONNECT, CREATE, TEMP ON DATABASE openfga TO openfga;
        GRANT USAGE, CREATE ON SCHEMA public TO openfga;
    END IF;
END $$;
