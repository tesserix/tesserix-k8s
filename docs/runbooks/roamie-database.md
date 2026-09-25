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
