-- ===========================================================================
-- app and platform roles
-- ===========================================================================

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

-- ADR-0021 §4. The demo cleanup job's role.
--
-- Separate from dwellm8_platform on purpose. This schema protects its history with two
-- locks — the privilege is revoked *and* a RESTRICTIVE policy refuses the delete — and
-- granting DELETE back to the platform role would remove one of them for onboarding,
-- support and reporting alike. A third role keeps both locks intact everywhere except
-- the one job that needs them open, and that job's policy still only reaches a sandbox.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dwellm8_purge') THEN
        CREATE ROLE dwellm8_purge LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    END IF;
END
$$;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_purge;
GRANT USAGE ON SCHEMA public TO dwellm8_purge;
GRANT dwellm8_app TO dwellm8_purge;

GRANT CONNECT ON DATABASE dwellm8 TO dwellm8_api, dwellm8_platform;
GRANT USAGE ON SCHEMA public TO dwellm8_api, dwellm8_platform;
GRANT dwellm8_app TO dwellm8_api, dwellm8_platform;

-- Deliberately NOT granted here: membership of dwellm8_platform for the table
-- owner.
--
-- It is tempting, because a data migration in this file cannot otherwise touch a
-- row (see the migrations section). But the bootstrap job and — today — the API
-- both connect as dwellm8, so making the owner a member of dwellm8_platform
-- would make every request platform-exempt and switch tenant isolation off for
-- the whole application, silently, with every policy still reading correctly.
--
-- Verified against the cluster rather than assumed: the API deployment's
-- DATABASE_URL uses the CNPG app credentials, whose username is dwellm8. Until
-- the API connects as dwellm8_api, the owner must stay unexempted, and the
-- migrations section pays for that with an explicit, transaction-scoped window
-- instead.

ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO dwellm8_app;
ALTER DEFAULT PRIVILEGES FOR ROLE dwellm8 IN SCHEMA public
    GRANT USAGE, SELECT ON SEQUENCES TO dwellm8_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO dwellm8_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO dwellm8_app;
GRANT EXECUTE ON FUNCTION current_tenant_id() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_platform_session() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION current_grant_id() TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_delegated(uuid, uuid, text) TO dwellm8_app;
GRANT EXECUTE ON FUNCTION current_active_grant(uuid, text) TO dwellm8_app;
GRANT EXECUTE ON FUNCTION is_delegated_unit(uuid, uuid, uuid, uuid, text) TO dwellm8_app;

-- After the blanket grant above, not before it, or it would hand DELETE straight
-- back. A grant is history the moment it exists: the RESTRICTIVE policy refuses
-- the delete, and withholding the privilege means a session never reaches the
-- policy at all. Two locks, because the record of who was allowed to touch an
-- owner's property is exactly what a bad actor would want gone.
REVOKE DELETE ON delegation_grants, delegation_grant_scopes FROM dwellm8_app;

-- And the tree, for the reason written above its RESTRICTIVE policies: a
-- deleted unit orphans the money posted against it. ADR-0009.
REVOKE DELETE ON properties, blocks, units FROM dwellm8_app;

-- The ledger is append-only, and UPDATE is revoked as well as DELETE — which is
-- the difference between this table and every other one in the file. A
-- corrected amount that leaves no trace is indistinguishable from a corrected
-- amount that was theft. ADR-0006 §3: the only correction is a reversing entry.
REVOKE UPDATE, DELETE ON journal_entries, ledger_postings FROM dwellm8_app;

-- A payment does have a lifecycle, so UPDATE stays; DELETE does not. An
-- abandoned collection is the record an owner asks for when a tenant says they
-- paid, and a webhook delivery is evidence whether or not it was ever acted on.
-- ADR-0011 §4.
REVOKE DELETE ON payments, payment_events FROM dwellm8_app;

-- And the reconciliation tables. A settlement file that was ingested and a
-- disagreement that was found are the evidence in the dispute that comes later,
-- and a batch's totals are the provider's statement rather than our note of it —
-- so the batch loses UPDATE as well. ADR-0012 §6.
REVOKE DELETE ON settlement_batches, settlement_lines, settlement_drift,
    reconciliation_runs FROM dwellm8_app;
REVOKE UPDATE ON settlement_batches FROM dwellm8_app;

-- ADR-0015. A run that escalated and a step that failed are the evidence in the
-- dispute that follows, and the reason this record exists rather than relying on
-- Temporal's is precisely that it has to survive longer than a retention window.
REVOKE DELETE ON workflow_runs, workflow_steps FROM dwellm8_app;

-- The ageing view, for the reason ledger_balances is revoked below: GRANT ... ON
-- ALL TABLES covers views, and a privilege list that claims an aggregate can be
-- written is a privilege list nobody can review.
REVOKE INSERT, UPDATE, DELETE ON settlement_drift_ageing FROM dwellm8_app;

-- The chart of accounts and the posting templates are the rule, not the data.
-- The application reads them; this file is the only thing that writes them, so a
-- request cannot invent an account and post against it.
REVOKE INSERT, UPDATE, DELETE ON ledger_accounts, posting_templates,
    posting_template_lines FROM dwellm8_app;

-- And the statutory rules, for the same reason one step further out: a request
-- that can write a TDS rate is a request that can decide its own tax. ADR-0023 §2
-- — a rate change is a reviewed commit to this file, and assertion 18 fails the
-- bootstrap if the privilege ever comes back.
REVOKE INSERT, UPDATE, DELETE ON statutory_rules, statutory_rule_slabs
    FROM dwellm8_app;
REVOKE INSERT, UPDATE, DELETE ON statutory_rules_review_due FROM dwellm8_app;
-- ADR-0031, and the same argument: a request that can write the fee rate is a
-- request that can price itself at zero.
REVOKE INSERT, UPDATE, DELETE ON platform_fee_rules FROM dwellm8_app;
-- The price is Dwellm8's own, and the product owner changes it. Handed back to
-- the platform role only — after the revoke, or the blanket grant above would
-- have undone it — so a rate change is an audited platform act rather than
-- something a tenant's request can reach. dwellm8_app is not a member of
-- dwellm8_platform, so this does not give the request path the privilege back,
-- and assertion 18 still fails the bootstrap if anything ever does.
GRANT INSERT, UPDATE ON platform_fee_rules TO dwellm8_platform;

-- GRANT ... ON ALL TABLES covers views too, so the blanket grant above handed
-- out INSERT, UPDATE and DELETE on a balances view. PostgreSQL would refuse all
-- three anyway — an aggregate view is not updatable — but a privilege list that
-- claims a balance can be written is a privilege list nobody can review.
REVOKE INSERT, UPDATE, DELETE ON ledger_balances FROM dwellm8_app;

-- identity_principals holds a verified phone number and email for every person
-- who has ever signed in, and it has no tenant_id — so row-level security has
-- nothing to scope it by, and the blanket GRANT above would let any module read
-- every principal on the platform.
--
-- The privilege is the boundary here rather than a policy: only the identity
-- module needs this table, and it holds its grant directly. ADR-0027 §6.
REVOKE ALL ON identity_principals FROM dwellm8_app;


-- ADR-0021 §4. And DELETE back, to the purge role only.
--
-- After every REVOKE above, so this is the last word. Every one of these tables refuses
-- the delete in its policy unless the row belongs to a sandbox, so the privilege alone
-- reaches nothing — but without the privilege the policy is never consulted, which is
-- what the two-lock design means and why this grant has to be explicit and narrow.
GRANT DELETE ON properties, blocks, units,
                delegation_grants, delegation_grant_scopes,
                journal_entries, ledger_postings,
                payments, payment_events,
                settlement_lines, settlement_drift,
                leases, lease_parties, rent_schedule,
                property_ownership,
                workflow_runs, workflow_steps,
                kyc_verifications, kyc_access_log,
                listings, enquiries, contact_bridges, prospects, prospect_shortlist,
                audit_events, organisations, demo_sessions
    TO dwellm8_purge;

-- No ALTER ROLE ... NOBYPASSRLS here: changing the attribute at all requires
-- superuser, which this job does not have and should not want. The roles are
-- created without it, and the guard that matters is the assertion in
-- 003_tenancy_assertions.sql, which fails the bootstrap if it ever appears.

