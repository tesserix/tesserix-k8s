# GKE general compute and CUD coverage

Project: `tesseracthub-480811`. Region: `asia-south1`.
Cluster: `tesseract-prod-in-gke`. Reviewed 2026-10-25.

## Scheduling and permanent ownership

`general-e2` replaces the empty `models-e2` pool because GKE pool names and
maximum pods per node cannot be edited in place. It is an on-demand
`e2-standard-8` pool with no taints, no model-only admission restriction,
110 pods per node, and a general workload label. Pod resource requests,
volume zones, affinity, architecture and Kubernetes authorization still apply.
The retained Seamless chart no longer selects the former pool or requires its
toleration. Its existing disabled status remains unchanged.

Terraform stack `terraform-new/stacks/04-gke` owns the replacement and removal.
The shared production tfvars cap `optimized-v2` at six nodes; `general-e2`
has one node. Both pools use zero surge for future upgrades. This trades one
temporarily unavailable node during upgrades for avoiding extra surge capacity.
GPU and sandbox pools stay at zero nodes with autoscaling disabled; enabling
these requires a separate cost and commitment review.

## Existing commitments (no new purchase)

| Existing name | vCPU | RAM GiB | Auto-renew | Term ends |
| --- | ---: | ---: | --- | --- |
| commitment-20260925-133025 | 18 | 0 | false | 2029-09-26 |
| commitment-20260925-133159 | 8 | 64 | true | 2029-09-26 |
| e2-cud-asia-south1 | 30 | 120 | true | 2029-08-30 |
| e2-ram-gap-40g-20261024 | 0 | 40 | false | 2029-10-24 |
| **Total** | **56** | **224** | | |

All four are active three-year `GENERAL_PURPOSE_E2` commitments in
`asia-south1`. Terraform imports existing purchases with destruction protection;
resource order preserves the API's CPU-before-memory ordering to avoid false
replacement plans. Preserve the current renewal settings unless separately
reviewed. The CPU and RAM quantities cover seven `e2-standard-8` instances.
The production plan rejects pool maxima exceeding these quantities. Lower
autoscaled usage can leave prepaid capacity unused; coverage is not utilization.
A commitment does not reserve capacity.

Source documentation:
- https://cloud.google.com/compute/docs/instances/committed-use-discounts-overview
- https://cloud.google.com/compute/docs/instances/signing-up-committed-use-discounts
- https://cloud.google.com/kubernetes-engine/docs/how-to/node-pools

E2 regional resource commitments cover eligible CPU and RAM, independent of pool
names or Kubernetes labels. They do not cover Persistent Disk, snapshots, cluster
management fees, networking, public IPs, GPUs, or unrelated services. Do not buy
more commitments to disguise idle VMs. Commitments cannot normally be cancelled
or deleted before expiry. Confirm billing-account sharing and hourly credits when
adding other projects or changing machine families.

## Evidence and costs

Initial discovery found eight running E2 standard-8 VMs but only seven registered
Kubernetes nodes. The extra VM
`gke-tesseract-prod-in-gk-optimized-v2-aec7d08d-3mxg` had no node, pods,
VolumeAttachments or data disks. After explicit approval, it was removed using
the owning managed group's delete-instances operation, reducing that group's
target from three to two rather than allowing it to recreate the VM.
The remaining seven running VMs exactly match 56 vCPU and 224 GiB.

Recovery metadata, pool description, pre-change Terraform state, managed-group
template and membership, and billing extracts are stored locally under
`/tmp/gke-general-compute-evidence` with restricted permissions. They are not
committed because state and instance metadata may contain sensitive information.
The template and captured pool configuration allow recreation; no application
data disks were removed. This temporary directory is not a durable backup.

Billing account: `01C0B7-C8CD85-88B397`.
Export: `billing_export.gcp_billing_export_v1_01C0B7_C8CD85_88B397`.
Currency: AUD. Export lag means capacity verification precedes invoice proof.
On 2026-10-25's exported usage, E2 CPU and RAM credits offset 87.5% of gross
usage charges, consistent with seven covered machines out of eight. Observed
on-demand rates imply approximately A$131 per 30 days of CPU/RAM avoided by
removing one continuously running extra machine, plus boot disk savings.
This estimate is not a bill guarantee.

For 2026-10-18 through 2026-10-24, the top exported net services were Compute
Engine A$353.43, GKE A$23.91, Networking A$17.59, Secret Manager A$8.53,
and Vertex AI A$1.77. On October 24, balanced persistent disks alone cost A$8.54;
storage reclamation needs a separate owner/data-retention review and approval.
CUDs remain payable when workloads shrink: reducing below seven nodes does not
automatically lower the committed CPU/RAM bill.

## Verification and recovery

Run `bash scripts/gke-upgrade/tests/terraform-tests.sh`, Terraform validation
and formatting, and `helm lint charts/apps/roamie-seamless`.
Inspect a scoped Terraform plan before applying: expected actions are four
commitment imports without purchase/update, creation of `general-e2`, deletion
of empty `models-e2`, and only the optimized pool autoscaling maximum reduction.
Use scoped planning to avoid unrelated cluster/configuration drift, then inspect
the remaining full plan separately.

Before deleting the old pool, verify again that only system DaemonSets and the
node's mirror pod run there. After apply, require seven Ready nodes, no taints
on general compute, no pending ordinary pods attributable to pool isolation,
and seven running E2 standard-8 VMs. Existing workloads need not move immediately;
normal scheduling can use the new pool. Review hourly CPU/RAM billing credits
after the export catches up. Recreating `models-e2` requires restoring its
captured configuration and approval; prefer repairing the general pool rather
than restoring model isolation.
