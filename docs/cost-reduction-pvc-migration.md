# PVC Migration Runbook: pd-balanced → pd-standard

## Why
8 PVCs hold caches / model files / uploads that don't need pd-balanced IOPS.
Migrating them to pd-standard saves ~10–15 AUD/mo and removes future growth.

## Migration candidates

| Namespace / PVC | Size | Workload | Reclaim | Target SC |
|---|---|---|---|---|
| `growthbook/growthbook-uploads` | 10Gi | Uploads | Delete | `economy-rwo` |
| `homechef/homechef-api-uploads` | 10Gi | API uploads | Delete | `economy-rwo` |
| `monitoring/grafana` | 10Gi | Dashboards (read) | Delete | `economy-rwo` |
| `stockpilot/fingpt-inference-models` | 10Gi | ML model cache | Delete | `economy-rwo` |
| `translation/bergamot-service-models` | 5Gi | ML model | Delete | `economy-rwo` |
| `translation/huggingface-mt-service-cache` | 10Gi | ML cache | Delete | `economy-rwo` |
| `translation/libretranslate-models` | 20Gi | Translation models | Delete | `economy-rwo` |
| `scrapper/postsocial-uploads` | 20Gi | User uploads | Retain | `economy-rwo-retain` |

**DO NOT migrate** any PVC matching `*-postgres-*`, `*-mongodb-*`, `*-redis-*`,
`typesense-*`, `nats-*`, `temporal-*`, `clickhouse-*`, or `mysql-*` — they need
pd-balanced IOPS and are not in scope here.

## Per-PVC procedure (model cache example)

This procedure is destructive of the existing PD; do it in a maintenance
window. Workload is offline for the duration of the snapshot+restore (typ.
2–10 min for ≤20 GiB).

```sh
NS=translation
PVC=libretranslate-models
NEW_SC=economy-rwo

# 1. Scale workload down
kubectl scale -n $NS deploy/libretranslate --replicas=0
# Wait until no pod owns the PVC
kubectl get pods -n $NS -l app=libretranslate

# 2. Find the underlying disk
DISK=$(kubectl get pvc -n $NS $PVC -o jsonpath='{.spec.volumeName}')
ZONE=$(kubectl get pv $DISK -o jsonpath='{.spec.csi.volumeAttributes.topology\.gke\.io/zone}' \
       || gcloud compute disks list --filter="name=$DISK" --format='value(zone.basename())')

# 3. Snapshot the PD (cheap, persists during migration)
gcloud compute disks snapshot $DISK --zone=$ZONE \
  --snapshot-names=${PVC}-pre-migration --project=tesseracthub-480811

# 4. Delete the PVC AND PV. With reclaimPolicy=Delete, the PD is also deleted.
#    With Retain, manually delete the PD afterwards.
kubectl delete pvc -n $NS $PVC

# 5. Recreate PVC pointing at the new SC + restoring from snapshot.
#    Easiest: deploy with updated chart (storageClass: economy-rwo) and let
#    GKE provision a fresh PV; copy data from snapshot via a one-shot Job.
#
#    OR: pre-create a PV from the snapshot:
gcloud compute disks create $PVC-restored --zone=$ZONE \
  --source-snapshot=${PVC}-pre-migration --type=pd-standard \
  --project=tesseracthub-480811

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PVC}-restored
spec:
  capacity: { storage: 20Gi }
  accessModes: [ReadWriteOnce]
  storageClassName: $NEW_SC
  csi:
    driver: pd.csi.storage.gke.io
    volumeHandle: projects/tesseracthub-480811/zones/$ZONE/disks/${PVC}-restored
    fsType: ext4
  claimRef:
    namespace: $NS
    name: $PVC
EOF

# 6. Recreate PVC with new SC, bound to that PV
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: $PVC, namespace: $NS }
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $NEW_SC
  resources: { requests: { storage: 20Gi } }
  volumeName: ${PVC}-restored
EOF

# 7. Scale workload back up
kubectl scale -n $NS deploy/libretranslate --replicas=1

# 8. Verify, then delete the snapshot (or keep for one billing cycle)
gcloud compute snapshots delete ${PVC}-pre-migration --project=tesseracthub-480811
```

## Validation after each migration

```sh
# Confirm PVC is bound to a pd-standard disk
kubectl get pvc -n $NS $PVC \
  -o jsonpath='{.spec.storageClassName}{"\n"}'   # → economy-rwo

# Confirm pod restarts cleanly
kubectl wait --for=condition=ready pod -n $NS -l app=<app> --timeout=120s

# Confirm app-level health
kubectl logs -n $NS deploy/<app> --tail=50
```

## Rollback (per-PVC)
```sh
# Re-snapshot the migrated disk before deleting if you've written new data
# Then restore from the original $PVC-pre-migration snapshot using the
# same procedure but pointing at standard-rwo.
```

## Suggested batching
Run in two windows of ~30 min each:

1. **Low-risk** (caches, easily rebuilt — start here):
   `bergamot-service-models`, `huggingface-mt-service-cache`,
   `fingpt-inference-models`, `libretranslate-models`
2. **Stateful uploads** (snapshots required, do second):
   `growthbook-uploads`, `homechef-api-uploads`, `postsocial-uploads`,
   `grafana`

## Estimated savings after full migration
- 95 GiB × ($0.17 - $0.06)/GiB-mo ≈ **10.5 AUD/mo**
- Future deployments via Helm charts now default to `economy-rwo` for
  applicable workloads — savings compound as workloads grow.
