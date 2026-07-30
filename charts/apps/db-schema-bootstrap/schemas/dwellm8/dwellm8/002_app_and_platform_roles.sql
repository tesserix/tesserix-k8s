-- The two roles the application uses, and why there are two.
--
-- dwellm8_api  — everything a request does. Owns nothing, cannot bypass RLS,
--                and is the role a handler's connection runs as.
-- dwellm8_platform — the few operations that cannot be tenant-scoped, because
--                they create or span tenants: onboarding an organisation,
--                platform reporting, and an audited support session. Its
--                exemption is written into each policy via is_platform_session(),
--                not into a role attribute — BYPASSRLS needs superuser, which
--                CNPG withholds, and an attribute is invisible where it matters.
--
-- Creating an organisation is the clearest case. With FORCE row level security
-- on, an INSERT into organisations must satisfy the policy — and the policy
-- compares against the organisation being created, which does not exist yet.
-- No amount of policy cleverness fixes that; it is not a tenant-scoped act.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_api') THEN
        CREATE ROLE dwellm8_api LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_platform') THEN
        CREATE ROLE dwellm8_platform LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_api, dwellm8_platform;
GRANT USAGE ON SCHEMA public TO dwellm8_api, dwellm8_platform;
GRANT dwellm8_app TO dwellm8_api, dwellm8_platform;

ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dwellm8_app;
ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO dwellm8_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dwellm8_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dwellm8_app;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_platform_session() TO dwellm8_app;

-- No ALTER ROLE ... NOBYPASSRLS here: changing the attribute at all requires
-- superuser, which this job does not have and should not want. The roles are
-- created without it, and the guard that matters is the assertion in
-- 003_tenancy_assertions.sql, which fails the bootstrap if it ever appears.
