# Global Postgres OpenBao migration

Track [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

The reviewed `prod-global-postgresql-password` maps to
`global-postgres/app/global-postgres-password`, field `value`. Exact read-only
roles are bound separately to `global` and `db-backup-and-restore`. Preserve the
three existing Kubernetes secrets and their `password` / `postgresql-password`
keys, including the bootstrap username and existing password trimming.

Consumers are the Global Postgres bootstrap ExternalSecret, the global schema
bootstrap chart's compatibility secret, and the backup namespace's compatibility
secret. Schema provisioning itself remains unchanged. No inactive backup job is
started, no schema or database is altered, and images/replicas stay unchanged.
The legacy backup credential is tested through a read-only schema dump; eleven
Global-owned databases pass real-password queries and reject wrong passwords.

Archive pinned versions, metadata and IAM with KMS, copy without overwriting a
different OpenBao value, verify equality and remove temporary access. Reconcile
only the reader resources and three ExternalSecrets through their owning Argo
Applications. Verify each fresh generation and whole-secret hash, database
queries, backup credential and workload readiness. Run a verified OpenBao
snapshot and isolated restore after installing permanent readers.

Terraform storage owns the original record. After all live and recovery gates
pass, retire it through a separate single-resource Atlantis plan. Never apply
unrelated storage drift. Verify GCP/state absence, another fresh ESO refresh and
functional checks after deletion. Keep the Cloudflare retention exception intact.

Staging completed with pinned-version byte equality and all temporary write
access removed. The archived value matches all three current consumers, with the
existing bootstrap trim preserved. Archive:
`gs://tesseract-prod-backups-in/openbao/global-postgres-migration/20260928T142628Z/gcp-sources.json.gz.kms`.
Consumer rollout, final recovery verification and Terraform retirement are pending.
