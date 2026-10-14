# Helivanta private document worker rollout

Owning story: [helivanta #1105](https://github.com/tesserix/helivanta/issues/1105).
Backend: [draft #1124](https://github.com/tesserix/helivanta/pull/1124).

This change registers `helivanta_document_worker` through CNPG before backend
migration `0008` grants its column-scoped permissions. The role has no LOGIN,
password, memberships or elevated privileges. `inherit: false` is explicit
because the installed CRD defaults inheritance to true; login defaults false.
Rendering and backup tests validate the intended role and preserve existing
cluster/backup wiring. The role is now registered in the live cluster. PostgreSQL
confirms NOLOGIN, NOINHERIT, no elevated privileges and zero memberships.

Read-only discovery on 15 October 2026 confirmed active account
`unidevidp@gmail.com`, GCP project `tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `helivanta`.
CNPG `helivanta-postgres` had two instances and two ready instances, healthy.
Argo's `valuesObject.instances: 2` supplies that production value; this change
does not alter it.

Required ordering before accepting confidential uploads:

1. Review and approve the named CNPG role registration through GitOps; verify
   the actual PostgreSQL role flags and absence of memberships after reconcile.
2. The isolated `17-helivanta-files` resources were approved and applied through
   Atlantis; [PR #1414](https://github.com/tesserix/tesserix-k8s/pull/1414) merged.
   Initial custom-role propagation blocked six grants after 11 resources were
   created. A refreshed six-addition plan then applied successfully:
   [apply evidence](https://github.com/tesserix/tesserix-k8s/pull/1414#issuecomment-6174222813).
   GCP inspection verifies all four regional buckets have enforced public-access
   prevention, uniform access, CMEK, versioning and seven-day soft deletion.
   GCS also seeded legacy project grants; the follow-up removes these through
   16 authoritative empty role bindings. That correction needs its own approved
   plan. It preserves workload grants and does not alter inherited project IAM.
3. Prepare a separate OpenBao worker credential and namespace-bound reader,
   its CNPG basic-auth secret and reviewed LOGIN activation. Neither the API
   owner/system DSNs nor unrelated tenant credentials belong in the worker.
4. Apply the additive workforce migration through the owning release hook only
   after the role exists. Verify forced RLS, column grants and constrained
   audit/outbox inserts against CNPG using synthetic scope identifiers.
5. Review scanner/worker workloads, dedicated `helivanta-document-worker` KSA,
   mesh/network policies, resource/quota fit, probes, graceful shutdown,
   current definitions and failure/backlog alerts. Use `/app/document-worker`
   from the same reusable API artifact, not a separate unreviewed image.
6. Enable API bucket/Temporal configuration only after real GCS workload-identity
   acceptance and local API/CNPG/browser tests pass. Complete generated UI
   contracts and file management before claiming story acceptance.
7. Deploy the approved exact-source artifacts through Kargo/Argo and verify
   synthetic live upload, rejection, release, authorized download, retry,
   revocation and cross-tenant/hospital denial. Only then close the story.

The current PR is not an approval to activate credentials, migrate the live
database, deploy workers or enable uploads. Production operations require the
specific approval stated in the working agreements. Rollback disables new
upload acceptance and restores the prior workload while retaining confidential
metadata and immutable objects; no destructive cleanup is part of this slice.

## Prepared runtime IaC

`helivanta-api` carries a disabled `documents.enabled` switch. When approved and
enabled, it configures the existing API producer, two workers using the same API
artifact, and one digest-pinned ClamAV 1.5.4 scanner. The scanner uses the existing
third-party mirror workflow and in-region GAR pull-through registry; verify its
published digest before activation. Recreate deployment pauses
processing during scanner replacement and definition loading. Files remain
quarantined and unavailable. The scanner has no credentials, public route or
persistent customer storage; definitions and scan data use bounded volumes.

The worker receives only its runtime DSN, no API/owner/system credentials. Its
OpenBao reader is bound to `helivanta/helivanta-document-worker`, has a 15-minute
token lifetime and reads exactly
`kv/data/helivanta/production/helivanta-document-worker-db-password`.
Credential projection and LOGIN are separate disabled PostgreSQL chart switches:
`documentWorker.credentials.enabled` and `documentWorker.login`. LOGIN without
credential projection fails rendering. Provision a cryptographically random,
URI-safe credential through the approved secret-service writer, using the
`password` property. Never print it or put it in Git.

Existing namespace-wide ingress excludes scanner and worker, so additive
NetworkPolicies cannot bypass scanner isolation. Only the worker can call
ClamAV over mTLS. Metadata-server access is explicit for API/worker, absent for
scanner. Sidecars have resource bounds and an Istiod egress path. Temporal admits
the exact two service accounts on frontend port 7233 and registers
`helivanta-documents-prod` idempotently. Shared Temporal has no namespace RBAC:
trusted platform clients are not isolated from each other by namespace names.
Histories contain opaque ownership IDs, attempts and statuses, never file bytes,
names or staff/patient payloads.

Observed namespace limits usage was 5.5 CPU / 7Gi. Prepared quota of 12 CPU /
16Gi covers workers, scanner, five sidecars, concurrent API/worker surges and the
migration hook. Requests remain 4 CPU / 6Gi. These are admission ceilings, not
reserved resources or measured load capacity. The scanner image is amd64-only;
observed GKE nodes are amd64 and its architecture selector is explicit.

Alerts and [the runbook](runbooks/helivanta-document-processing.md) are prepared.
Current Prometheus replicas are **zero**: live alert evaluation and delivery
are not proved. Monitoring restoration needs its own reviewed operational
change. Shared Temporal namespace authorization and automatic terminal-failure
or backlog alerting are not claimed by this slice.

## Verification

New render tests failed before implementation, then passed. The affected suite
covers restricted credentials, activation guards, unchanged disabled API,
shared artifact, scanner bounds, mTLS identity, NetworkPolicy bypass prevention,
quota and alert ownership. Existing identity, backup, Temporal and Atlantis graph
checks pass alongside them. Terraform mock plan tests and offline validation
pass. Real GCP inspection is separate from mocked provider proof; actual object
access under workload identity remains pending.

Actual isolated ClamAV 1.5.4 passed benign, EICAR and compressed-EICAR checks
with the rendered config, UID 100/GID 101, read-only filesystem, dropped
capabilities, no-new-privileges, 3Gi memory and one CPU. Definitions were dated
14 October 2026. This proves local scanner behavior, not production mesh,
automatic definition updates, workload identity or complete story acceptance.
