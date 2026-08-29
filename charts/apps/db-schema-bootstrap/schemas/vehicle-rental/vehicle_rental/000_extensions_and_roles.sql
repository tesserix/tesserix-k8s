-- ============================================================================
-- Vehicle rental — the vehicle_rental database.
--
-- The bootstrap chart's contract is one .sql file per DATABASE, so these
-- chapters are concatenated by `combineInto: vehicle_rental` rather than being
-- separate databases.
--
-- Every statement here is idempotent by construction and safe to replay every
-- 30 minutes, which is why this app sets applySchemaToExistingDatabases: true.
-- No ORM manages these tables at runtime, so there is no AutoMigrate to fight.
--
-- Chapters:
--   000 extensions, schemas and roles
--   010 tenancy — current_tenant_id(), the platform exemption, audit
--   020 identity — tenant, staff, pickup points
--   030 catalog — vehicles, documents, media
--   040 pricing — rate plans, modifiers, quotes
--   050 availability and booking — the exclusion constraint
--   060 customers and KYC
--   070 payments
--   080 telematics, maintenance, incidents, partners, trips
--   090 storefront
--   900 RLS policies and grants — last, so every table exists to be covered
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";     -- gen_random_uuid, digest
CREATE EXTENSION IF NOT EXISTS "citext";       -- case-insensitive email
CREATE EXTENSION IF NOT EXISTS "postgis";      -- geography(Point) / (Polygon)

-- btree_gist is not optional: the availability exclusion constraint mixes a
-- uuid equality with a range overlap in one index, and GiST cannot do the uuid
-- half without it. Without this line the whole double-booking guarantee fails
-- to create, and it fails at DDL time rather than at booking time.
CREATE EXTENSION IF NOT EXISTS "btree_gist";

-- One schema per module. A module writes only to its own schema and reads
-- others through views — this is what makes the module boundary real.
CREATE SCHEMA IF NOT EXISTS identity;
CREATE SCHEMA IF NOT EXISTS catalog;
CREATE SCHEMA IF NOT EXISTS pricing;
CREATE SCHEMA IF NOT EXISTS availability;
CREATE SCHEMA IF NOT EXISTS booking;
CREATE SCHEMA IF NOT EXISTS handover;
CREATE SCHEMA IF NOT EXISTS payments;
CREATE SCHEMA IF NOT EXISTS kyc;
CREATE SCHEMA IF NOT EXISTS telematics;
CREATE SCHEMA IF NOT EXISTS maintenance;
CREATE SCHEMA IF NOT EXISTS incidents;
CREATE SCHEMA IF NOT EXISTS partners;
CREATE SCHEMA IF NOT EXISTS trips;
CREATE SCHEMA IF NOT EXISTS storefront;
CREATE SCHEMA IF NOT EXISTS support;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS financial_archive;

-- uuid v7: time-ordered, so index locality is good and ids do not leak counts.
-- Postgres 17 has no uuidv7() of its own, so this is the standard layout —
-- 48-bit millisecond timestamp, version 7, variant 10, random rest.
CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid
    LANGUAGE sql VOLATILE PARALLEL SAFE AS
$$
  SELECT encode(
    set_bit(
      set_bit(
        overlay(
          uuid_send(gen_random_uuid())
          PLACING substring(int8send((extract(epoch FROM clock_timestamp()) * 1000)::bigint) FROM 3)
          FROM 1 FOR 6
        ),
        52, 1
      ),
      53, 1
    ),
    'hex')::uuid;
$$;

COMMENT ON FUNCTION uuid_generate_v7() IS
    'Time-ordered v7 UUID. Primary key default on every table in this database.';

-- Two login roles, created by CNPG's managed.roles, not here. This file only
-- grants; creating them would fight the operator every reconcile.
--   vehicle_rental_api      — the storefront and admin surfaces. Tenant-scoped.
--   vehicle_rental_platform — onboarding and platform reporting. Crosses tenants
--                             deliberately, and only via the exemption in 010.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vehicle_rental_app') THEN
        CREATE ROLE vehicle_rental_app NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'vehicle_rental_platform_role') THEN
        CREATE ROLE vehicle_rental_platform_role NOLOGIN;
    END IF;
END
$$;

GRANT vehicle_rental_app TO vehicle_rental;
