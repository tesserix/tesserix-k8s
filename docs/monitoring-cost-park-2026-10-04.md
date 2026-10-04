# Temporary production monitoring shutdown

Prepared on 2026-10-04 at the owner's request to stop monitoring traffic and
reduce cost. This file describes the intended rollout; it does not prove the
live cluster has been changed.

Target: `tesseracthub-480811`, `asia-south1`, cluster
`tesseract-prod-in-gke`. Namespaces: `monitoring`, `observability`, `opencost`.
Grafana in `monitoring` and Kiali in `istio-system` are already parked.

## Desired state

Production Application Helm parameters override the running chart defaults.
Removing these park parameters restores the recorded running configuration.
Services, configuration, credentials, rules, charts and persistent volumes stay
in place. Do not disable the releases, unregister their Applications or delete
their namespaces.

| Application | Park | Restore |
|---|---|---|
| kube-prometheus-stack | Prometheus, Alertmanager and kube-state-metrics: 0 | 1 each |
| clickhouse-ha | 0 | 2 |
| clickhouse-keeper | 0 | 3 |
| redpanda | 0; retain 3 explicit expansion PVCs | 3 |
| otel-gateway | 0; retain 2 explicit expansion PVCs | 2 |
| otel-ingest | 0 | 2 |
| otel-cluster | 0 | 1 |
| otel-agent | `nodeSelector.workload: observability-parked` | remove override |
| obs-api / obs-ui | 0 each | 2 each |
| langfuse | web and worker: 0 | 2 each |
| opencost | all four deployments: 0 | 1 each |
| observability-db-schema-bootstrap | CronJob suspended | remove override |

No current node carries `workload=observability-parked`. Do not add this label
to a node while monitoring is parked. StatefulSet PVC retention was verified as
`Retain` on both scale and deletion. Explicit Redpanda/gateway claims remain
rendered using `persistence.retainedReplicas`; their `Prune=false,Delete=false`
annotations also remain intact. The temporary Redpanda topic bootstrap hook is
not rendered while brokers are at zero.

## Rollout

Use GitOps only. Commit/push/merge authorization is separate from the approved
monitoring shutdown. Keep the unrelated working-tree changes out of the rollout.

1. Publish the first-stage changes with the Prometheus operator still running.
   Reconcile the production Application definitions and sync the child apps.
   Langfuse deliberately uses manual sync, so merging alone does not stop it.
2. Verify that the Prometheus and Alertmanager CRs and their generated
   StatefulSets all show `spec.replicas: 0`, with zero current/ready replicas.
   Confirm zero scheduled OTel agents, zero other target workload replicas and
   a suspended schema CronJob. Check no telemetry Job remains active; suspending
   a CronJob does not stop an already running Job.
3. Only after step 2, publish these additional kube-prometheus-stack Helm
   parameters and sync that Application:

   ```yaml
   - name: prometheusOperator.nodeSelector.workload
     value: observability-parked
   - name: prometheusOperator.strategy.type
     value: Recreate
   - name: prometheusOperator.admissionWebhooks.failurePolicy
     value: Ignore
   ```

   Chart 65.5.0 hardcodes one operator replica. The unmatched selector prevents
   it from running; `Recreate` is necessary because RollingUpdate would retain
   the existing pod while the replacement cannot schedule. This leaves one
   unscheduled Pending pod and may make the Application report Progressing.
   There must be zero running operator pods. Do not turn the controller off
   before it has stopped its managed StatefulSets.

   `Ignore` applies only to PrometheusRule admission checks so other GitOps
   rule updates are not blocked by the parked webhook. It does not change
   mesh authentication, authorization, networking policy or application access.
4. Confirm the target namespaces contain no Running telemetry pods and inspect
   affected application readiness. Use billing exports after a complete usage
   day to measure the reduction; billing data arrives with a delay.

## Effects and remaining costs

- Metrics collection, alert evaluation/delivery, log/event/trace collection,
  the observability explorer, Langfuse and cost dashboards stop.
- Prometheus uses `emptyDir`; its recent local history is lost on shutdown.
  ClickHouse, Redpanda and disk-backed gateway queues remain on their PVCs.
- Product telemetry exporters can retry/drop data while their receivers are
  parked. The AI tracing SDK is fail-open; monitoring downtime creates a gap in
  telemetry and does not mean historical data will be backfilled.
- Only one live ScaledObject currently uses Prometheus: the already parked
  `stockpilot/fingpt-inference`. Other application autoscalers and controllers
  are not modified. Recheck this dependency before rollout if live state changes.
- Shared `infra-postgres`, global Valkey, OpenBao, application databases,
  OpenPanel product analytics and the service mesh are not part of this shutdown.
- Existing CUD fees, retained disks/snapshots, fixed NAT/IP/load-balancer/PSC
  charges and application network traffic continue. Zero monitoring pods is
  not a zero cloud bill. Scaling nodes down does not cancel purchased CUDs.

The October 1–2 network bill extrapolates to about AUD 284 per 30 days, including
AUD 178 in cross-zone transfer and AUD 46 in NAT data processing. A separate
24-hour mesh measurement attributed 131.43 GiB of known cross-zone traffic to
the monitoring namespace, about AUD 56 per 30 days at the observed billed rate.
This is a measured candidate saving, not a guarantee or a complete accounting
of monitoring traffic; OTel and some other paths are outside that attribution.

## Restore

Restore the operator first: remove its second-stage selector, strategy and
webhook overrides; sync and wait for it to be Running and Ready. Restore Keeper,
then ClickHouse, then Redpanda and the gateway; wait for their retained data
services to become Ready. Unsuspend schema reconciliation and verify it succeeds.
Remove the remaining park parameters for the ingest, collectors, UI/API,
Langfuse, cost dashboards and monitoring CRs. Sync the manually managed Langfuse
Application explicitly. Restore Prometheus/Alertmanager and verify metrics,
alert routing and the relevant autoscaler before considering revival complete.

Do not use the old dedicated-node-pool recreation commands in
`docs/observability-park.md`: these workloads currently use the existing shared
pool. No node pool is removed by this change.
