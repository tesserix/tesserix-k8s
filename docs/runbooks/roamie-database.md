# Roamie database rollout

Dedicated `roamie-postgres` in namespace `roamie`, two PostgreSQL instances on
separate nodes, synchronous replication, retained data/WAL volumes and PDB.
Two instances prioritise durable acknowledged writes: losing the only standby
can block writes until a synchronous standby returns. This is not three-node HA.

CNPG is already installed (observed 1.30.0); do not install a second operator.
The product database and non-superuser migration owner are both `roamie`. Runtime connections use the non-owner `roamie_app` role from `roamie-postgres-runtime` / `prod-roamie-postgresql-runtime-password`; application migrations grant only schema usage and table DML.
RW endpoint: `roamie-postgres-rw.roamie.svc.cluster.local:5432`.
Credentials: ExternalSecret `roamie-postgres-app`; the password comes from
`prod-roamie-postgresql-password`. Never copy it into values or logs.

Apply order, after scoped production approval:
1. Review Terraform plans in stacks 03-storage, 06-workload-identity and
   07-app-secrets with the production variables. Reject unrelated changes.
2. Apply the dedicated backup bucket, dedicated GSA/WI binding, and generated
   Secret Manager password. Terraform state contains the sensitive password;
   preserve existing restricted remote state access. Do not rotate by tainting.
3. Merge/sync the Argo application and wait for ExternalSecret Ready, then two
   CNPG ready instances on distinct nodes with streaming replication.
4. Verify a successful scheduled/manual backup and WAL archiving; perform a
   restore to an isolated test cluster before declaring recovery verified.
5. Wire API persistence with TLS verify-full and the CNPG CA, account-scoped
   queries and versioned migrations. Shared mobile trip synchronization is a
   separate release; provisioning alone does not synchronize device data.

Backups use a dedicated private GCS bucket, Workload Identity, daily base backups,
continuous WAL and seven-day retention. Storage resources prevent destruction.
The two-instance cluster and API database connection were verified during the
September 2026 rollout; inspect current Argo and CNPG status before maintenance.
Do not prune the CNPG application or delete PVCs as a rollback procedure.

Validation: Helm lint/template, Kubernetes app kustomization, live CNPG CRD JSON
schema, and Terraform validate in all three modified stacks.

## API integration and release recovery

The API uses `roamie-postgres-runtime` and mounts only the public CNPG CA from
`roamie-postgres-ca`. The `roamie-api-migrate` Argo Sync hook runs at wave -1 with
owner credentials, before the Deployment. Selective sync is disabled because it
can skip hooks. Migrations are additive, transactional and replay-safe; a failed
job blocks rollout without replacing the healthy API pods. Inspect its logs and
retry the GitOps sync after correcting the cause; do not delete data or migration
history. The hook has a five-minute deadline and one retry.

Readiness `/readyz` checks PostgreSQL; `/healthz` remains independent. Verify
`pg_stat_ssl` for `roamie_app` after rollout, confirm runtime has no superuser,
createdb or createrole privileges, and confirm both instances are healthy.

The September 2026 rollout uses a digest pin in `image.digest` because GitHub's
hosted runners refused jobs due to account billing. GCP Cloud Build builds the
exact reviewed source into the existing `global` Artifact Registry repository.
The pin takes precedence over Kargo's `image.tag`; subsequent tag promotions do
not replace the pinned image. To return to normal delivery, first restore GitHub
billing, publish a verified database-capable image through the normal workflow,
then in one reviewed GitOps change restore the `ghcr-remote` repository and clear
`image.digest`. Confirm the Kargo tag identifies that verified image before sync.
Do not clear the pin while Kargo still identifies the pre-database release.

A one-time GitOps `Backup` resource verifies the repaired backup path; daily
scheduled backups continue separately. An isolated restore drill is still
required before closing Roamie #85. No production failover or restore is performed
implicitly by the rollout.

## Customer authentication and audit migration

The authenticated API requires `AUTH_ENABLED=true` and the Roamie native-client
IDs from the reconciled identity-operator resources. The issuer is
`https://auth.tesserix.app`, project `392328861469115174`, TESSERIX organization
`386377229942128837`. Google and Apple use the existing organization providers;
Facebook is omitted until its setup and callback have been verified. No provider
credentials are stored in Helm values. Public endpoints are `/healthz`, `/readyz`
and `/v1/auth/config`; every business route requires a verified customer token.

The same wave -1 owner hook applies `202609260001`, creating accounts,
case-insensitive unique emails, eight travel-style reference rows and audit
triggers. It never loads the separate synthetic development fixture. Verify
three successful rows in `_sqlx_migrations`, eight rows in `travel_styles`, and
no runtime INSERT/UPDATE/DELETE/TRUNCATE privilege on `audit_events`. Mutations
capture column names without copying profile values into audit payloads.

After sync, confirm two healthy API replicas, runtime TLS sessions, health and
readiness HTTP 200, and missing/forged credentials HTTP 401 on protected routes.
An actual successful social callback remains a separate device verification;
an HTTP 401 smoke test does not prove that journey. Keep the local debug bypass
on a loopback/local database only, and point unsigned development builds at that
local API. The public production backend does not accept the development bypass.

Retain the schema on application rollback. Do not restore the previous public
unauthenticated API as an ordinary rollback; use a corrected authenticated image
or a separately approved maintenance response. Account/audit migration is
forward-only, without a destructive down migration. Per-customer rate limits,
retention policy and a tested restore remain explicit release follow-ups.
