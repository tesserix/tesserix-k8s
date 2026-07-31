-- OpenFGA's datastore (ADR-0020). OpenFGA owns and migrates its own schema —
-- the dwellm8-openfga migrate Job — so this file only hands the role its
-- database. The bootstrap creates the database from this directory's name;
-- the role is a CNPG managed role, so it may not exist yet on a fresh sync.
DO $$
BEGIN
    IF EXISTS (SELECT FROM pg_roles WHERE rolname = 'openfga') THEN
        GRANT CONNECT, CREATE, TEMP ON DATABASE openfga TO openfga;
        GRANT USAGE, CREATE ON SCHEMA public TO openfga;
    END IF;
END $$;
