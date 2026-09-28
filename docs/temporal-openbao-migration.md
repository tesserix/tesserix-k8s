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
Consumer rollout, final isolated recovery verification and deletion are pending.
