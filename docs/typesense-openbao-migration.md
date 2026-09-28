# Typesense OpenBao migration

Track [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

The production `prod-typesense-api-key` source maps to
`typesense/app/typesense-api-key`, field `value`. The namespace-bound
`read-typesense-production` reader permits only this exact path and no writes.
ESO preserves `typesense/typesense-secrets` and its `api-key` field, refreshing
every five minutes. Images, replicas and Argo overrides remain unchanged.

The baseline authenticated collections request succeeds and an invalid key is
rejected. Archive metadata, IAM and enabled versions with KMS before staging a
pinned version using temporary exact-path create/read access. Revoke and remove
that access after byte verification. Verify fresh ESO generation, unchanged
payload, application health and authenticated API checks. Run a verified backup
and isolated restore after the permanent reader is installed.

Terraform storage owns the GCP record. Keep the original until all cutover and
recovery gates pass, then retire its declaration using a separate, narrowly
targeted Atlantis plan. Never apply unrelated storage drift. After deletion,
verify a new successful ESO refresh and repeat the API checks. Development/test
sources are separate inventories and are not implicitly migrated by this change.

Provision future production keys directly to this OpenBao path using temporary
scoped access. Any rotation must coordinate the Typesense process and all callers;
this migration copies the current value and performs no rotation.

Staging completed on 2026-09-28 with byte equality and all temporary migration
grants removed. Encrypted archive:
`gs://tesseract-prod-backups-in/openbao/typesense-migration/20260928T133147Z/gcp-sources.json.gz.kms`.
Consumer rollout, final recovery verification and Terraform retirement are complete.

## Completion

Typesense cohort complete. PR #1253 switched its production reader to OpenBao; #1254 retired the Terraform-owned original using a reviewed Atlantis plan containing exactly one delete and no other changes. GCP and Terraform state both confirm the source is absent.

The namespace-bound reader passes byte equality, exact read-only permissions and wrong-namespace denial. Authenticated collections requests succeed, invalid keys are rejected, and health passes. ESO refreshed successfully at 13:59:05Z after deletion, preserving the value, workload images/replicas and Argo overrides. Temporary migration grants were removed.

Recovery archive: `gs://tesseract-prod-backups-in/openbao/typesense-migration/20260928T133147Z/gcp-sources.json.gz.kms`. Backup `20260928T134459Z-643ab0fa347a` restored in 20.035 seconds, with exactly three verified backups retained and pruning confirmed.

Fresh GCP inventory: 350 secrets. GrowthBook remains deferred. Shared Temporal is next; its local changes are in draft #1255 with all six database credentials and three Temporal service health checks passing. Keep this issue open; the estate migration is not complete.
