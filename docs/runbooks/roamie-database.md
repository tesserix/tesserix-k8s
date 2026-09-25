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
5. Wire the API persistence implementation with TLS verify-full and the CNPG CA,
   account-scoped queries and versioned migrations. The current API and trip
   implementation still use local device storage; provisioning is not persistence.

Backups use a dedicated private GCS bucket, Workload Identity, daily base backups,
continuous WAL and seven-day retention. Storage resources prevent destruction.
No live resources have been provisioned by preparing this worktree.
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
