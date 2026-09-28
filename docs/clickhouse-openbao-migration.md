# ClickHouse OpenBao migration

Completed in PR #1251; estate work remains in
[issue #1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

Three `prod-clickhouse-*` originals (OTel, observer and SRE writer passwords)
were copied without overwrite to `clickhouse/app/clickhouse-*` and deleted on
2026-09-28. Observability reads all three paths; tesserix reads only the shared
OTel password. Langfuse uses the explicit ClickHouse reader for that password.
Namespace-bound policies allow exact reads; temporary staging access is removed.

All three consumers refreshed after deletion, matching generations and unchanged
bytes. All three users authenticate on both data replicas, and wrong-password
controls are rejected. Langfuse v2 observations and obs-api health/ClickHouse
readiness return 200. Both data replicas, three Keeper nodes and consumer
workloads remain Ready with unchanged images and replicas. Existing database
users and permissions were not changed.

Recovery archive:
`gs://tesseract-prod-backups-in/openbao/clickhouse-migration/20260928T124722Z/gcp-sources.json.gz.kms`.
Final backup `20260928T130314Z-21609bc2f75d` includes the permanent reader
policies and passed isolated restore in 21.23 seconds. Exactly three snapshots
remain and pruning was verified. Restricted acceptance evidence is in
`/tmp/remaining-openbao-evidence/clickhouse/`.

Validation: 645 tests and 48 subtests passed with the four previously documented
unrelated exclusions; all PR CI checks passed. The post-cohort GCP inventory
contains 357 secrets. GrowthBook remains deferred.
