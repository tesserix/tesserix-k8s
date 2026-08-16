# GKE upgrade runbook

Manual, gated upgrade of a GKE cluster via the **GKE Upgrade (Manual)** workflow
(`.github/workflows/gke-upgrade.yaml`). Nothing here runs on a schedule — an
upgrade only ever happens because a human dispatched it.

## One-time setup

Both of these are prerequisites; the workflow fails without them.

**1. Grant the CI service account permission to upgrade.**
`github-actions@tesseracthub-480811` currently holds `roles/container.developer`,
which can read clusters and talk to the Kubernetes API but **cannot** call
`container.clusters.update`. Without this the upgrade job fails at the first
`gcloud container clusters upgrade`:

```bash
gcloud projects add-iam-policy-binding tesseracthub-480811 \
  --member=serviceAccount:github-actions@tesseracthub-480811.iam.gserviceaccount.com \
  --role=roles/container.clusterAdmin

# optional: lets preflight read deprecated-API insights instead of warning
gcloud projects add-iam-policy-binding tesseracthub-480811 \
  --member=serviceAccount:github-actions@tesseracthub-480811.iam.gserviceaccount.com \
  --role=roles/recommender.viewer
```

**2. Create the `gke-upgrade` environment with required reviewers.** The upgrade
job declares `environment: gke-upgrade`. If the environment does not exist GitHub
creates it on first use *with no protection rules*, which silently removes the
approval gate — so create it explicitly:

```bash
gh api -X PUT repos/tesserix/tesserix-k8s/environments/gke-upgrade \
  -f 'reviewers[][type]=User' -F 'reviewers[][id]=<github-user-id>'
```

## Running an upgrade

Always in this order, one dispatch each. Preflight re-runs every time.

| Step | scope | dry_run | Why |
|---|---|---|---|
| 1 | `control-plane` | `true` | See the plan and the blockers, change nothing |
| 2 | `control-plane` | `false` | Control plane first — nodes may never exceed it |
| 3 | `node-pools` | `false` | Nodes follow, one pool at a time |

Set `target_version` to an exact version (`1.36.2-gke.2064000`). `latest` is
rejected. Check what the channel offers:

```bash
gcloud container get-server-config --region=asia-south1 --project=tesseracthub-480811 \
  --flatten=channels --filter='channels.channel=REGULAR' \
  --format='value(channels.validVersions)' | tr ';' '\n'
```

`confirm` must be typed as the exact cluster name, and `dry_run` defaults to
true, so the safe path is the default path.

## What preflight blocks on

Blockers fail the run before anything is touched. Warnings are printed and allowed.

- Cluster not `RUNNING`, or another cluster operation already in flight.
- Downgrade, a skipped minor version, or an unparseable target.
- Target not offered by the cluster's release channel — override with
  `allow_out_of_channel` if you deliberately want to run ahead of the channel.
- A node pool that would end up ahead of the target control plane version.
- Any node that is not Ready. A cordoned-but-Ready node is only a warning: that
  is normally the cluster autoscaler retiring a node, not a fault.
- Deprecated API usage that the target version removes.
- **PDBs that allow zero evictions.** This is the usual blocker on this cluster —
  every single-instance CNPG `*-postgres-primary` has `minAvailable: 1`, so a
  drain cannot legally evict it. GKE waits about an hour per node and then
  force-drains anyway, which means an uncoordinated restart for that database.
  Either scale the CNPG cluster to 2 instances first so it can switch over
  cleanly, or set `allow_blocking_pdbs` and accept the downtime.

## Node pool strategies

`pool_strategy` applies **only** to the pools named in `recreate_pools`
(default `gpu-l4-spot`). Every other pool always surge-upgrades.

- **`recreate`** (default) — delete the pool and rebuild it at the target
  version from the spec captured during preflight. Used because a surge upgrade
  must first obtain an *additional* spot L4 node in `asia-south1` before it will
  drain the old one, and that capacity may simply not exist, leaving the upgrade
  stalled. Recreate accepts a short outage on that pool instead of a stall.
- **`surge`** — normal in-place rolling upgrade. **Switch `gpu-l4-spot` to this,
  and empty `recreate_pools`, once those nodes move to CUD/on-demand capacity**,
  since the surge node is then guaranteed to be available.
- **`skip`** — leave the pool alone.

Recreate-strategy pools are always upgraded **last**, so a capacity failure there
cannot leave the rest of the cluster half-upgraded.

### Recreate safety

Before deleting anything, the workflow writes `recreate-<pool>.sh` into the run
artifacts — a runnable script that rebuilds the pool exactly as it was. If the
workflow dies between delete and create, run that script.

Flag generation **fails closed**: if a pool's spec contains a field the script
cannot faithfully reproduce, it refuses to delete the pool rather than rebuild a
pool that differs from the one it replaced.

## Verification

Runs automatically after a non-dry-run upgrade. It waits `SETTLE_SECONDS`
(default 180) and then checks control plane and node pool versions, node
readiness, kubelet versions, and pod/workload/CNPG/ArgoCD health.

Health is compared **against the pre-upgrade baseline**, so only workloads the
upgrade actually broke fail the run — things already unhealthy beforehand (this
cluster has a scaled-to-zero `observability` stack and a number of
already-degraded ArgoCD apps) do not produce false failures.

## Rollback

**A GKE control plane cannot be downgraded.** Rolling forward is the only option,
so the control plane dry run matters.

Node pools can be rolled back after a *failed* upgrade:

```bash
gcloud container node-pools rollback <pool> --cluster=tesseract-prod-in-gke \
  --region=asia-south1 --project=tesseracthub-480811
```

For a recreated pool, roll back by running the `recreate-<pool>.sh` artifact with
`--node-version` set to the old version.

## Local use

Everything the workflow runs is a plain script, so preflight can be run from a
laptop against a live cluster without changing anything:

```bash
./scripts/gke-upgrade/preflight.sh tesseract-prod-in-gke asia-south1 \
  tesseracthub-480811 1.36.2-gke.2064000 both ./artifacts

bash scripts/gke-upgrade/tests/run-tests.sh   # offline unit tests, no cloud access
```
