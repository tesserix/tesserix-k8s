# Helivanta independent tenant identity migration

Prepared, not approved for live application. Requested by the user on 2026-11-11.

Remove `customer_signups_new_owner_email_reservation`, which currently makes an
email globally unique across public Helivanta tenant signups. Retain the immutable
signup intent, tenant/user unique IDs, receipt, native-proof and legacy-binding
triggers. Add a bounded partial retry index for unbound legacy `existing_account`
intents. Add a non-unique `(owner_email_hash,tenant_id)` recipient-mail lookup
index concurrently, supporting a cross-intent 10/hour and30/rolling24h recipient delivery
budget, retaining each workspace's3/hour and10/day limits without treating email as shared identity. No user, tenant, business row
or secret is deleted or rewritten.

Rollout order: explicit unique native usernames (operators PR31), this schema,
onboarding intake/delivery, then Helivanta scoped sign-in/UI. Existing accepted
legacy bindings retain their history and are not silently migrated. Recovery of
an unbound active receipt creates only its deterministic fresh native owner.

Before approved application, capture the existing index DDL, schema hash and
counts of conflicting email hashes (no emails, profiles or credential values)
in the protected task evidence directory. Record cloud account/project/context
and target global/onboarding_db. Deploy through the owning Argo schema bootstrap;
verify the expected schema, index validity and normal workload health. A failed
concurrent index build can leave an invalid index; do not activate onboarding
until it is repaired through an approved forward operation. The schema file is
executed in autocommit mode, never `--single-transaction`.

Removing this restriction is compatible with the old application. After new
same-email rows are accepted, rollback must retain the expanded schema: restoring
the unique index can fail and requires reconciliation rather than data deletion.
Real PostgreSQL reservation/replay tests in onboarding-service must pass against
this exact schema before onboarding is activated. Existing schema/chart checks
also retain owner guards and receipt bounds.
