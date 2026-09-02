-- DevAI evaluation datasets: anonymised product snapshots written by the
-- devai-sandbox-operator sync jobs (k8s/operators/db-anonymise). One schema
-- per product; the sync worker TRUNCATE+COPYs, it never runs DDL, so this
-- file owns the schema. Listed in reapplyExistingSchemas and reapplied every
-- run — keep every statement idempotent.

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'devai_evals') THEN
    EXECUTE 'GRANT CONNECT ON DATABASE devai_evals_db TO devai_evals';
  END IF;
END $$;

-- Kora (claim: k8s/operators/db-anonymise/claims/kora.yaml).
-- Columns mirror the claimed subset of kora_db public.users only.
CREATE SCHEMA IF NOT EXISTS kora;

CREATE TABLE IF NOT EXISTS kora.users (
    id UUID PRIMARY KEY,
    firebase_uid TEXT UNIQUE NOT NULL,
    email TEXT,
    display_name TEXT,
    apple_refresh_token TEXT
);

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'devai_evals') THEN
    EXECUTE 'GRANT USAGE ON SCHEMA kora TO devai_evals';
    EXECUTE 'GRANT SELECT, INSERT, TRUNCATE ON ALL TABLES IN SCHEMA kora TO devai_evals';
  END IF;
END $$;
