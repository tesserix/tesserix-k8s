# OpenBao verified recovery

Status: production backup/restore acceptance passed on 2026-09-27. Console
integration is being prepared. Infrastructure: #1181; recovery jobs: #1182;
key metadata permission required by auto-unseal: #1183.

Four successful backups restored in 19.851, 19.884, 16.056 and 17.363 seconds.
The bucket contained exactly three snapshot objects and three matching catalog
entries after the fourth success. An independent restore under the read-only
restore-test identity passed in 18.595 seconds. A truncated local copy was rejected
without changing the catalog. Both Fe3dr/HomeChef and Roamie readiness endpoints
returned HTTP 200 afterward. The production mount inventory contained only KV,
cubbyhole, identity and system engines.

CI for #1182 passed 498 tests and 48 subtests; four existing quarantined tests
remained excluded by the repository workflow. Runner tests, strict mypy, Ruff,
and Helm lint also passed. Private rollout manifests and job evidence are stored
under `/tmp/openbao-recovery-pre-rollout` on the operator workstation. The first
failed drill exposed missing `cloudkms.cryptoKeys.get`; #1183 added metadata read
permission scoped to the original unseal key for both recovery identities.

## Scope and recovery objectives

The verified backup CronJob runs at **03:00 and 15:00 UTC**, giving a nominal
12-hour recovery point objective. Each run uploads a whole Raft snapshot to
`tesseracthub-480811-openbao-recovery-prod`, downloads the exact generation,
checks SHA-256 and bucket CMEK metadata, and restores it into an isolated,
loopback-only OpenBao process. A fresh Kubernetes login reads the captured
verification marker version. No application secret values enter logs or reports.
The job must finish within 15 minutes; this is a test deadline, not a measured
production recovery-time guarantee.

Only three verified snapshots appear in `catalog.json`. Superseded generations
are recorded as pending deletions in the same conditional catalog write. Failed
deletion is retried on the next successful publication. Uncatalogued snapshots
older than the oldest retained recovery point are also removed. A newer interrupted
upload is preserved until it falls below that cutoff. Failed verification never
prunes the previous recovery points. GCS lifecycle age rules cannot enforce a
count of three; the job owns count-based retention.

The previous shared bucket keeps its existing lifecycle, including its 30-day
retention lock. Historical snapshots and migration archives there are not part of
the new three-snapshot catalog and must not be deleted as part of this rollout.

## Security and dependencies

Production credentials and all application secrets are assets within the encrypted
snapshot. A compromised backup workload or cloud administrator is the primary
threat: the recovery identities can read the snapshot and use the original unseal
key. Their permissions are confined to the dedicated bucket and that key. The
backup identity can delete superseded objects; the restore-test identity cannot
write GCS objects. Neither identity has production Raft restore permissions.

Recovering requires **both** the backup CMEK and the original
`openbao-unseal-key`, including the key versions used by retained snapshots.
Terraform `prevent_destroy` does not protect against manual key destruction.
Do not retire these versions while snapshots depend on them.

Restore tests have no Service, persistent volume, production join address, or
external listener. Their Kubernetes identities can perform TokenReview so that
fresh login works after restoring an old snapshot. Verify the production mount
inventory before enabling this design for dynamic secret engines: restored lease
reconciliation must not revoke or rotate credentials in external production systems.
The current acceptance must explicitly confirm that this is safe.

## Rollout gate

1. Review a Terraform plan restricted to the recovery resources. The initial
   full `03-storage` plan included unrelated changes and **11 deletions**; do not
   apply it. Review the replacement plan, not just a green Atlantis status.
2. Approval was granted for applying the dedicated bucket, backup key, recovery
   identities and bindings, and deploying the recovery Helm resources.
3. Capture the existing backup CronJob manifest privately before changing its
   schedule. Keep the old backup running throughout verification.
4. Merge infrastructure and chart changes through their owning GitOps paths.
   `recovery.enabled=true` is the current deployed setting.
5. Verify production bootstrap applied `recovery-backup` and `snapshot-verify`
   roles, and confirm the OpenBao mount inventory is safe for isolated restoration.
6. Run four backups sequentially, then an independent restore test of a retained
   snapshot. Confirm exactly three snapshot objects and three catalog entries;
   check every object's CMEK and generation, and record measured restore durations.
7. Run failure-path acceptance: corrupted download must fail, existing recovery
   points must remain usable, and a failed delete must succeed on retry.
8. Confirm all three production OpenBao nodes and Fe3dr/Roamie consumers remain
   healthy. Then retire the legacy schedule in Git with specific rollout approval.

The local runner tests cover ordering/idempotency, interrupted pruning, catalog
conflicts, generation-safe cleanup, corrupt archive rejection, network isolation
configuration, scheduling and missing-success alerts. They are **not** evidence
of a successful live KMS unseal or whole-Raft restore.

## Manual operations after rollout

Use the approved CronJob templates; do not construct arbitrary recovery pods.
The restore-test CronJob is deliberately suspended and exists as a manual template.

```sh
kubectl -n openbao-recovery create job openbao-verified-backup-manual-UNIQUE \
  --from=cronjob/openbao-verified-backup
kubectl -n openbao-recovery create job openbao-restore-test-manual-UNIQUE \
  --from=cronjob/openbao-restore-test
kubectl -n openbao-recovery get jobs
```

The runner accepts `backup` and `restore-test`; an independent restore can select
an immutable catalog ID using `restore-test --backup-id ID`. Successful job output
contains only operation, backup ID, status and restore duration. Never print the
snapshot, marker nonce, root token, projected service account token, or server log.

## Console integration contract

Console application integration is pending. The recovery chart supplies a fail-closed
admission policy and two fixed CronJob parameter bindings. Its namespace-scoped
role grants only fixed-template reads and Job get/list/create; no Secret or pod-log
access is granted. Reuse the secret-service backend's existing
operator authentication and audit trail. Its GCS identity has catalog-only read
permission, not snapshot download permission. Expose catalog metadata, backup
status, and fixed backup/restore-test operations. Each mutating request needs
operator authorization, CSRF protection and an idempotency key.

The approved pod templates are enforced at Kubernetes admission before the
backend RoleBinding is reconciled. Namespace-scoped `create jobs` alone lets a compromised
backend select a privileged recovery service account and arbitrary code. Do not
ship a console button until this boundary has an enforced denial test.
Production restore must not be exposed as an ordinary restore-test action.

## Alerts and response

`OpenBaoVerifiedBackupFailed` alerts on failed backup/test jobs.
`OpenBaoVerifiedBackupStale` alerts when no successful backup metric exists or
its age exceeds 14 hours, with a 15-minute alert debounce. Check job conditions,
GCS/KMS availability, Workload Identity, TokenReview RBAC, and networking. Keep
existing snapshots when diagnosis is uncertain. Do not bypass verification or
force a catalog update to silence the alert.

## Production recovery

Production recovery requires explicit approval naming the target and snapshot.
Capture a pre-restore snapshot and existing manifests privately, stop writers
through an approved maintenance procedure, preserve the old storage, and verify
key access before proceeding. Prefer a replacement isolated cluster first. A
production Raft overwrite is not performed by this automation. Validate recovered
application authentication and secret access before routing clients or resuming
writers. Record operator, snapshot generation, approval and application checks.

Rollback the scheduling/chart change through Git. Keep the new bucket and keys.
The legacy backup schedule is suspended after successful acceptance and can be
re-enabled through Git. No production
Raft rollback is required to disable failed backup automation.

### Alert regression checks

With Helm, PyYAML and Prometheus 2.55 `promtool` installed, run
`python3 scripts/test-openbao-recovery-alerts.py`. The scenarios verify that
successful backups resolve older failures and that a backup success cannot hide
an independent restore-test failure. Each operation compares the creation time
of its latest failed and successful Jobs; an operation with no success still alerts.
