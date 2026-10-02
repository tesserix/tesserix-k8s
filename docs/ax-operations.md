# AX operations

AX is isolated in `ax-system`. Desired state is owned by the `ax` and `ax-valkey`
Argo Applications; `ax-foundation` owns the namespace and secret bootstrap
identities. Terraform stack `16-ax` owns GCS and Workload Identity bindings.
Existing Kagent and `ate.dev` resources are not part of this release.

## Capacity and availability

Two API replicas and two gVisor workers are the initial bounded capacity. The
GKE cluster stays on the existing main pool with a seven-node maximum and zero
surge. No GPU or separate gVisor pool is enabled. Workers each request 250m CPU
and 512Mi and are limited to two CPUs and 2Gi. Worker admission and latency must
be measured before increasing concurrency. Extra persistent storage initially
consists of two 10Gi PostgreSQL volumes and three 2Gi Valkey volumes, plus GCS
snapshot/backup usage. These add storage charges; no additional node pool is
provisioned. PVCs use a Retain storage class.

## Access and secrets

The AX API is a ClusterIP with no ingress. Use `ax --context
 gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke` from an authorized
workstation; the CLI opens a local Kubernetes port-forward. Anyone authorized
to forward this service can administer AX, so namespace RBAC is the API access
boundary. Do not publish the service without adding application authentication.

The create-only bootstrap Job writes product-prefixed secrets to
`kv/ax-system/production/ax-*` in OpenBao with CAS=0. Existing values are retained.
ESO materializes only the required fields. Signing pools are never mounted into
the AX server or workers. Substrate uses the external GKE issuer, audience
`api.ax-system.svc`, stable certificate APIs and its own CA pools. No provider
keys belong in task YAML, Git, logs, command arguments, or workstation shell rc.

AX uses the existing `ai-gateway.agentgateway-system` Vertex route with
`gemini-2.5-flash`. Only the AX server and AX egress service accounts are
admitted, through ambient mTLS, and only to `/vertex/*`. Provider credentials
remain at the gateway. Model failures return errors instead of synthesized
success. Each actor initially permits egress only to the gateway hostname;
additional Git/package hosts require an explicit actor egress policy.

The CA pools expire one year after initial creation. A daily certificate-only check alerts through failed Jobs. Also inspect certificate-only
material monthly and renew at least 30 days before expiry using overlapping
trusted roots; never rerun bootstrap expecting rotation. Keep OpenBao's tested
independent recovery and GCS backup path intact.

## Backups and recovery

Valkey is authenticated, uses AOF with every-second fsync, disables eviction,
and requires a current replica for writes. Three Sentinels elect the primary;
two HAProxy replicas route writes. A backup Job takes an RDB every 15 minutes to
`gs://tesseracthub-480811-ax-backups/valkey/`. PostgreSQL continuously archives WAL
and takes a base backup every six hours in the same bucket under `postgres/`.
The intended RPO is 15 minutes for AX metadata; verify measured recovery lag.
The initial RTO target is 60 minutes and is unproven until a timed restore passes.
Backups have 30-day retention, object versioning and seven-day soft deletion.
Active actor snapshots have no age-based deletion policy.

Restore only into isolated `ax-restore` resources first. Give the restore KSA
read-only backup access, restore the selected Valkey RDB and verify task metadata,
then restore a CNPG clone from a base backup plus WAL and verify actor/template
records. A successful upload or checksum alone is not a restore test. Record
results and durations before claiming disaster recovery readiness.

## Upgrade and rollback

Review source pins, patches, licenses, SBOMs and image digests in `scripts/ax`.
Run the affected upstream Go suites, repository render tests, Helm lint and
server-side dry-run checks. Promote through a PR and verify Argo health, an AX
task, suspend/resume and a restore. Do not update the legacy shared Substrate as
part of an AX release. Revert the runtime image/config commit for a compatible
rollback; never prune state, buckets, CAs or CRDs as an image rollback. Database
schema changes require a separate reviewed compatibility and recovery plan.

## Acceptance status

Foundation PR #1279 was applied by Atlantis and merged. Runtime deployment and
end-to-end acceptance are still in progress; this document does not assert they
have completed.

## Reviewed runtime privileges

Trivy flags the dedicated atelet node agent's privileged/root execution,
`/dev` and `/var/lib/kubelet/device-plugins` host mounts, and host port 18085.
These are required by the upstream device-plugin/gVisor architecture. The
agent is limited to the existing main pool, uses a separate AX host root, has
bounded resources and a read-only image filesystem. It must be treated as
trusted node-level software. Untrusted task code runs inside gVisor, not in
this agent process. The controller can mutate network policies only inside
`ax-system`, which is required to manage workers. These findings are retained
for review; ordinary control-plane containers run non-root and drop all
capabilities. This is not an appropriate runtime for an untrusted cluster admin.
