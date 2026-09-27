# Telemetry storage recovery

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

The user approved production storage expansion on 2026-09-27. PR #1198 merged
as `4d451d14`, and Argo reconciled all five PVCs. A disk expansion cannot be
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

## Verified recovery — 2026-09-27

All three broker claims reached 80 GiB and both gateway claims reached 40 GiB,
with no remaining resize conditions. All five Pod UIDs stayed unchanged and all
five pods remained Ready. Both Argo applications are Synced/Healthy. Redpanda
reports Healthy with no high-disk nodes or under-replicated partitions; broker 0
filesystem usage fell from 88% to 44% after expansion.

Six exact synthetic spans (three through each gateway) reached Langfuse v4 in
6.81–10.78 seconds. A further span sent from the running Kora agents pod also
arrived. AI queues are empty and the AI consumer group is Stable with zero lag.
No disk-full or export-timeout messages appeared in the post-expansion check.
The older metrics queue on gateway 0 is still draining: 4,081 to 4,014 batches
between samples. Do not claim the historical backlog has fully drained; keep
#1197 open for backlog and capacity follow-up.

CI: 529 tests and 48 subtests passed, four pre-existing quarantines unchanged;
chart lint, template validation, Argo validation and security scans passed.
Private evidence includes expanded claim state, pre-expansion pod identities,
metrics samples and six trace receipts in `/tmp/kora-telemetry-storage-evidence`.
