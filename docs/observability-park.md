# Observability park — 2026-08-01

The whole observability estate is parked at **0 pods** to cut GCP spend. Nothing
was deleted: every Application, chart, Service, ConfigMap, Secret, PVC and alert
rule is still in Git and still in the cluster. Revival is flipping replica
counts back and recreating one node pool.

## What is parked

| Component | Namespace | Where the park lives | Running value |
|---|---|---|---|
| `clickhouse` | observability | `charts/thirdparty/clickhouse-ha/values.yaml` | `replicaCount: 2` |
| `clickhouse-keeper` | observability | `charts/thirdparty/clickhouse-keeper/values.yaml` | `replicaCount: 3` |
| `redpanda` | observability | **revived 2026-09-03** as the AI-trace buffer, see `docs/ai-trace-pipeline.md` | `replicaCount: 3` |
| `otel-gateway` | observability | **revived 2026-09-03**, traces only, AI filter | `replicaCount: 2` |
| `otel-ingest` | observability | **revived 2026-09-03**, routes Kafka to Langfuse (ClickHouse exporter removed) | `replicaCount: 2` |
| `otel-cluster` | observability | `charts/thirdparty/otel-cluster/values.yaml` | `replicaCount: 1` (never more) |
| `otel-agent` (DaemonSet) | observability | `charts/thirdparty/otel-agent/values.yaml` | `nodeSelector: {}` |
| `obs-api` | observability | **revived 2026-09-03** for the public explorer | `replicaCount: 2` |
| `obs-ui` | observability | **revived 2026-09-03** for the public explorer | `replicaCount: 2` |
| ClickHouse schema CronJob | observability | `argocd/prod/infrastructure/observability-db-schema-bootstrap.yaml` | `suspend: false` |
| `prometheus-server` | monitoring | `argocd/prod/infrastructure/prometheus.yaml` → `server.replicaCount` | `1` |
| `prometheus-alertmanager` | monitoring | same file → `alertmanager.replicaCount` | `1` |
| `kube-state-metrics` | monitoring | same file → `kube-state-metrics.replicas` | `1` |
| `pushgateway` | monitoring | same file → `prometheus-pushgateway.replicaCount` | `1` |
| `node-exporter` (DaemonSet) | monitoring | same file → `prometheus-node-exporter.nodeSelector` | `{}` |
| `grafana` | monitoring | `argocd/prod/infrastructure/grafana.yaml` → `replicas` | `1` |
| `kiali` | istio-system | `argocd/prod/infrastructure/kiali.yaml` → `deployment.replicas` | `1` |

DaemonSets have no replica count, so their park is an **unsatisfiable
`nodeSelector`** (`tesserix.io/otel-agent`, `tesserix.io/node-exporter` — labels
no node carries). Desired drops to 0 while the DaemonSet object stays.

`enabled: false` was deliberately **not** used anywhere: every one of these
ArgoCD apps runs `prune: true`, so disabling a subchart would delete the
workload, its Service and its PVC outright.

## Retained state

The 32 GiB in `monitoring` (Prometheus TSDB 20, Grafana 10, Alertmanager 2) is
intact — ~$5/month, not worth the revival friction.

The 390 GiB in `observability` (ClickHouse 2×100, Redpanda 3×40, keeper 3×10,
otel-gateway queue 2×20) is **being deleted** — telemetry history is not worth
$68/month while nothing reads it. Eight of the ten are `Retain`, so the PVC
delete alone leaves the disks behind; PV and disk must go too. Revival therefore
starts from an empty store and needs the schema bootstrap to run before
otel-ingest can write.

## Node pool

The `observability` node pool was deleted. It autoscaled `totalMinNodeCount: 3`,
so it held three nodes regardless of how few pods it ran — parking pods alone
would not have released them.

Recreate it before scaling anything back up, or the pods pend forever on the
`workload=observability` taint:

```bash
gcloud container node-pools create observability \
  --cluster tesseract-prod-in-gke --region asia-south1 \
  --project tesseracthub-480811 \
  --machine-type e2-highmem-2 --spot \
  --disk-type pd-balanced --disk-size 50 \
  --image-type COS_CONTAINERD \
  --node-labels workload=observability \
  --node-taints workload=observability:NoSchedule \
  --enable-autoscaling --total-min-nodes 3 --total-max-nodes 6 \
  --location-policy ANY \
  --node-locations asia-south1-a,asia-south1-b,asia-south1-c \
  --enable-autorepair --enable-autoupgrade \
  --workload-metadata=GKE_METADATA \
  --shielded-secure-boot --shielded-integrity-monitoring \
  --max-pods-per-node 110 --enable-private-nodes
```

`--node-locations` must stay all three zones: the retained PVCs are zonal disks
spread across a, b and c, and a pod cannot bind a disk in a zone the pool does
not reach.

## Revival order

1. Recreate the node pool above; wait for three `Ready` nodes.
2. `clickhouse-keeper` → 3, then `clickhouse` → 2. Wait for ClickHouse `Ready` —
   Keeper quorum must exist first or the replicated tables will not attach.
3. `suspend: false` on the schema bootstrap; confirm the CronJob run succeeds.
4. `redpanda`, `otel-gateway` and `otel-ingest` are already back as the AI-trace
   pipeline on `optimized-v2`; reviving the rest means `otel-cluster` → 1 and
   emptying `otel-agent`'s `nodeSelector`, plus restoring the ClickHouse exporter
   and the log/metric topics the AI pipeline removed.
5. `obs-api` → 2, `obs-ui` → 2.
6. Monitoring side, independent of the above: `prometheus.yaml` counts back to 1,
   empty `prometheus-node-exporter.nodeSelector`, `grafana` → 1, `kiali` → 1.
   Prometheus needs up to an hour of WAL replay on first start; that is what the
   240-failure startup probe in its values is for.

## Notes

- Product services still carry their `OTEL_EXPORTER_*` env vars and will keep
  trying to export. The OTel SDK drops spans and logs a retry — no request path
  fails. Their exporter logs get noisier while parked.
- Alert rules, `AlertmanagerConfig` and Grafana dashboards still render and sync.
  Nothing evaluates or delivers them while Prometheus and Alertmanager are at 0 —
  including the CNPG disk-full and HA alerts, so a repeat of the 2026-06-17
  Postgres disk deadlock would arrive with no warning. The autoheal CronJob that
  incident produced is unaffected and still runs.
- `gpu-l4-spot` and `sandbox-gvisor` both sit at zero nodes already and cost
  nothing but their pool definitions.
- **Eight ScaledObjects carry a `prometheus` trigger** and now log
  `FailedGetExternalMetric` every 30s: `devai-api`, `homechef-api`,
  `homechef-auth-bff`, `homechef-vendor-portal`, `homechef-web`,
  `homechef-web-app`, `mark8ly-marketplace-api-admin`, `fingpt-inference`.
  HPA holds current scale when a metric is unavailable, and the first six also
  carry a `memory` trigger that still drives scaling, so nothing stops working —
  but the Prometheus half of their scaling logic is inert until revival.
  `mark8ly-marketplace-api-admin` is `min=max=1`, so it has no scaling to lose.
  A `fallback.replicas` stanza on each would silence the errors if the park
  becomes long-lived.

## Adjacent parks from the same cost pass

- `fingpt-inference` (stockpilot) — 2.25Gi, missed by the 2026-06-12 product
  park. KEDA disabled: its prometheus trigger cannot scale to zero while
  Prometheus is parked.
- `volume-autoscaler` — suspended; it reads volume usage from Prometheus.
- `support-platform-slm-inference` / `-reranker` / `-embedder` — 9Gi parked
  because `support-platform-slm-router` has had **zero Service endpoints since
  2026-07-29**: its binary exits on `otel init: conflicting Schema URL 1.41.0
  vs 1.26.0`, a semconv mismatch that needs fixing in the product repo. Unpark
  this tier together with that fix.
- `openpanel` — its Application was applied by hand and was **not** registered in
  `argocd/prod/infrastructure/kustomization.yaml`, so commenting the file out
  never stopped it. It was never deleted and has run continuously since. As of
  2026-08-15 it is retained as the analytics backend, registered in the
  kustomization, and the Application now reads `values.yaml` + `values-prod.yaml`
  instead of a divergent inline block.
- Node count went 4 → 3 once those requests were freed. The blocker was
  `dwellm8-temporal-postgres`, a single-instance CNPG cluster whose primary PDB
  allows zero disruptions — the autoscaler can never evict it. Deleting the pod
  let CNPG rebuild it on the other zone-a node (its disk is zonal, so it can
  only move within `asia-south1-a`); ~90s of downtime. Expect to repeat this for
  any single-instance CNPG cluster that lands on a node the autoscaler wants.
