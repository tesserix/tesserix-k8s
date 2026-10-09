# Approved parked-storage retirement — 2026-10-04

The owner approved purging the ten parked observability disks and the two
stopped-VM boot disks identified in the cost review. Target project:
`tesseracthub-480811`; account: `unidevidp@gmail.com`; production context:
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`.

## Exact scope

| Owner / claim | Zone | GiB | Recovery snapshot |
|---|---|---:|---|
| `data-clickhouse-0` | `asia-south1-c` | 100 | `retire-20261004-data-clickhouse-0` |
| `data-clickhouse-1` | `asia-south1-a` | 100 | `retire-20261004-data-clickhouse-1` |
| `data-clickhouse-keeper-0` | `asia-south1-c` | 10 | `retire-20261004-data-clickhouse-keeper-0` |
| `data-clickhouse-keeper-1` | `asia-south1-b` | 10 | `retire-20261004-data-clickhouse-keeper-1` |
| `data-clickhouse-keeper-2` | `asia-south1-a` | 10 | `retire-20261004-data-clickhouse-keeper-2` |
| `data-redpanda-0` | `asia-south1-c` | 80 | `retire-20261004-data-redpanda-0` |
| `data-redpanda-1` | `asia-south1-b` | 80 | `retire-20261004-data-redpanda-1` |
| `data-redpanda-2` | `asia-south1-a` | 80 | `retire-20261004-data-redpanda-2` |
| `queue-otel-gateway-0` | `asia-south1-a` | 40 | `retire-20261004-queue-otel-gateway-0` |
| `queue-otel-gateway-1` | `asia-south1-b` | 40 | `retire-20261004-queue-otel-gateway-1` |
| `win-test-vm` | `asia-south1-a` | 50 | `retire-20261004-win-test-vm` |
| `polymarket-access` | `asia-south1-c` | 50 | `retire-20261004-polymarket-access` |

This covers 550 GiB in `observability` plus two 50-GiB boot disks. The VM names
are `win-test-vm` and `polymarket-access`; their disk names are `win-test-vm` and
`polymarket-access-c`. The VM records remain stopped with their boot disks
detached, preserving configuration without disk-capacity charges. No Terraform
resource for either VM was found in the workspace.

Stockpilot's 120-GiB database/WAL volumes, OpenBao staging, active application
volumes and existing snapshots are excluded. This is a named retirement, not
an expansion of the daily orphan cleaner's eligibility rules.

## Execution guards

1. Capture current PVC/PV/StatefulSet metadata, disk identities and VM
   configuration under `/tmp/tesseract-cost-audit-20261004/storage-retirement/`
   with restricted permissions. Keep VM metadata and recovery captures out of Git.
2. Create snapshots in `asia-south1`. Before any deletion, require each snapshot
   to report `READY` and its `sourceDiskId` to equal the captured source disk ID.
3. Keep all four observability StatefulSets at zero and verify no pod references
   the target claims. Set production Redpanda and OTel `persistence.retainedReplicas`
   to zero through GitOps. This removes their five explicit expansion claims from
   desired state; `Prune=false,Delete=false` prevents automatic premature deletion.
4. After parent/child reconciliation, recheck original PVC/PV UIDs, binding
   references, CSI disk handles and absence of disk users. Use Retain while
   removing claims so the backing disks remain until the explicit disk purge.
   Remove only the approved claim/PV objects and their captured disks.
5. Recheck both VM identities and `TERMINATED` state, detach only their captured
   boot disks, verify no disk users, then delete only those disks.
6. Verify the twelve disk identities are absent, no observability claim is
   recreated, workloads remain parked and application readiness is unchanged.

## Recovery

**Do not unpark by changing replica counts alone after this retirement.** The
old telemetry data and VM operating systems are available through the named
snapshots, rather than the deleted disks.

For Kubernetes recovery, keep workloads at zero. Recreate each disk from its
snapshot using the captured original name, zone and disk type. Recreate the
captured PV and PVC, preserving CSI handles, node affinity, capacity and claim
names. Remove server-generated metadata/status and old claim UID/resourceVersion
from the recovery manifests. Verify bindings before enabling workloads. Restore
Redpanda/OTel retainedReplicas only after disks and claims are recovered. Restore
Keeper, ClickHouse, schema and telemetry consumers in dependency order.

For VM recovery, create the original boot-disk name from its snapshot in the
recorded zone, then attach it as the boot disk to the retained stopped VM. Use
captured instance configuration for the original device/boot settings. Starting
VMs or restoring monitoring is a separate approved action.

## Savings

October 2's complete AUD billing day charged AUD 3.03051 for the ten
observability disks and AUD 0.551 for the two VM disks: gross avoided capacity
charges of about **AUD 107.45 per 30 days** after deletion. Recovery snapshots
continue to incur storage charges; deduct those from the gross savings. Report
actual snapshot bytes and billing once available. No CUD cancellation or new
compute savings are included.
