# Shared Temporal credential migration

Track [issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

The shared `prod-temporal-postgresql-password` maps to
`temporal/app/temporal-postgresql-password`, field `value`. Four namespace-bound
readers expose only that path to ESO in `homechef`, `scrapper`, `infra` and
`temporal-system`. Existing Kubernetes password keys and templates are preserved.
Dwellm8 retains its independent product credential and reader.

The consumer manifests cover both Temporal single-service instances, the shared
Temporal platform database credentials, Infra Postgres, and the dormant HomeChef
Temporal database chart so a future rebuild does not reintroduce GCP access.
The running workloads keep their image, replica and Argo overrides.

Before rollout, archive metadata/IAM/all enabled versions with KMS, copy the
pinned source without overwriting any different value, verify equality and remove
temporary staging access. After scoped GitOps reconciliation, verify every
ExternalSecret generation and unchanged payload; all namespace readers must be
read-only and deny other paths/namespaces. Verify authenticated queries and
wrong-password controls through service DNS on both database backends. Localhost
connections are unsuitable authentication controls because Scrapper allows local
trust. Verify Temporal health and all existing replicas.

Run a verified backup and isolated restore after installing the permanent
readers. Only then delete the approved original and verify another fresh ESO
refresh and all functional checks. Storage and app-secrets Terraform states have
no owner for this source. No database data, password or service deployment is
changed by the migration.

Staging completed on 2026-09-28 with byte equality and temporary token, role,
policy and service account removed. Recovery archive:
`gs://tesseract-prod-backups-in/openbao/temporal-migration/20260928T140002Z/gcp-sources.json.gz.kms`.
All six database connections pass real credential checks and reject wrong
passwords. HomeChef, Scrapper and the shared Temporal platform report SERVING.
Consumer rollout, final isolated recovery verification and deletion are complete.

## Completion

Shared Temporal cohort complete. PR #1255 migrated the shared password to `temporal/app/temporal-postgresql-password` with exact read-only, namespace-bound readers for HomeChef, Scrapper, Infra Postgres and the shared Temporal platform. All four consumers preserve their Kubernetes keys and values. Dwellm8’s separate credential remains unchanged.

The original `prod-temporal-postgresql-password` was deleted and confirmed absent after the acceptance gates passed. All four ESO consumers refreshed after deletion at 14:23:35–42Z with matching generations and unchanged values. All three Temporal services report SERVING, and all twelve database authentication checks pass (real credentials accepted, wrong passwords rejected). Images, replicas and Argo source settings are unchanged.

Archive: `gs://tesseract-prod-backups-in/openbao/temporal-migration/20260928T140002Z/gcp-sources.json.gz.kms`. Final backup `20260928T141609Z-bc62ebba262b` passed isolated restore in 19.911 seconds, with exactly three verified snapshots retained and pruning confirmed. Temporary writer access is removed.

Fresh GCP inventory: 349 secrets. Shared Cloudflare remains deliberately retained in GCP with its verified OpenBao copy; GrowthBook remains deferred. Global Postgres is next, with read-only baseline checks passing. Keep this issue open; the estate migration is not complete.
