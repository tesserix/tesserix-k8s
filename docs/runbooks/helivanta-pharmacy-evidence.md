# Pharmacy prescription-image worker (#1406)

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
