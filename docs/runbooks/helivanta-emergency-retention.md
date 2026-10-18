# Emergency caller-contact retention

Owner: Helivanta operations. Application implementation: helivanta#1227.

This job clears expired caller ciphertext. It never deletes a case, incident,
closure, timeline or unpublished event. API reads mask caller data at expiry
independently of successful maintenance. Do not treat a purge as backup erasure.

The default chart creates no CronJob. The explicit enabled configuration is still
suspended. Enable and unsuspend only after reviewing the approved caller retention
policy, clinical incident retention, backup/restore controls, named owner and the
promoted image containing `/app/emergency-retention`. The image must match the API
and migrations and use its in-region GAR repository. No new secret store exists.

## Alert

`HelivantaEmergencyContactRetentionOverdue` selects an unsuspended CronJob with no
successful run in the previous hour, including a missing last-success metric. It
waits 30 minutes to tolerate the first scheduled run. Suspended jobs do not alert.
Confirm kube-state-metrics exposes the last-success metric before activation and
that Alertmanager routes `owner=helivanta` to the responsible team.

Read-only diagnosis:

```sh
kubectl config current-context
kubectl -n helivanta get cronjob helivanta-api-emergency-retention -o wide
kubectl -n helivanta get jobs -l app.kubernetes.io/component=emergency-retention
kubectl -n helivanta get pods -l app.kubernetes.io/name=helivanta-emergency-retention
kubectl -n helivanta logs job/<failed-job-name> --all-containers
```

Logs carry counts and fixed operational errors, not caller payloads. Check image
availability, CronJob suspend state, namespace resource quota, job deadlines,
CNPG health and OpenBao-backed ESO credential synchronization. Do not print secret
values, execute environment dumps or weaken forced RLS. The command uses restricted
application and existing operational system DSNs, not schema-owner credentials.
The system role has bounded new contact-column update and append-audit grants;
its general platform operational privileges remain the existing trust boundary.

Each run is bounded to ten batches of 200, five minutes overall, 330 seconds at the
Job level, one retry and no concurrent run. A batch-ceiling log warns that backlog
may remain even when a job succeeds. Investigate repeated ceilings and capacity;
never delete records to make the alert green. Two thousand contacts per 15 minutes
exceeds the documented pilot planning load; remeasure if load materially changes.

## Recovery and verification

Correct credential readers/writers through GitOps and OpenBao, preserve exact-path
namespace policies, then get explicit approval before a live rerun, rollout or
unsuspend. Do not use `kubectl apply`, patch cron settings, rotate credentials or
change an Argo-managed object imperatively. A failed transaction rolls back purge
and audit together; replay clears each still-expired envelope once. SKIP LOCKED
prevents overlapping manual invocations from waiting on the same batch.

Check a fresh `lastSuccessfulTime`, count-only job logs and the append-only
`case.contact_purged` audits using an authorised operations process. An independent
synthetic test proves expired contacts remain absent while incident/timeline are
readable to an explicitly granted supervisor. Never use a real incident in a
GitHub issue or public screenshot.

Code rollback must retain compatible maintenance and decryption for data already
collected. Do not drop the additive emergency tables or revoke keys. Restore
procedures must reapply expiry purging before restored caller data is served and
respect the separately approved clinical retention/hold policy.
