# GKE upgrade runbook

Manual, gated upgrade of a GKE cluster via the **GKE Upgrade (Manual)** workflow
(`.github/workflows/gke-upgrade.yaml`). Nothing here runs on a schedule — an
upgrade only ever happens because a human dispatched it.

## Version ownership and staged upgrades

Terraform owns the exact control-plane minimum through `control_plane_version`
in `terraform-new/environments/prod/terraform.tfvars`. It no longer selects a
moving latest version for either the control plane or nodes. Node versions are
preserved by Terraform; the manual workflow upgrades individual pools after
their workload checks pass. GKE can still perform automatic upgrades outside
maintenance exclusions, so this is not an indefinite version freeze.

For the AX prerequisite upgrade, the reviewed target is
`1.37.0-gke.3503000`, offered by the cluster's Rapid channel on 2026-10-02.
`1.38.0-gke.1002000+preview` is excluded. Refresh version availability and
preflight before applying. The read-only Terraform plan showed one in-place
cluster change (`maintenance_policy`, `min_master_version`), no node-pool
changes, and no deletes/replacements.

`node_upgrade_hold` sets a bounded `NO_MINOR_OR_NODE_UPGRADES` exclusion until
2026-10-09 00:00 UTC. It prevents automatic minor and node upgrades during the
staged rollout; it does not cancel an active operation, block manual upgrades,
or prevent emergency maintenance. The pinned Google provider 5.45.2 updates
maintenance policy and waits before updating the control-plane version.
Review/remove the hold after node verification; do not silently extend it.

The cluster and managed node-pool resources also use `prevent_destroy`.
Terraform must reject replacements, including immutable node changes. This
guard does not protect a resource whose entire configuration is removed, and
does not prevent deletion through gcloud. Keep cluster deletion protection on.

Use Atlantis's saved-plan review/apply path for the Terraform change. Do not
run a Terraform apply and the manual upgrade workflow concurrently. Apply the
control-plane change only after the cluster is RUNNING and no cluster or
node-pool operation is pending/running. Verify certificate API discovery and
the before/after workload health before proceeding with AX or node upgrades.

At the assessment, automatic operation
`operation-1790899686623-0a9d0222-23cd-4b1d-98af-e9053d2b1472` was upgrading
`optimized-v2`, and the cluster was RECONCILING. It is a live gate, not a reason
to override preflight. Cancellation requires a separate named approval; an
in-flight node may finish, and completed nodes are not rolled back by cancelling.

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
- **PDBs that allow zero evictions block node upgrades, not a control-plane-only
  upgrade.** A control-plane-only run reports them without needing an eviction
  override. This is the usual node-rollout blocker on this cluster —
  every single-instance CNPG `*-postgres-primary` has `minAvailable: 1`, so a
  drain cannot legally evict it. GKE waits about an hour per node and then
  force-drains anyway, which means an uncoordinated restart for that database.
  Plan and verify database redundancy and the operator's switchover behaviour
  before draining. Setting `allow_blocking_pdbs` accepts possible forced-drain
  downtime and requires an explicit operational decision.

Preflight includes operations targeting `/clusters/<name>/nodePools/...`, and
fails closed if it cannot read operations. It runs again after environment
approval immediately before the upgrade; verification uses that fresh baseline.

## Node pool strategies

`pool_strategy` applies **only** to the pools named in `recreate_pools`
(empty by default). Every other pool always surge-upgrades. The script defaults
to `DRY_RUN=true` and rejects values other than `true` or `false`.

- **`recreate`** (explicit opt-in) — delete the pool and rebuild it at the target
  version from the spec captured during preflight. Used because a surge upgrade
  must first obtain an *additional* spot L4 node in `asia-south1` before it will
  drain the old one, and that capacity may simply not exist, leaving the upgrade
  stalled. Recreate accepts a short outage on that pool instead of a stall.
- **`surge`** (default) — rolling upgrade with additional temporary capacity.
  Verify quota and zonal capacity first; on-demand billing or a CUD does not
  guarantee spare capacity. Current settings permit one surge node per zone and
  zero unavailable nodes. Budget for temporary extra nodes during the rollout.
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
bash scripts/gke-upgrade/tests/preflight-tests.sh
bash scripts/gke-upgrade/tests/upgrade-tests.sh
bash scripts/gke-upgrade/tests/terraform-tests.sh
```

The Terraform tests mock providers and remote-state data; the mock apply runs
only in memory. The runner omits credential outputs because the legacy SDK
provider mock cannot synthesize an absent `master_auth` block. The real stack
must additionally pass `terraform validate` and a reviewed live-state plan.
