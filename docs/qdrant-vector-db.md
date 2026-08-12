# Qdrant — shared vector store (`ai-database`)

The vector database behind the AI agents: embeddings, RAG corpora, semantic
memory. One shared cluster, same policy as `global-postgres` — products get a
collection, not their own cluster.

| | |
|---|---|
| ArgoCD project | `ai-database` (`argocd/prod/projects/ai-database.yaml`) |
| Namespace | `ai-database` (ambient mesh, mTLS STRICT) |
| Chart | `charts/thirdparty/qdrant` → upstream `qdrant/qdrant` 1.18.2, image `v1.19.0` |
| Endpoints | `qdrant.ai-database.svc.cluster.local` — REST `6333`, gRPC `6334` |
| Per-pod (admin/backup only) | `qdrant-{0,1,2}.qdrant-headless.ai-database.svc.cluster.local:6333` |
| Auth | API key via `QDRANT__SERVICE__API_KEY`; ExternalSecret ships with the chart, sourced from GCP SM `prod-qdrant-api-key` |
| Backups | nightly 02:00 UTC → `gs://tesseract-prod-backups-in/qdrant/`, 14 days |

## There is no operator — that is deliberate

Qdrant's Kubernetes operator (`QdrantCluster` CRs, automated snapshots,
cluster-manager rebalancing) ships only as part of **Hybrid Cloud / Private
Cloud**, on the Enterprise plan. Its charts and images come from the gated
`registry.cloud.qdrant.io`, need an onboarding credential, and Hybrid Cloud
additionally runs a Cloud Agent that keeps an outbound connection to
`cloud.qdrant.io:443`. There is no free-standing OSS operator to install.

So this deployment is the official Helm chart plus the pieces the operator
would otherwise have provided:

| Operator feature | Replacement here |
|---|---|
| Automated snapshots + retention | `backup-cronjob.yaml` in this chart |
| Scheduling / PDB / topology config | `values.yaml` (anti-affinity, PDB, spread) |
| NetworkPolicies | `charts/apps/ai-database-namespace` |
| Vertical scaling | `allowVolumeExpansion: true` on both StorageClasses |
| Cluster manager rebalance | manual — see *Shard rebalancing* below |

If the estate ever justifies Enterprise, the migration is a re-import of
snapshots into an operator-managed `QdrantCluster`; nothing here blocks it.

## Topology

Three nodes, raft consensus. Every node in `tesseract-prod-in-gke` is Spot, so:

- **3 replicas** — an odd number keeps quorum after one preemption. Two would
  not.
- **`replication_factor: 2`** on new collections — losing a node loses no data
  and no availability. Collections created with explicit settings override
  this, so pass it when creating one by hand.
- **Required pod anti-affinity per hostname** — two replicas on one node makes
  a single preemption a quorum loss.
- **Node affinity is only preferred.** The node pools do not autoscale
  (`optimized-v2` has 2 nodes), so a hard `workload: infrastructure`
  nodeSelector would leave the third replica Pending forever.
- **PDB `maxUnavailable: 1`** — voluntary evictions (drains, upgrades) can
  never take two.

Storage per node: 20Gi `premium-rwo-retain` (pd-ssd, HNSW is random-read heavy)
for data, 20Gi `standard-rwo-retain` for snapshots. Both Retain: a deleted PVC
on a vector store means re-embedding every document. Growth is manual —
`volume-autoscaler` is driven by Prometheus, which is currently parked.

## Two traps worth knowing before editing values

1. **Do not use the chart's `apiKey:` value.** It resolves the key with a Helm
   `lookup`, which returns empty under ArgoCD's server-side `helm template`.
   The chart then renders an empty key and ships an *unauthenticated* cluster
   that looks fine in the UI. The key is injected as an env var instead.
2. **Do not enable `livenessProbe` or `startupProbe`.** The chart hardcodes
   `/` for both, and `/` returns 401 once an API key is set — every pod
   restarts forever. Only readiness is enabled, because `/readyz` is one of the
   three endpoints Qdrant serves unauthenticated.

## Connecting from a service

```
QDRANT_URL=http://qdrant.ai-database.svc.cluster.local:6333
QDRANT_API_KEY=<from prod-qdrant-api-key>
```

Two things gate access, and both must be updated for a new consumer:

1. Add the consumer's namespace to `allowedSources` in
   `charts/apps/ai-database-namespace/values.yaml` (drives both the L3
   NetworkPolicy and the L7 AuthorizationPolicy).
2. Add an ExternalSecret in the consumer's namespace pulling
   `prod-qdrant-api-key` — or `prod-qdrant-read-only-api-key` for
   query-only workloads.

The *egress* side is already handled: `istio-config`'s `vectorStoreNamespace`
value opens 6333/6334 from every namespace in `appNamespaces`, so a consumer
listed there needs no NetworkPolicy change of its own. A namespace outside that
list (support-platform manages its own policies, for instance) must add the
egress rule itself.

The consumer must be in the mesh. `PeerAuthentication` is STRICT, so a non-mesh
pod gets a connection reset with no useful error; flip
`peerAuthenticationMode` to `PERMISSIVE` deliberately rather than debugging it.

## Backups and restore

Qdrant has no cluster-wide snapshot API — snapshots are per node. The CronJob
walks each pod over headless DNS, POSTs `/snapshots`, streams the result
straight to GCS (never staging it on disk), deletes the local copy, then prunes
runs older than `backup.retentionDays`.

A run is therefore a *set* of files:

```
gs://tesseract-prod-backups-in/qdrant/<date>/<timestamp>/node-{0,1,2}/<snapshot>
```

To restore, copy the node snapshots onto the snapshot PVCs and use the chart's
`snapshotRestoration` values, or `PUT /collections/<name>/snapshots/recover`
per node with a signed URL. Restore is not automated — write the runbook the
first time it is needed for real.

## Operations

```bash
export KUBECONFIG=~/.kube/gke-prod

# Cluster health (raft peers, one entry per node)
kubectl exec -n ai-database qdrant-0 -- \
  curl -s -H "api-key: $KEY" localhost:6333/cluster | python3 -m json.tool

kubectl get pods,pvc -n ai-database
kubectl logs -n ai-database job/<qdrant-snapshot-backup-...>
```

**Shard rebalancing** after a node replacement is manual (the operator's
cluster-manager would do it):
`POST /collections/<name>/cluster` with a `move_shard` operation.

## One-time GCP setup

Not in git — run once per environment:

```bash
PROJECT=tesseracthub-480811

# API keys
for s in prod-qdrant-api-key prod-qdrant-read-only-api-key; do
  gcloud secrets create "$s" --project=$PROJECT --replication-policy=automatic
  openssl rand -base64 48 | tr -d '\n' | \
    gcloud secrets versions add "$s" --project=$PROJECT --data-file=-
done

# Workload Identity for the backup CronJob
gcloud iam service-accounts create qdrant-backup --project=$PROJECT \
  --display-name="Qdrant snapshot backup"
gcloud storage buckets add-iam-policy-binding gs://tesseract-prod-backups-in \
  --member="serviceAccount:qdrant-backup@$PROJECT.iam.gserviceaccount.com" \
  --role=roles/storage.objectAdmin --project=$PROJECT
gcloud iam service-accounts add-iam-policy-binding \
  qdrant-backup@$PROJECT.iam.gserviceaccount.com --project=$PROJECT \
  --role=roles/iam.workloadIdentityUser \
  --member="serviceAccount:$PROJECT.svc.id.goog[ai-database/qdrant-backup]"
```

The ExternalSecret stays `SecretSyncedError` and the StatefulSet stays
`CreateContainerConfigError` until the two secrets exist — that is the expected
failure mode, not a chart bug.
