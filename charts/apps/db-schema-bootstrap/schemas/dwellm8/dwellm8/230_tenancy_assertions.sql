-- ===========================================================================
-- tenancy assertions
-- ===========================================================================

-- Assertions about the tenancy model, run on every bootstrap.
--
-- Each of these has already been wrong once during development. A schema file
-- that shouts is worth more than a comment that hopes.

DO $$
DECLARE
    offending text;
BEGIN
    -- 1. Every tenant-scoped table must FORCE row level security, not merely
    --    enable it. A table's owner bypasses its own policies otherwise, and
    --    the bootstrap job is the owner.
    SELECT string_agg(c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relrowsecurity          -- RLS enabled
      AND NOT c.relforcerowsecurity -- but not forced
    ;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'RLS enabled but not FORCEd on: % — the owner would bypass every policy', offending;
    END IF;

    -- 2. Neither application role may hold BYPASSRLS. The platform exemption
    --    lives in the policies, where it is visible.
    SELECT string_agg(rolname, ', ') INTO offending
    FROM pg_roles
    WHERE rolname IN ('dwellm8_api', 'dwellm8_platform', 'dwellm8_app', 'dwellm8_purge')
      AND rolbypassrls;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'role(s) hold BYPASSRLS: % — the exemption belongs in a policy', offending;
    END IF;

    -- 3. Every policy states WITH CHECK explicitly, so a reader does not have
    --    to know PostgreSQL's fallback rule to see that writes are constrained.
    SELECT string_agg(format('%s.%s', tablename, policyname), ', ') INTO offending
    FROM pg_policies
    WHERE schemaname = 'public'
      AND cmd = 'ALL'
      AND with_check IS NULL;
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'policy without an explicit WITH CHECK: %', offending;
    END IF;

    -- 4. Neither delegation table may be deletable. Losing a revoked grant
    --    loses the record of what a firm was permitted to do, and when — which
    --    is the one thing an owner would later need. ADR-0005.
    --
    --    ADR-0021 scoped the predicate from `false` to sandbox_purge_permitted(), for the
    --    reason given at assertion 7: a demo sandbox has to be cleanable, and it is safe
    --    because no real effect may originate in one. The grantee still cannot erase
    --    anything — the predicate requires a platform session *and* a sandbox
    --    organisation, so a firm deleting the record of what it was permitted to do is
    --    exactly as impossible as it was.
    SELECT string_agg(t, ', ') INTO offending
    FROM unnest(ARRAY['delegation_grants', 'delegation_grant_scopes']) AS t
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           -- pg_policies.permissive is text, not boolean: 'RESTRICTIVE'.
           AND p.cmd = 'DELETE' AND p.permissive = 'RESTRICTIVE'
           AND (p.qual = 'false' OR p.qual LIKE '%sandbox_purge_permitted%'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'no RESTRICTIVE deny-delete policy on: % — a grantee could erase the evidence', offending;
    END IF;

    -- 5. A table that is property-scoped must say so in its policy. Passing
    --    NULL for row_property, or omitting the delegated branch entirely,
    --    silently widens a two-unit grant to the grantor's whole portfolio.
    --    This bit for the first time with ADR-0009's blocks table, as predicted.
    --
    --    is_delegated_unit() also satisfies it, and is strictly stronger: it
    --    checks the exact unit. A table that has both columns should use it.
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns col
      ON col.table_schema = 'public' AND col.table_name = c.relname
     AND col.column_name = 'property_id'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND NOT EXISTS (
          SELECT 1 FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
             AND (p.qual LIKE '%is_delegated(%property_id%'
               OR p.qual LIKE '%is_delegated_unit(%property_id%'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) with property_id whose policy does not pass it to is_delegated(): % '
                        '— a scoped grant would widen to the whole portfolio', offending;
    END IF;

    -- 6. And the same one level down. A table that identifies a unit must be
    --    judged at unit granularity, or a mandate over one flat reads every flat
    --    in the tower — which assertion 5 would happily allow, because
    --    property_id is passed and the check is honest about the wrong thing.
    --
    --    units itself is included by name: its unit column is `id`, so no column
    --    scan finds it, and it is the table where getting this wrong matters
    --    most. ADR-0009 §4.
    SELECT string_agg(DISTINCT t, ', ') INTO offending
    FROM (
        SELECT c.relname AS t
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN information_schema.columns col
          ON col.table_schema = 'public' AND col.table_name = c.relname
         AND col.column_name = 'unit_id'
        WHERE n.nspname = 'public' AND c.relkind = 'r'
        UNION
        SELECT 'units'
    ) unit_tables
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = unit_tables.t
           AND p.qual LIKE '%is_delegated_unit(%');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) identifying a unit whose policy does not use is_delegated_unit(): % '
                        '— a one-unit mandate would read every unit in the property', offending;
    END IF;

    -- 7. The ledger is append-only. Both tables need a RESTRICTIVE policy
    --    denying UPDATE and one denying DELETE — the privileges are revoked as
    --    well, but a future GRANT that hands them back must still hit a wall.
    --    ADR-0006 §3.
    --    The alias is `required_cmd` rather than `cmd` for a reason that cost a
    --    round of testing: with the obvious name, `p.cmd = cmd` inside the
    --    subquery resolves to pg_policies' own column, the condition becomes
    --    `p.cmd = p.cmd`, and the assertion passes as long as *either* policy
    --    exists. Measured — dropping ledger_postings_no_update and running the
    --    assertion block alone came out green.
    --
    --    ADR-0021 relaxed the DELETE half, and it is the only relaxation of this rule in
    --    the file. It reads `sandbox_purge_permitted(tenant_id)` rather than `false`,
    --    which means: no ledger row of a *real* organisation may ever be deleted, and a
    --    demo sandbox's may be purged by the platform.
    --
    --    That is a genuine weakening and its safety rests entirely on ADR-0021 §3 — no
    --    real effect may originate in a sandbox, so a sandbox ledger contains no real
    --    money. If that ban is ever weakened this must go back to `false`, and assertion
    --    16 is what would otherwise let the two drift apart. UPDATE stays absolute: there
    --    is no reason to edit a posting even in a demo, and the seed writes them once.
    SELECT string_agg(format('%s:%s', t, required_cmd), ', ') INTO offending
    FROM unnest(ARRAY['journal_entries', 'ledger_postings']) AS t
    CROSS JOIN unnest(ARRAY['UPDATE', 'DELETE']) AS required_cmd
    WHERE NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = t
           AND p.cmd = required_cmd AND p.permissive = 'RESTRICTIVE'
           AND (p.qual = 'false'
             OR (required_cmd = 'DELETE' AND p.qual LIKE '%sandbox_purge_permitted%')));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'the ledger is mutable: no RESTRICTIVE deny policy for % — a corrected '
                        'amount that leaves no trace is indistinguishable from theft. DELETE may '
                        'be scoped to sandbox_purge_permitted() and to nothing else; UPDATE may '
                        'not be scoped at all', offending;
    END IF;

    -- 8. Money is an integer of minor units. This is ADR-0007's standard
    --    arriving early, because the first table to hold an amount is landing
    --    now and an inexact column added later would be found by a rounding
    --    complaint rather than by a build.
    --
    --    Two rules, and the split is deliberate. Typing the column is what
    --    matters, so the first clause is about types: nothing money-shaped may
    --    be numeric, real, double precision or money. The second is about the
    --    name, so that *_minor keeps meaning what it says. An earlier version
    --    matched on the name alone and failed on posting_template_lines
    --    .amount_role, which holds the word 'gross' — the assertion was right
    --    that the name looked like money and wrong that the column was.
    SELECT string_agg(format('%s.%s (%s)', col.table_name, col.column_name, col.data_type), ', ')
      INTO offending
    FROM information_schema.columns col
    JOIN pg_class c ON c.relname = col.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    WHERE col.table_schema = 'public' AND c.relkind = 'r'
      AND (
        (col.data_type IN ('numeric', 'real', 'double precision', 'money')
         AND (col.column_name ~ '(amount|price|fee|balance|total|rent|deposit|payable|receivable)'))
        OR (col.column_name LIKE '%\_minor' AND col.data_type <> 'bigint')
      );
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'money column(s) that are not an integer of minor units: % '
                        '— an inexact type in a money path is the defect ADR-0007 exists to prevent', offending;
    END IF;

    -- 9. A posting template that posts to one side only would produce an entry
    --    the balance trigger rejects at commit, which is a failure discovered by
    --    a customer rather than by this file. 'reversal' is exempt by design: it
    --    is the original entry flipped, not a rule about accounts.
    SELECT string_agg(t.event_kind, ', ') INTO offending
    FROM posting_templates t
    WHERE t.event_kind <> 'reversal'
      AND NOT (EXISTS (SELECT 1 FROM posting_template_lines l
                        WHERE l.event_kind = t.event_kind AND l.version = t.version AND l.side = 'debit')
           AND EXISTS (SELECT 1 FROM posting_template_lines l
                        WHERE l.event_kind = t.event_kind AND l.version = t.version AND l.side = 'credit'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'posting template(s) with only one side: % — every entry they produce would be rejected', offending;
    END IF;

    -- 10. Every view must run as its caller. A view without security_invoker
    --     executes as its owner, so every policy on the tables underneath it is
    --     evaluated for the wrong role — it does not leak, it under-reports,
    --     which is the harder failure to notice. ADR-0006 §5.
    --
    --     Written by name for ledger_balances first, and generalised when
    --     ADR-0012 added a second view. Naming the view was the same mistake
    --     assertion 6 was written not to make: a guard that covers the objects
    --     its author had in mind decays with the next migration, and here the
    --     decay would be silent under-reporting of an ageing report.
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION 'PostgreSQL % is too old: this schema''s views need security_invoker (15+)',
            current_setting('server_version');
    END IF;
    SELECT string_agg(c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'v'
      AND NOT coalesce(c.reloptions @> ARRAY['security_invoker=true'], false);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'view(s) that are not security_invoker: % — they would be evaluated as their owner, '
                        'and every delegated or platform session would silently see the wrong numbers', offending;
    END IF;

    -- 11. No table owner may inherit dwellm8_platform.
    --
    --     is_platform_session() exempts a session from every policy in this
    --     file, and the role that owns these tables is the role the bootstrap
    --     job — and, today, the API deployment — connects as. If it inherits the
    --     platform role, tenant isolation is off for the whole application while
    --     every policy still reads correctly.
    --
    --     This is not hypothetical: from PostgreSQL 16 a CREATEROLE role is
    --     automatically granted the roles it creates, and the first version of
    --     is_platform_session() asked 'MEMBER', which that grant satisfies. See
    --     the comment on the function.
    SELECT string_agg(DISTINCT pg_get_userbyid(c.relowner), ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND c.relrowsecurity
      AND pg_has_role(pg_get_userbyid(c.relowner), 'dwellm8_platform', 'USAGE');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table owner(s) inherit dwellm8_platform: % — every session connecting as '
                        'that role is exempt from every policy in this file, and nothing looks wrong', offending;
    END IF;

    -- 12. A table whose rows may belong to no organisation must be writable only
    --     by a platform session.
    --
    --     ADR-0011 §5 introduced that exception once, for the webhook inbox, with
    --     a paragraph explaining why. ADR-0012 added three more tables of the same
    --     shape, and at that point it stopped being an exception and became a
    --     pattern — so it gets a guard rather than a paragraph.
    --
    --     The hazard is specific. A nullable or absent tenant_id means
    --     `tenant_id = current_tenant_id()` is not a filter for every row, so the
    --     ordinary ADR-0003 policy shape does not constrain writes at all: an
    --     organisation could insert a row with a NULL tenant, and nothing would
    --     refuse it. The only WITH CHECK that is sound on such a table is
    --     is_platform_session() alone, and the consequence — that ingestion is a
    --     platform-role path — is a real architectural constraint rather than an
    --     implementation detail.
    --
    --     Reference tables have no row-level security at all and are therefore not
    --     considered here; that is deliberate, and assertion 1 is what keeps a
    --     tenant-scoped table from quietly joining them.
    --
    --     organisations is excluded by name, for the same reason assertion 6 has to
    --     include units by name: its tenant column is `id`, so no column scan finds
    --     it. Measured — the first version of this assertion failed the bootstrap on
    --     organisations, which is correctly scoped by `id = current_tenant_id()` and
    --     is the one table where that is the right shape. The exclusion is a named
    --     row rather than a widened rule, so a second table that grows this shape
    --     has to argue for itself.
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
      AND c.relname <> 'organisations'
      -- Either no tenant_id column at all, or one that admits NULL.
      AND NOT EXISTS (
          SELECT 1 FROM information_schema.columns col
           WHERE col.table_schema = 'public' AND col.table_name = c.relname
             AND col.column_name = 'tenant_id' AND col.is_nullable = 'NO')
      AND NOT EXISTS (
          SELECT 1 FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
             AND p.permissive = 'PERMISSIVE'
             AND p.with_check = 'is_platform_session()');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose rows may belong to no organisation and whose writes are not '
                        'platform-only: % — on such a table tenant_id = current_tenant_id() constrains '
                        'nothing, so any organisation could write a row belonging to none', offending;
    END IF;

    -- 13. The constraints and triggers this file's ADRs actually depend on, asserted
    --     by name.
    --
    --     This exists because of the trap the migrations section is now three
    --     entries long for: a CHECK written inside CREATE TABLE IF NOT EXISTS never
    --     reaches a database that already has the table. The file replays, reports
    --     nothing, and the constraint is simply absent — present in CI, where every
    --     database is fresh, and missing in the one place it matters.
    --
    --     Measured on a database where workflow_runs_compensated_means_reversible
    --     had been dropped: replay exit 0, constraint count 0.
    --
    --     A named list is the honest shape. It cannot be derived — there is no way
    --     to ask PostgreSQL which constraints a file meant to create — so this is a
    --     list somebody maintains, and the thing that makes it worth having is that
    --     it fails the bootstrap rather than a review. Each entry is a rule an ADR
    --     argues for at length, not every constraint in the file: a list of
    --     everything would be a second copy of the schema and would rot.
    --
    --     It does not catch a replay that aborted half way — that case is already
    --     loud, because the job fails. It catches the quiet one.
    -- 14. An effective-dated table must be able to answer an as-of question with one
    --     row, and the database must be what guarantees it.
    --
    --     Column-driven, like assertion 6, so it polices a table nobody updated it
    --     for. Three clauses:
    --
    --     (a) A table with `valid_from date` is effective-dated in ADR-0008's sense
    --         and must have the generated `validity` column. Without it every query
    --         hand-writes `valid_from <= $1 AND (valid_to IS NULL OR valid_to > $1)`,
    --         which has two places to get the open-ended case wrong.
    --     (b) It must have an EXCLUDE constraint over that column. A trigger cannot
    --         do this job: it reads the table it protects, so it is racy under
    --         concurrency — which is exactly when two people revise the same flat.
    --     (c) `valid_from timestamptz` means an authorisation window rather than an
    --         effective date, which is a real distinction (delegation_grants) and a
    --         plausible mistake. Those tables are named, so a new one argues for
    --         itself instead of quietly escaping (a) and (b).
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns vf
      ON vf.table_schema = 'public' AND vf.table_name = c.relname AND vf.column_name = 'valid_from'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND vf.data_type = 'date'
      AND (NOT EXISTS (
              SELECT 1 FROM information_schema.columns v
               WHERE v.table_schema = 'public' AND v.table_name = c.relname
                 AND v.column_name = 'validity' AND v.udt_name = 'daterange')
           OR NOT EXISTS (
              SELECT 1 FROM pg_constraint x
               WHERE x.conrelid = c.oid AND x.contype = 'x'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'effective-dated table(s) without a generated validity range and an '
                        'exclusion constraint over it: % — an as-of query would hand-write the '
                        'open-ended case and two revisions of the same subject could both be live',
                        offending;
    END IF;

    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN information_schema.columns vf
      ON vf.table_schema = 'public' AND vf.table_name = c.relname AND vf.column_name = 'valid_from'
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND vf.data_type <> 'date'
      -- delegation_grants (ADR-0005) is an authorisation window: access begins at a
      -- moment and no legal document is dated by it. payout_accounts (#227) is one
      -- too: a 72-hour cool-off is measured in hours, and a calendar date would
      -- round the attacker's wait down. Anything else with a timestamptz validity
      -- is an effective date that lost its timezone argument.
      AND c.relname NOT IN ('delegation_grants', 'payout_accounts');
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose validity is a timestamp rather than a date: % — an '
                        'effective date has no time and no zone, or 1 April means two different '
                        'days five and a half hours apart. If it is an authorisation window rather '
                        'than an effective date, say so here', offending;
    END IF;

    -- 15. No column anywhere may be named after a prohibited identifier, and the KYC
    --     table may hold nothing but the fields ADR-0013 lists.
    --
    --     Two clauses, because they catch different developers.
    --
    --     (a) A name scan. Weak on its own — somebody determined calls the column
    --         `national_id` — and it catches the careless case, which is the common one:
    --         the vendor SDK returns `aadhaarNumber` and the obvious column name follows
    --         it. The list lives in internal/platform/pii so there is one copy, and the
    --         arch test reads the same one.
    --     (b) A positive allowlist on kyc_verifications. This is the strong half: *any*
    --         column not on the list fails the bootstrap, so a field cannot be added to
    --         the KYC table without arguing for it here. That is the mechanism the
    --         story's failure scenario asks for — a developer adding a field that would
    --         persist a full identifier is blocked, whatever they call it.
    SELECT string_agg(format('%s.%s', col.table_name, col.column_name), ', ') INTO offending
    FROM information_schema.columns col
    JOIN pg_class c ON c.relname = col.table_name
    JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
    WHERE col.table_schema = 'public' AND c.relkind = 'r'
      AND lower(col.column_name) ~ '(aadhaar|aadhar|adhaar|adhar|uidai)';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'column(s) named after a prohibited identifier: % — the Aadhaar number may '
                        'not be stored in any form, and a column named for it is where one ends up',
                        offending;
    END IF;

    SELECT string_agg(col.column_name, ', ') INTO offending
    FROM information_schema.columns col
    WHERE col.table_schema = 'public' AND col.table_name = 'kyc_verifications'
      AND col.column_name <> ALL (ARRAY[
          'id', 'tenant_id', 'subject_party_id', 'kind', 'masked_reference', 'result',
          'provider', 'provider_txn_id', 'consent_artefact_id', 'verified_at',
          'expires_at', 'created_at']);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'kyc_verifications has column(s) ADR-0013 does not list: % — a completed '
                        'verification holds the result, a masked reference, the provider and its '
                        'transaction, a timestamp and the consent artefact. Anything else has to be '
                        'argued for in an ADR and added to this list', offending;
    END IF;

    -- 16. Every tenant-scoped table's no-delete policy must permit the sandbox purge.
    --
    --     Column-driven, so a table added by a future ADR is covered before anybody
    --     writes a test for it — which is the whole point, because the failure is not
    --     visible from the new table. It shows up as a demo sandbox that cannot be
    --     cleaned up, months later, as storage that only grows.
    --
    --     The two platform-owned tables with no tenant_id are exempt by name: a
    --     settlement batch and a reconciliation run belong to no organisation, so they
    --     belong to no sandbox, and theirs stay at `false`.
    SELECT string_agg(DISTINCT p.tablename, ', ') INTO offending
    FROM pg_policies p
    JOIN information_schema.columns col
      ON col.table_schema = 'public' AND col.table_name = p.tablename
     AND col.column_name = 'tenant_id'
    WHERE p.schemaname = 'public'
      AND p.cmd = 'DELETE' AND p.permissive = 'RESTRICTIVE'
      AND p.qual NOT LIKE '%sandbox_purge_permitted%';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) whose no-delete policy does not permit the sandbox purge: % '
                        '— an expired demo sandbox would leave rows in them forever, and the '
                        'failure shows up as storage that only grows', offending;
    END IF;

    -- 17. Nothing but `listings` may be readable without a tenant.
    --
    --     ADR-0019 opened the first read path in this schema that does not fail closed,
    --     and this is what keeps it the only one. A PERMISSIVE read policy that mentions
    --     neither current_tenant_id() nor is_platform_session() has a branch an unscoped
    --     session can match — which is what an anonymous visitor is.
    --
    --     RESTRICTIVE policies are excluded because they narrow rather than widen: a
    --     deny-delete policy legitimately mentions neither.
    --
    --     The failure this prevents is silent and total. A new table given a convenience
    --     policy while somebody is debugging is a table the whole internet can read, and
    --     nothing about it looks wrong from the application.
    SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ') INTO offending
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.permissive = 'PERMISSIVE'
      AND p.cmd IN ('ALL', 'SELECT')
      AND p.tablename <> 'listings'
      AND coalesce(p.qual, '') NOT LIKE '%current_tenant_id()%'
      AND coalesce(p.qual, '') NOT LIKE '%is_platform_session()%';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'policy/policies readable without a tenant: % — an unscoped session is an '
                        'anonymous visitor, so this is world-readable. Only listings may be, and '
                        'only for a row its owner published', offending;
    END IF;

    -- And the other direction: the one public branch must stay scoped to a published,
    -- live row. Widening it to every listing would advertise drafts.
    IF NOT EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = 'listings' AND p.cmd = 'ALL'
           AND p.qual LIKE '%published_at IS NOT NULL%' AND p.qual LIKE '%live%') THEN
        RAISE EXCEPTION 'the public listing policy is not scoped to a published, live row — a '
                        'draft listing would be advertised before its owner published it';
    END IF;

    -- A public read path with a public *write* path is a different thing entirely.
    --
    -- PERMISSIVE only: a restrictive policy is an AND that narrows — ADR-0029's
    -- resident deny is one — and judging it by this rule would report the
    -- narrowing as a hole.
    IF EXISTS (
        SELECT 1 FROM pg_policies p
         WHERE p.schemaname = 'public' AND p.tablename = 'listings' AND p.cmd = 'ALL'
           AND p.permissive = 'PERMISSIVE'
           AND coalesce(p.with_check, '') NOT LIKE '%current_tenant_id()%') THEN
        RAISE EXCEPTION 'the listings policy admits a write without a tenant — the hole is meant to '
                        'be read-only by construction';
    END IF;

    -- 18. Reference data has no runtime writer, and no unverified rule blocks.
    --
    --     The chart of accounts, the posting templates and the statutory rules are
    --     the rule rather than the data: this file writes them, and a request reads
    --     them. The privilege is revoked at the foot of each section, which is one
    --     line that a later `GRANT ... ON ALL TABLES` would silently undo — and it
    --     does exist, three sections up. So the state is asserted rather than the
    --     statement trusted.
    --
    --     What it prevents is specific and is not a leak: an organisation that can
    --     INSERT into statutory_rules can write itself a zero TDS rate with a
    --     valid_from of last April, and every deduction after it resolves correctly
    --     against a rule nobody authorised.
    SELECT string_agg(format('%s:%s', t, priv), ', ') INTO offending
    FROM unnest(ARRAY['ledger_accounts', 'posting_templates', 'posting_template_lines',
                      'statutory_rules', 'statutory_rule_slabs']) AS t
    CROSS JOIN unnest(ARRAY['INSERT', 'UPDATE', 'DELETE']) AS priv
    WHERE has_table_privilege('dwellm8_app', t, priv);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'reference data is writable at runtime: % — a request that can write a rate '
                        'is a request that can decide its own tax, and the rule would have no review '
                        'and no citation', offending;
    END IF;

    --     And the rule india-property-compliance.md §1.1 states, asserted over the
    --     rows rather than over the constraint: a CHECK written inside CREATE TABLE
    --     IF NOT EXISTS never reaches a database that already has the table, so on a
    --     replayed database this clause is the only thing between an unverified row
    --     and a lease the product refuses to create for a reason nobody can source.
    SELECT string_agg(format('%s/%s/%s', rule_type, jurisdiction, rule_key), ', ') INTO offending
    FROM statutory_rules
    WHERE retired_at IS NULL AND enforcement = 'block' AND verification_status <> 'verified';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'unverified statutory rule(s) set to block: % — a cap enforced from a blog '
                        'post is worse than no cap, because it is wrong with authority', offending;
    END IF;

    -- 19. Every row-level-secured table must have an opinion about a resident
    --     session, and the default opinion must be no.
    --
    --     ADR-0029 narrows a request a second time, from "this organisation" to
    --     "this renter", and the failure it prevents is not a cross-tenant leak —
    --     it is a renter reading the other forty tenants of the same landlord,
    --     which looks exactly like the product working.
    --
    --     A table is compliant when some policy on it mentions the resident
    --     scope: either one of the allowlisted narrowing policies above, or the
    --     generated deny. This is the guard on the generator — if the loop is
    --     ever removed, reordered above a table's creation, or quietly narrowed
    --     to a list, the bootstrap fails here rather than opening a table.
    SELECT string_agg(DISTINCT c.relname, ', ') INTO offending
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
      AND NOT EXISTS (
          SELECT 1 FROM pg_policies p
           WHERE p.schemaname = 'public' AND p.tablename = c.relname
             AND p.permissive = 'RESTRICTIVE'
             AND (coalesce(p.qual, '') LIKE '%is_resident_session()%'
               OR coalesce(p.qual, '') LIKE '%resident_holds_lease(%'));
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'table(s) with no resident-scope policy: % — a renter session would read '
                        'every row their landlord can, which is every other tenant of that landlord. '
                        'Either narrow it in the ADR-0029 section or let the deny loop close it', offending;
    END IF;

    -- And the other direction: a resident policy must be RESTRICTIVE. A
    -- PERMISSIVE one would be an OR against the organisation policy, so instead
    -- of narrowing a renter it would widen everybody else to the renter's rows.
    SELECT string_agg(format('%s.%s', p.tablename, p.policyname), ', ') INTO offending
    FROM pg_policies p
    WHERE p.schemaname = 'public'
      AND p.policyname LIKE '%\_resident\_%'
      AND p.permissive <> 'RESTRICTIVE';
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'resident policy/policies that are PERMISSIVE: % — a permissive policy is an '
                        'OR, so this would widen every other session to the renter''s rows rather '
                        'than narrowing the renter', offending;
    END IF;

    SELECT string_agg(want, ', ') INTO offending
    FROM unnest(ARRAY[
        -- ADR-0003: the composite key every tenant-scoped foreign key points at.
        -- Absent, the tables that reference it do not create at all, which is
        -- what happened to lease_tax_facts, tds_obligations and mandates.
        'leases_tenant_id_unique',
        -- ADR-0002 §1: an event names its tenant, its subject and its author.
        'outbox_actor_kind',
        'outbox_user_actor_has_an_id',
        'outbox_subject_present',
        -- ADR-0006 §3: the ledger balances, and an entry has lines.
        'ledger_postings_balance',
        'journal_entries_have_postings',
        -- ADR-0007: money is representable, and the currency is one.
        'journal_entries_kind',
        'journal_entries_reversal_reason_check',
        -- ADR-0011 §3: a payment walks forward, and a captured one posted.
        'payments_forward_only',
        'payments_captured_has_entry',
        -- ADR-0012 §2 and §5: a settlement file adds up, and an unreconciled line
        -- posts nothing.
        'settlement_batches_adds_up',
        'settlement_lines_only_matched_lines_post',
        'reconciliation_runs_counters',
        'reconciliation_runs_reconciled_saw_the_file',
        -- ADR-0015 §4: a run past the point of no return was not compensated, and
        -- the point of no return is monotonic.
        'workflow_runs_compensated_means_reversible',
        'workflow_runs_forward',
        -- ADR-0008 §4: two owners of the same flat cannot both be current.
        'property_ownership_no_overlap_unit',
        'property_ownership_no_overlap_property',
        'property_ownership_no_edit',
        -- ADR-0010: one flat cannot be let twice over the same days, a terminated
        -- tenancy says what happened to the money, and the agreement is not editable.
        'leases_no_double_let',
        'rent_schedule_no_overlap',
        'leases_termination_shape',
        'leases_legal_transitions',
        'leases_retrospective_end',
        -- ADR-0010 §7: an entry that bills a tenancy names it, so the trigger above is
        -- enforcing rather than inert.
        'journal_entries_lease_charge_shape',
        -- ADR-0013: a full identifier does not fit in the only column that could hold one.
        'kyc_verifications_reference_is_a_mask',
        'kyc_access_log_support_needs_a_grant',
        -- ADR-0019: browsing is anonymous and making contact is not, and neither party's
        -- number is reachable before both have engaged.
        'enquiries_verification_point',
        'contact_bridges_mutual',
        -- ADR-0021 §3: no real effect originates in a demo, which is what makes a demo
        -- purgeable at all.
        'payments_sandbox_provider',
        'workflow_runs_sandbox_ban',
        'demo_sessions_sandbox_only',
        'demo_sessions_cap',
        -- ADR-0023: one statutory rule in force at a time, the value shape matches the
        -- kind, an unverified rule cannot block, and a scale has no hole in it.
        'statutory_rules_no_overlap',
        'statutory_rules_value_shape',
        'statutory_rules_unverified_cannot_block',
        'statutory_rules_slabs_shape',
        -- #227: a full account number is unstorable, so the impersonated-owner
        -- attack cannot exfiltrate what was never kept.
        'payout_accounts_account_is_a_mask'
    ]) AS want
    WHERE NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = want)
      AND NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = want AND NOT tgisinternal);
    IF offending IS NOT NULL THEN
        RAISE EXCEPTION 'the rule(s) this schema is built on are missing: % — a CHECK inside '
                        'CREATE TABLE IF NOT EXISTS never reaches a database that already has the '
                        'table, so this is what a green replay with an absent constraint looks like',
                        offending;
    END IF;
END
$$;
