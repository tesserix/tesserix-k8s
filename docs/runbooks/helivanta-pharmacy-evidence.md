# Pharmacy prescription-image worker (#1406)

## Synthetic user credentials

The production acceptance seed uses the separate OpenBao role
`seed-helivanta-pharmacy-users-production`. It is bound only to the existing
`helivanta/helivanta-pharmacy-evidence-secret-seed` bootstrap service account,
with audience `openbao` and a five-minute maximum token lifetime. Runtime API
and worker readers do not acquire this writer role.

The role can create and read only
`helivanta/production/helivanta-pharmacy-seed-users`, plus read its metadata.
It has no overwrite, delete or list authority. Create the retained synthetic
user intent and generated passwords with KV v2 CAS 0 before creating identities;
resume the same intent on retry. Existing or deleted history requires explicit
recovery rather than replacement. Keep passwords, identity bindings and sessions
out of Git and logs, and revoke the short-lived OpenBao token after use.

Create the TEST human identities through the identity owner's authenticated
API, then use Helivanta's Global API for membership, outlet grants and pharmacy
records. Seed credentials do not grant clinical authority or approve licences.

## Worker rollout

## Verified deployment evidence (2026-11-01 UTC)

Preparation/IAM was delivered by [#1615](https://github.com/tesserix/tesserix-k8s/pull/1615).
The create-only initializer was delivered by [#1617](https://github.com/tesserix/tesserix-k8s/pull/1617)
and retried after policy bootstrap by [#1618](https://github.com/tesserix/tesserix-k8s/pull/1618).
Job `helivanta-pharmacy-evidence-secret-seed-bc32fc3f` succeeded. Its predecessor
exhausted retries before OpenBao bootstrap finished; a selective Argo prune
removed only that obsolete failed Job. No secret values were read.

[#1620](https://github.com/tesserix/tesserix-k8s/pull/1620) activated processing.
Both API/PostgreSQL Argo Applications were Synced/Healthy; the dedicated worker
had two updated, available replicas. Its ExternalSecret reported
`Ready=True, SecretSynced`. A read-only `pg_roles`/`pg_auth_members` query verified
LOGIN, NOINHERIT, no superuser/BYPASSRLS/CREATEDB/CREATEROLE and zero memberships.
API and worker used the same promoted artifact
`02b1e2b7e5a0fb9fa1fdbc65e449ca322cfda56a`. ClamAV reported engine 1.5.4,
definitions 28171 updated 2026-11-01 06:27:34 UTC (under 24 hours old at check).
These are point-in-time observations, not permanent readiness guarantees.

Synthetic owner-API scan/release/rejection/recovery and disclosure acceptance
remains pending a designated test tenant/outlet. These deployment observations
do not close #1406 or authorize prescription-image enforcement PR
[helivanta #1477](https://github.com/tesserix/helivanta/pull/1477).
Alert evaluation and delivery have not been verified.

This prepares a separate worker for retained prescription pages. It follows the
reviewed Supply evidence release sequence; clean scanning is not prescription,
drug, pharmacist or licence approval. Application #1467 restores the existing
requirement for released prescription-image evidence before a new G/H/H1 sale.

## Scope and release order

The worker KSA is `helivanta-pharmacy-evidence-worker` in `helivanta`. Its existing
CNPG role is `helivanta_pharmacy_evidence_worker`; defaults retain NOLOGIN,
NOINHERIT, no elevated attributes or memberships. No production activation is
included in preparation defaults.

1. Review the additive stack-17 plan. Its three object IAM grants permit GET on
   quarantine and CREATE/GET on released objects, only under
   `t/<tenant>/o/pharmacy_outlet/...`. No list, overwrite, delete, organisation,
   patient or staff access is introduced. Apply only that reviewed plan.
2. Use the dedicated create-only GitOps initializer (the established Helivanta
   emergency/privacy pattern) to generate a separate random URI-safe password.
   It stores only `password` at
   `helivanta/production/helivanta-pharmacy-evidence-worker-db-password` in
   OpenBao. Never read/print credentials or put them in Git or command URLs.
   The exact-path reader is bound to the one KSA/namespace. The initializer has
   only create on that data path and read on its metadata, checks its own
   capabilities, uses CAS 0, refuses deleted/destroyed history and revokes its
   five-minute token. It cannot read or replace an existing credential.
   Enable `pharmacyEvidenceWorker.seed.enabled` through GitOps; require Job
   completion before enabling login/ESO. If policy reconciliation was delayed,
   use a reviewed `seed.podTemplateRevision` change to retry the same create-only
   operation. No root or operational credential needs to be read or copied.
3. Through reviewed GitOps activation, enable
   `pharmacyEvidenceWorker.credentials.enabled` and `pharmacyEvidenceWorker.login`
   in the owning PostgreSQL Application. Verify ESO Ready, two healthy database
   instances and the exact non-inheriting role attributes without dumping secrets.
4. Activate `pharmacyEvidence.enabled` in the owning API Application after the
   worker image and existing `0016_pharmacy` worker privileges are present.
   Private document uploads/processing must already be enabled. The worker uses
   the same promoted API artifact, a separate task queue and only its own runtime
   credential. It receives no API/owner/system DSN, NATS or session secrets.
5. Verify two ready workers, probes, scanner definitions younger than 24h,
   bounded Temporal workflow execution and no content/secrets in logs/history.
   Upload synthetic pages through the normal owner API; prove clean release and
   audited download, rejected content and retry after dependency failure.
   Verify cross-tenant/outlet denial, denied non-pharmacy paths, denied list and
   write escalation. Retain evidence of which checks were live versus local.
6. Only after worker acceptance, deploy application #1467 enforcement. Without
   released evidence the new sale correctly refuses; historical invoices replay
   unchanged. Do not fabricate available rows to bypass the pipeline.

All Kubernetes changes use GitOps. Monitoring rules are delivered, but alert
evaluation/delivery must be independently verified; do not infer functioning
monitoring from a PrometheusRule if the monitoring platform remains suspended.

Rollback stops new acceptance and disables the worker through GitOps, preserves
documents and lifecycle/audit history, and leaves unavailable scans explicit.
Never grant the API the worker role or release documents manually as recovery.
