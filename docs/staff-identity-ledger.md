# Staff identity creation ledger

Status: draft schema expansion for
[onboarding-service PR #22](https://github.com/tesserix/onboarding-service/pull/22).
Not approved, merged or applied to an application/production database. The
provider protocol and ledger do not by themselves complete Staff provisioning,
employment, membership or Access/RBAC.

## Canonical schema and ownership

Canonical input:
`charts/apps/db-schema-bootstrap/schemas/global/global/onboarding_db.sql`.
Chart version: `0.3.60`. Existing onboarding databases receive the existing
idempotent schema replay; no separate application-owned table copy is created.
SQL SHA-256:
`8e2f89da8e6f4771a7d0af3ca075094f2ec622ab6f0ce38475f9b7660018b382`.
All new objects belong to the existing onboarding identity owner and existing
`onboarding_db`; no new cloud service, role, credential or network path is added.

The additive expansion contains four append-only tables:

- `staff_identity_commands`: UUIDv7 command, canonical organisation/product,
  current machine and attributable human, frozen provider organisation/project,
  generated provider account ID and correlation nonce, private contact/name and
  required reason. A repeated command cannot replace its original generated ID.
- `staff_identity_dispatches`: one permanent claim per command, committed with
  the dispatch audit before any provider creation. A timeout or later source
  deletion cannot clear this claim or permit a second creation attempt.
- `staff_identity_creations`: one retained creation outcome per dispatch, bound
  by composite foreign key to its original provider account ID. The provider's
  RFC3339 UTC creation timestamp is retained as bounded canonical source text to
  preserve all nine fractional digits; PostgreSQL timestamps round to six.
  Local recording times remain `timestamptz`.
- `staff_identity_contact_claims`: one permanent root per source organisation
  and owner-normalized contact, bound by composite FK to the exact original
  command/source org/email. The owner uses the pinned provider's Go lowercase
  normalization without dot/plus rewriting. Preparation/root/audit are atomic;
  exact retry retains the original root, and competing command IDs conflict.
  Historical commands receive no silent backfill. Operator replacement must
  preserve explicit root/command/outcome lineage instead of freeing the root.

The application role receives SELECT/INSERT only. UPDATE, DELETE and TRUNCATE
are explicitly revoked for all four tables. Tenant/product references use
RESTRICT: offboarding or source deletion must retain the creation/dispatch facts.
The central owner service must still authorize every product/tenant command and
receipt read. These grants are not browser access or a new tenant authorization
model, and no role or permission is assigned by a creation receipt.

Root SQL is persisted at `2214e7a7d6730570447bbe1f0ad8e341c5026c3b` and pinned
by owner CI. Its Helm/repository/PR validation gates passed. Owner creation PUT
at `f7bc168` passed full local race tests, vet/build/lint and an actual isolated
provider test: role-free creation, immutable replay, unverified observation and
zero actual source memberships/user grants. That provider test uses fixture
registry proof; it does not prove normal-role UI/recipient acceptance.

## Attributable recovery request/decision substrate

Chart 0.3.60 adds two append-only ledgers, without enabling a recovery endpoint:
`staff_identity_recovery_requests` binds a UUIDv7 request to an actual dispatch,
the original initiating actor and exact original provider-user ID. It retains
requesting operator, action (`close_unresolved` or `replace`), mandatory reason,
opaque evidence reference and, for replacement, its initiating actor.
`staff_identity_recovery_decisions` retains one decision per request and binds all
of those authority facts by composite FK. None of its binding fields is nullable;
a NULL must not bypass PostgreSQL's composite-FK checks.

The database rejects review by the requester, original initiator, original source
account or proposed replacement initiator. Rejection is final for that request;
new requests retain corrected evidence. Only one approved replacement can win for
an original command. Closing an unresolved investigation preserves the unknown
outcome and allows a later reviewed replacement; it does not claim the original
creation was unsent or clear the original dispatch/contact root. The approved
replacement row alone grants no dispatch or membership authority. Atomic successor
preparation/root lineage, audited owner commands, current operator/source scope,
consumer/operator UI and normal-role acceptance remain unimplemented gates.

Both tables permit the application role only SELECT/INSERT; UPDATE, DELETE and
TRUNCATE are denied. FKs retain original commands, dispatches and reviewed requests.
Actual disposable-PostgreSQL tests cover self-review, forged actor/user/maker and
request binding, NULL bypass, required evidence, undispatched commands, final
rejection, closure then replacement, twelve competing replacement approvals with
one winner and application-role mutation denial. No production migration ran.

## Compatibility and recovery

The history expansion adds a partial exact-command audit index and an ephemeral
`staff_identity_history_cursors` cache, separate from the four immutable ledgers.
Only token hashes, scope hashes, internal sequence positions and expiry are
retained. Tokens carry no authorization, no global sequence is returned, and
every continuation requires current principal/source/command checks. History
pages and new cursors require an atomic mandatory disclosure audit.

The cache permits SELECT/INSERT and database-enforced deletion of expired rows.
PostgreSQL row locking requires a narrow `UPDATE(token_hash)` privilege; forced
RLS with `WITH CHECK(false)` rejects every actual update, and TRUNCATE is denied.
Real application-role tests first reproduced permission-denied continuation,
then passed with lock-only policy, denied active deletion/rewrites and permitted
expired cleanup. Collection is capped at 1,000 rows and skips locked rows.
Cache expiry/cascade cannot delete commands, roots, dispatches, receipts or audit.

The full SQL and policies were replayed twice against the disposable fixture.
On a rolled-back 100,001-row synthetic audit transaction, the actual bounded
history query used `audit_events_staff_command_idx` with 0.046 ms execution.
That is local query-plan evidence, not an API SLO. The private plan is retained
with QA evidence. No live database or provider permission was changed.

The old application does not query these tables, so applying the expansion does
not activate a new endpoint or change existing member invitations. Deploy the
owner's verified ledger/service first, then its authorized consumer. Do not use
the existing ORG_OWNER member invitation for role-free Staff accounts.

Rollback retains these tables and their facts. There is intentionally no
destructive down migration: deleting a claim can cause duplicate creation or
recreation of a deleted global identity. Any later retention/privacy change
requires its own owner policy and reviewed forward migration. It must preserve
the minimal evidence needed to avoid unsafe redispatch.

Successful provider creation, contact delivery, recipient contact verification,
current account eligibility, Helivanta membership and hospital employment/access
are separate facts. Source absence after uncertain dispatch is not proof that
the request never ran. The owner must supply explicit reconciliation and
attributable operator recovery before provisioning can be accepted.

## Verification and rollout evidence

The full canonical schema was applied repeatedly to a fresh local PostgreSQL 16
container dedicated to this work. Owner Go regressions first failed for missing
preparation/dispatch/receipt methods and then for absent canonical relations.
Focused real-database race tests pass for exact/conflicting preparation, eight
concurrent dispatch claimants with one winner/audit, immutable creation receipt,
nanosecond-preserving replay, changed actor/contact/provider/nonce, foreign
tenant/machine, withdrawn entitlement, changed source mapping, application-role
rewrite denial and audit-failure rollback. See the owner PR for full package,
build and current CI results; this does not claim API/UI or production acceptance.

The owner full Go race suite passed against that disposable database (52.7%
overall coverage); the final affected store/provider suites passed at 56.2% and
81.1%. The additional lock-wait test observes `pg_blocking_pids`, withdraws the
entitlement before releasing its blocker, and verifies no dispatch claim.
Preparation and receipt audit-failure tests also prove atomic rollback; a
completed provider outcome can be retained after entitlement withdrawal without
restoring dispatch authority. Helm lint and the four existing onboarding schema
tests passed, the latter through an isolated uv environment because system
Python had no pytest.

A 100,000-command synthetic transaction exercised `EXPLAIN (ANALYZE, BUFFERS)`
for the exact command/tenant/product lookup. PostgreSQL selected an index scan
on `staff_identity_commands_id_provider_user_id_key`, returned one row with four
shared-buffer hits, and recorded 0.066 ms execution in this fixture. This is a
local query-plan observation, not an API latency SLO. All planning rows were
rolled back.

No production database, registry, provider account or cloud resource was changed.
Only disposable owner/provider fixtures were changed; their private synthetic
account evidence is retained separately. Before merging this schema into GitOps, capture its exact source
and SQL digest, verify owner/consumer compatibility and obtain approval for this
named rollout/migration. Retain the source and application receipts for future
environment replay. Do not infer rollout authority from the earlier Helivanta
migration approvals.
