# sm-version-cleanup

Self-sustaining GCP Secret Manager version retention. Runs as a Kubernetes
CronJob in the `global` namespace and, on each tick, keeps the latest N active
versions of every secret in the `tesseracthub-480811` project and destroys
older ones.

## Why

Secret Manager bills `Secret version replica storage` per active
(ENABLED+DISABLED) version, per replication location, per month. Without
retention, every rotation accumulates storage cost forever.

## How it works

- Image: `google/cloud-sdk:slim` (no custom build).
- Auth: Workload Identity. The KSA `global/sm-version-cleanup` is bound to the
  GSA `sm-cleanup-sa@tesseracthub-480811.iam.gserviceaccount.com`, which holds
  two project roles:
  - `roles/secretmanager.secretVersionManager` — list/disable/destroy versions
  - `roles/secretmanager.viewer` — list/get secrets (versionManager alone does
    not include `secretmanager.secrets.list`, which the script needs to
    enumerate the project)
  Cannot delete secret resources, cannot read payload bytes.
- Schedule: weekly, Sunday 03:00 UTC (`0 3 * * 0`).
- Idempotent: if no secret has more than `keep` active versions, the job is a
  no-op and exits SUCCESS.

## Configuration

| Key | Default | Notes |
|---|---|---|
| `gcp.projectId` | `tesseracthub-480811` | Project to clean up. |
| `gcp.keep` | `2` | Newest N active versions retained per secret. |
| `gcp.destroy` | `true` | Set to `false` for dry-run (logs the plan only). |
| `gcp.nameFilter` | `""` | gcloud `name~` regex; empty = all secrets. |
| `schedule` | `0 3 * * 0` | Cron, UTC. |

## One-time GCP setup (already done)

```bash
PROJECT=tesseracthub-480811
GSA_EMAIL=sm-cleanup-sa@$PROJECT.iam.gserviceaccount.com

gcloud iam service-accounts create sm-cleanup-sa \
  --project=$PROJECT \
  --display-name="SM Version Cleanup CronJob"

gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$GSA_EMAIL" \
  --role="roles/secretmanager.secretVersionManager"

gcloud projects add-iam-policy-binding $PROJECT \
  --member="serviceAccount:$GSA_EMAIL" \
  --role="roles/secretmanager.viewer"

gcloud iam service-accounts add-iam-policy-binding $GSA_EMAIL \
  --project=$PROJECT \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT.svc.id.goog[global/sm-version-cleanup]"
```

## Operations

Logs of the most recent run:
```bash
kubectl -n global logs -l app.kubernetes.io/name=sm-version-cleanup --tail=200
```

Trigger an off-schedule run (testing):
```bash
kubectl -n global create job sm-version-cleanup-manual-$(date +%s) \
  --from=cronjob/sm-version-cleanup
```

Disable temporarily (e.g., during a migration that adds many versions you want
to keep):
```bash
# Edit values.yaml:  suspend: true   then commit + ArgoCD sync.
```

Switch to dry-run (no destroys):
```bash
# Edit values.yaml:  gcp.destroy: false   then commit + ArgoCD sync.
```

## Failure modes

- **`PERMISSION_DENIED` listing or destroying versions**: the GSA binding has
  drifted. Re-apply the IAM bindings shown above.
- **Job hangs past `activeDeadlineSeconds`**: many secrets with many versions
  will take longer than 30 minutes. Bump `activeDeadlineSeconds` in values.
- **Need to recover a destroyed version**: not possible. Destroy is
  permanent. If a critical version was lost, rotate the underlying credential
  and add a new version.
