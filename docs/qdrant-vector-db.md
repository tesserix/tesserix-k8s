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
| Auth | API key via `QDRANT__SERVICE__API_KEY`; ExternalSecret ships with the chart, sourced from OpenBao `qdrant/app/qdrant-api-key` |
| Backups | nightly 02:00 UTC → `gs://tesseract-prod-backups-in/qdrant/`, 14 days — deployed, not yet verified |

Live since 2026-08-13: three replicas Ready, raft leader elected, no collections
yet.

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

## Four traps worth knowing before editing

1. **Do not use the chart's `apiKey:` value.** It resolves the key with a Helm
   `lookup`, which returns empty under ArgoCD's server-side `helm template`.
   The chart then renders an empty key and ships an *unauthenticated* cluster
   that looks fine in the UI. The key is injected as an env var instead.
2. **Do not enable `livenessProbe` or `startupProbe`.** The chart hardcodes
   `/` for both, and `/` returns 401 once an API key is set — every pod
   restarts forever. Only readiness is enabled, because `/readyz` is one of the
   three endpoints Qdrant serves unauthenticated.
3. **DNS egress needs the kube-dns service IP, not just a `kube-system`
   namespaceSelector.** The cluster runs NodeLocal DNSCache, which answers from
   the node, so the selector never matches. Without `dnsServiceIP` in the
   policy, `qdrant-0` comes up alone and every other replica panics with
   `Failed to initialize Consensus ... Temporary failure in name resolution`.
4. **`volumeClaimTemplates` needs `ignoreDifferences`.** The API server defaults
   `apiVersion`, `kind`, `volumeMode` and `status` into them and the chart sets
   none of it, so the app sits OutOfSync while Healthy and self-heal re-syncs
   every reconcile. The ignore lives on the Application and is diff-only —
   do not add `RespectIgnoreDifferences` (CLAUDE.md gotcha 11).

## Connecting from a service

```
QDRANT_URL=http://qdrant.ai-database.svc.cluster.local:6333
QDRANT_API_KEY=<injected by the namespace-bound OpenBao reader>
```

Two things gate access, and both must be updated for a new consumer:

1. Add the consumer's namespace to `allowedSources` in
   `charts/apps/ai-database-namespace/values.yaml` (drives both the L3
   NetworkPolicy and the L7 AuthorizationPolicy).
2. Add a namespace-bound, exact-path OpenBao reader and ExternalSecret for
   `qdrant/app/qdrant-api-key` — or `qdrant/app/qdrant-read-only-api-key` for
   query-only workloads — using the `value` property. Keep every consumer of a
   shared key on the same source and coordinate rotations.

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

**Not yet verified end to end.** The GSA, its `roles/storage.objectAdmin` on
the bucket and the Workload Identity binding are all in place, but no run has
written to GCS — the first scheduled run fired during the DNS outage in trap 3,
with one node up, and failed. Smoke-test it with
`kubectl create job --from=cronjob/qdrant-snapshot-backup <name> -n ai-database`
before relying on it.

To restore, copy the node snapshots onto the snapshot PVCs and use the chart's
`snapshotRestoration` values, or `PUT /collections/<name>/snapshots/recover`
per node with a signed URL. Restore is not automated — write the runbook the
first time it is needed for real.

## Operations

```bash
kubectl config use-context gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke

# Cluster health (raft peers, one entry per node). The image ships no curl,
# so drive the API from outside rather than kubectl exec.
KEY=$(kubectl get secret qdrant-api-keys -n ai-database -o jsonpath='{.data.api-key}' | base64 -d)
kubectl port-forward -n ai-database svc/qdrant 16333:6333 &
curl -s -H "api-key: $KEY" localhost:16333/cluster | python3 -m json.tool

kubectl get pods,pvc -n ai-database
kubectl logs -n ai-database job/<qdrant-snapshot-backup-...>
```

**Shard rebalancing** after a node replacement is manual (the operator's
cluster-manager would do it):
`POST /collections/<name>/cluster` with a `move_shard` operation.

## One-time GCP setup

Provision the two `qdrant/app/` key paths through the approved secret-service
writer before installing a new environment. Use create-only writes and readback
verification; never rotate an existing environment as a bootstrap step. Do not
create replacement GCP Secret Manager records.

Backup Workload Identity is a separate dependency, provisioned once per environment:

```bash
PROJECT=tesseracthub-480811

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

## OpenBao cutover (2026-10-08)

Both API keys use the namespace-bound `read-qdrant-production` role and
`openbao-qdrant-production` SecretStore. The role can read only
`qdrant/app/qdrant-api-key` and `qdrant/app/qdrant-read-only-api-key`, property
`value`; it cannot list or write secrets. Existing Kubernetes key names,
workload images and replicas are preserved. The initial copy pins GCP version 1
and checks equality with the running workload before create-only staging.

Assets are Qdrant read/write access and its data. A compromised other namespace
must not acquire these credentials; the reader binds the existing `qdrant`
ServiceAccount only in `ai-database`. ESO refreshes every five minutes. If
OpenBao is unavailable, existing Kubernetes secrets remain; new provisioning
fails closed. No credential is rotated by this migration.

Retain both GCP originals until fresh ESO sync, exact readback, namespace denial,
authenticated Qdrant checks and a verified OpenBao backup/restore pass. Deleting
the sources is a separate reviewed retirement, including the Terraform owner
and every external runtime/CI client.
Rollback before retirement restores the old ExternalSecret references without
changing values. Future key rotations must coordinate all Qdrant consumers.

DevAI consumes the shared read/write key through `openbao-qdrant` in `devai`,
using the existing `devai-production-reader` identity and exact single-path
`read-qdrant-devai` policy. It cannot read the separate read-only credential.
Both consumers must refresh and match before source retirement.


PR #1324 deployed on 2026-10-08: OpenBao, Qdrant and shared ExternalSecrets are
Synced/Healthy. Both consumers refreshed from OpenBao with unchanged key values;
Qdrant remains 3/3 ready and DevAI API/worker remain 3/3 and 2/2 ready.
Read/write and read-only keys return HTTP 200 for collection reads; invalid keys
return 401. Exact read-only capabilities and wrong-namespace denial passed.
Backup `20261008T025841Z-3b502a5a7123` passed restore verification in 19.467s and an
independent isolated restore in 26.122s. The two pinned originals and metadata
are encrypted at `gs://tesseract-prod-backups-in/openbao/qdrant-migration/20261008/gcp-sources.json.kms`;
remote decrypt/readback equality passed. After explicit retirement approval and a
final version/equality check, both originals were deleted at 03:15 UTC on
2026-10-08; GCP returned 404 for each. No other originals were deleted.
Post-deletion ESO refreshes succeeded at 03:17:23 UTC (Qdrant) and 03:17:26 UTC
(DevAI). Readback equality, exact permissions, wrong-namespace denial and all
three authentication checks passed again; workload readiness remained unchanged.
The encrypted archive is pinned to generation `1791428997651231`. Storage for
these two GCP versions is retired; the resulting bill reduction is not yet measured.
