# Telemetry storage recovery — pending production approval

Kora OpenBao acceptance found intermittent trace delivery. On 2026-09-27,
both OTel gateway replicas reported full persistent queues. Redpanda reported
node 0 at high disk usage: approximately 35 GiB used on a 40 GiB volume,
with no down brokers or under-replicated partitions. One exact synthetic Kora
span reached Langfuse v4, but a repeat did not. Track the incident in #1197;
keep migration #1191 open and retain the GCP originals.

## Proposed recovery

Expand existing Redpanda claims `data-redpanda-{0,1,2}` from 40 to 80 GiB and
existing gateway claims `queue-otel-gateway-{0,1}` from 20 to 40 GiB. This adds
160 GiB of provisioned GCP disk capacity, billed at the applicable disk tariff.
Both live StorageClasses support online expansion. This is recovery headroom;
telemetry rates and retention still need measurement for long-term sizing.

The existing Argo applications manage explicit PVC manifests for the same names.
Their immutable StatefulSet claim templates remain unchanged. Rendering confirms
that every existing resource is unchanged: no pod restart, StatefulSet replacement,
queue deletion, retention change or topic truncation is requested. New claims are
protected with `Prune=false,Delete=false`; do not force-replace them. The separate
`expandedSize` value must never be reduced below the live allocated capacity.
Keep it set if replicas change, so every desired ordinal receives the larger claim.

Server-side dry runs must preserve each existing bound PV and pass before approval.
Private pre-change PVC/PV metadata is captured at
`/tmp/kora-telemetry-storage-evidence`; no telemetry payloads are captured.
This is metadata for recovery, not a backup of queued telemetry.

## Approval and acceptance

The PR remains unmerged until the user explicitly approves production storage
expansion. Argo reconciles the five PVCs after merge. A disk expansion cannot be
rolled back by shrinking: keep expanded claims if application code is reverted.
Do not use a Git revert that requests a smaller size.

After approval, verify all five claims and filesystems reach their requested size,
Redpanda clears high-disk health, collector queues drain without new disk/export
errors, and repeated synthetic Kora spans arrive through both gateway replicas at
Langfuse's `/api/public/v2/observations` endpoint. The v4 events-only deployment
intentionally rejects the legacy traces endpoint. Record observed delivery latency;
no telemetry latency SLO has been established by this repair.

If errors persist, inspect throughput, topic retention and persistent-queue
compaction. Expansion does not authorize deleting queue contents or shortening
retention. Kora GCP-source deletion and the next product remain gated on acceptance.
