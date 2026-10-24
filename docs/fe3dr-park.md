# FE3DR suspended operation

Requested on 2026-10-24: keep FE3DR offline until explicitly resumed.
These changes are prepared locally; deployment must be verified separately.

## Scope

- Zero replicas for the API, Temporal worker/server, BFF, customer web apps,
  vendor portal, MCP gateway, dedicated OCR workers/APIs, Cloudflare connector,
  ingress gateway and namespace waypoint.
- Disable FE3DR KEDA/HPA resources so autoscaling cannot restart workloads.
- Hibernate `homechef-postgres` using `cnpg.io/hibernation: on`. Keep its Cluster,
  PVCs, network policy and backup configuration. Keep both Pooler resources with
  zero instances; suspend scheduled backups and autoheal while offline.
- Pause the Percona MongoDB cluster using `spec.pause: true`. Keep its volumes
  and the namespaced operator running so pause/resume remains reconciled.
- Suspend database bootstrap and the orphaned legacy Keycloak bootstrap CronJob.
  Adopt the latter back into GitOps with a suspended no-op job: its original chart
  no longer exists and Keycloak is retired. Do not restore that legacy job.
- Disable FE3DR OCR migration/credential seed hooks while suspended. Retain
  ExternalSecrets and identities so resuming does not require credential recovery.

Shared global/infra PostgreSQL, NATS, Valkey, OpenBao, identity, support-platform,
the CNPG operator and other products remain running. The current FE3DR API uses
the shared global database; hibernating the old dedicated cluster does not stop
the shared database. Existing GCS backup objects and all PVCs remain intact.
Scheduled backups cannot run while a database is stopped; existing GCS lifecycle
retention still applies. Retained disks are the primary persistent copy during
an extended pause.

## Deployment and verification

Use the owning `tesserix/tesserix-k8s` GitOps repository. Do not apply ad-hoc
replica changes: Argo CD, KEDA and database operators would reconcile them away.
The production target is project `tesseracthub-480811`, cluster
`tesseract-prod-in-gke`, region `asia-south1`, namespaces `homechef`,
`document-intelligence`, `cloudflared` and `istio-ingress`.

After the reviewed change is merged, verify all affected Argo applications use
the new revision, all dedicated runtime deployments show zero desired replicas,
FE3DR HPAs/ScaledObjects are absent, PostgreSQL reports hibernation, MongoDB
reports paused, and all three homechef CronJobs are suspended. The MongoDB
operator is intentionally the only remaining dedicated management deployment.
Check shared services remain healthy and confirm PVC names/UIDs are unchanged.
Do not claim bill savings from freed RAM alone: paid commitments remain fixed.

Local non-secret before-state metadata is captured at
`/tmp/fe3dr-park-20261024/before-metadata.json` for this session. Git baseline:
`74f79d299cda3e21ae6a771d24e6c877f4a86b36`. This metadata is not a data backup.

## Resume

Only on an explicit request: reverse the parking changes through GitOps, keeping
the retired identity bootstrap suspended. Resume databases first (`hibernate:
false`, MongoDB `pause: false`), verify primary/replica health and backup/WAL
archiving, then restore poolers, Temporal, workers, APIs, frontends and ingress.
Restore OCR seed/migration settings deliberately and verify migrations before
serving traffic. Check expired Temporal timers and queued notifications before
restarting workers; retained workflows may resume immediately.

## Cost findings

Billing export through 2026-10-23 (AUD, usage-date basis, subject to late charges):

| Item | October cost |
| --- | ---: |
| E2 three-year CPU commitments | 512.61 |
| E2 three-year RAM commitments | 225.55 |
| Flexible three-year compute CUD, net | 40.39 |
| Balanced / standard / SSD persistent disk capacity | 321.74 |
| Regional Kubernetes cluster | 77.31 |
| Inter-zone transfer | 56.12 |
| E2 running CPU/RAM remaining after credits | 39.51 |

Compute Engine totals 1,213.36 net against 2,711.69 gross. Three resource-based
commitments cover 56 vCPUs and 184 GiB RAM through August/September 2029.
Six registered e2-standard-8 workers provide 48 vCPUs and 192 GiB RAM; an extra
VM appeared in the Compute inventory during discovery, so reconcile actual
instance-hours and commitment utilization before assigning exact wasted cost.
Review the separate Flexible CUD utilization too; its presence alone does not
prove overlapping or wasted coverage.

Project disks total 2,777 GB (1,971 balanced, 690 standard, 116 SSD). Five disks,
58 GB total, were unattached at discovery; unattached does not mean disposable.
Database/PVC ownership, restore requirements and retention must be checked before
any separate deletion proposal. FE3DR shutdown frees capacity for other products;
significant further cash savings need storage reclamation and avoiding new
uncommitted compute, rather than shrinking below already-paid commitments.

The namespaced MongoDB operator is also parked at zero after the database reports
`paused`. Restore its replicaCount to 1 before unpausing MongoDB.
