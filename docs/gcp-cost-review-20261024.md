# GCP cost review — 24 October 2026

Scope: project `tesseracthub-480811`, billing account
`01C0B7-C8CD85-88B397`, GKE `tesseract-prod-in-gke` in `asia-south1`.
The account has one billing-enabled project, `tesseracthub-480811`; the five
other accessible projects have billing disabled. Only one open billing account
was visible. Total exported usage cost for 1–23 October was **A$1,403.35 net**.
Amounts below are AUD from the billing export through 23 October; monthly figures
are 30-day estimates, not forecasts or the final invoice.

## CUD application and the fixed cost floor

The Compute service subtotal was A$2,711.69 gross, A$1,498.33 credits and
A$1,213.36 net. This is not the entire cloud invoice. Three E2 commitments cover
56 vCPU and 184 GiB RAM and expire in August/September 2029. Recent fixed CPU
and RAM commitment charges total A$32.486/day, about A$975 per 30 days. Running
CPU usage is offset by COMMITTED_USAGE_DISCOUNT credits. Remaining running RAM
charges were approximately A$0.97–1.21/day on 20–22 October.

The six registered e2-standard-8 nodes provide 48 vCPU and 192 GiB RAM. This
indicates unused committed CPU capacity and some memory beyond commitment;
precise utilization varies with node upgrades and instance-hours. Scaling unused
apps down frees shared capacity and removes their running code, but does not
cancel the commitment payments. Do not buy more commitments to solve this bill.
The A$40.39 flexible-CUD net charge in the monthly export occurred only on
1–5 October and is not a current daily expense.

Credits offset covered usage while the commitment fee remains separately billed.
The credit total is not the net saving versus an account with no commitment,
because the gross total also includes commitment fees.

## Service totals

| Service | Net A$ |
|---|---:|
| Compute Engine | 1,213.36 |
| Kubernetes Engine | 77.31 |
| Networking | 55.11 |
| Secret Manager | 27.31 |
| Vertex AI | 18.01 |
| Cloud Storage | 4.09 |
| KMS | 3.57 |
| Artifact Registry | 1.69 |
| Speech | 1.15 |
| Cloud Build | 0.98 |
| Text-to-Speech | 0.51 |
| Cloud DNS | 0.26 |

The other exported services net to zero. Disk and some network SKU charges below
are components of these service totals, not additional amounts to add again.

## Other measured drivers

| Cost | Export-to-date or recent daily amount | Interpretation |
|---|---:|---|
| Persistent disk capacity | A$321.74 to date | Balanced 265.65; standard 31.14; SSD 24.95 |
| GKE management | A$77.31 to date | Separate from E2 usage discounts |
| Cross-zone transfer | A$56.12 to date | Approximately 138–143 GiB/day, A$60/month recently |
| Secret replicas | A$26.28 to date | Retire only after consumer migration and recovery checks |
| NAT data processing | A$0.86–0.99/day | Approximately 14–15 GiB/day |
| NAT gateway | A$0.287/day | Remains independently billable |
| IP address | A$0.171/day | Remains independently billable |
| Public load balancer | A$1.025/day | Shared custom-ingressgateway in istio-ingress |

The disk inventory contained 2,777 GB: 1,971 balanced, 690 standard and 116 SSD.
Five unattached disks totalled 58 GB; attachment status alone does not establish
that they are disposable. They were not approved as part of this migration.

## Changes and next priorities

FE3DR/homechef is parked in GitOps: dedicated app workloads, Temporal, gateways,
tunnel, OCR and poolers are stopped; autoscalers cannot restart them; PostgreSQL
is hibernated; MongoDB is natively paused and its namespaced operator is zero.
Resume instructions are in `fe3dr-park.md`. Parking does not remediate vulnerable
code; update and test it before resuming.

The approved data-volume migration is documented in
`storage-rightsize-20261024.md`: four PostgreSQL data volumes and blog MongoDB to
60Gi, OpenPanel ClickHouse to 120Gi. It reduces provisioned capacity by 540Gi,
approximately A$86/month at observed rates, after the verified original disks were retired.
Temporary copies and recovery snapshots add cost until cleanup. Smaller volumes
and PostgreSQL WAL volumes are unchanged.

Further material savings require lowering charges outside the fixed commitment:

1. Review disk utilization and retention, including ClickHouse system/event logs,
   old backups and recovery snapshots. Keep enough free space for compaction and
   database growth. Verify ownership and restore requirements before deleting
   unattached disks.
2. Measure chatty inter-zone flows and use topology-aware routing for suitable
   stateless traffic. Preserve database replication and failure tolerance. VPC
   flow logs and NAT logs were disabled, so existing billing cannot prove which
   individual app caused every transfer charge; enable scoped sampling only after
   considering logging costs.
3. Audit actual external image and application traffic. Private Google Access is
   enabled. Registry mirroring can reduce external image downloads but does not
   eliminate cross-zone replication, NAT processing or load-balancer charges.
   External image names alone do not prove traffic bypasses a transparent mirror.
4. Audit routing before removing the shared public ingress load balancer. It is
   shared infrastructure, not a dedicated unused FE3DR resource.
5. Continue the existing OpenBao migration for Secret Manager consumers, keeping
   explicit Cloudflare and independent recovery exceptions intact.

There is no evidence that CUD credits are missing. The largest recurring charge
is the contractual commitment, which cannot be removed by stopping pods. Reuse
that paid capacity for other needed apps and avoid new nodes where possible.

At the post-change spot check, six nodes were using 15–49% CPU and 29–50%
memory. All 15 shared deployment readiness baselines matched. These are spot
measurements, not peak-capacity guarantees.

Kubernetes scheduling headroom is tighter than actual utilization: node memory
requests were 71–92% of allocatable capacity. The largest review candidates were
Roamie weather (16Gi requested across two pods, 36Mi working set at the spot
check), Mark8ly PostgreSQL (16Gi requested, 269Mi immediately after restart),
Qdrant (6Gi requested, 206Mi), and NATS (3Gi requested, 85Mi). These readings do
not establish safe limits, especially after a database restart or for cache-heavy
services. The seven-day Cloud Monitoring query returned no matching data, and
both discovered Prometheus services had no endpoints, so historical peaks could
not be verified. Restore a suitable low-cost metrics source, then rightsize
requests against peaks and workload tests before planning node consolidation.
This can free scheduling capacity; committed CPU/RAM charges still remain.

OpenPanel's live post-cutover inspection found 59.45GiB in system diagnostic logs
and approximately 403KiB in active application data parts. The largest tables
were `system.trace_log_0` (42.98GiB), `system.trace_log` (8.03GiB), and
`system.text_log_0` (4.78GiB). Review retired system-log tables and apply the
intended retention policy to existing tables; this helps prevent future disk
growth. Diagnostic history was retained during this migration. Its deletion is
a separate retention decision.

Observed capacity rates were A$0.170812/GiB-month for balanced PD and
A$0.068322/GiB-month for standard PD. The migration removes 480GiB balanced
and 60GiB standard capacity, approximately A$86.09 per billing month before
snapshot overhead. Eight recovery snapshots are retained, including both FE3DR
WAL volumes. Review their retention after confirming recovery requirements. The OpenPanel
source snapshot reports about 185GB stored, versus about 60GiB of live
filesystem data.
