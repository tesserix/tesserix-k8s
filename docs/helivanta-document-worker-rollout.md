# Helivanta private document worker rollout

Owning story: [helivanta #1105](https://github.com/tesserix/helivanta/issues/1105).
Backend: [draft #1124](https://github.com/tesserix/helivanta/pull/1124).

This change registers `helivanta_document_worker` through CNPG before backend
migration `0008` grants its column-scoped permissions. The role has no LOGIN,
password, memberships or elevated privileges. `inherit: false` is explicit
because the installed CRD defaults inheritance to true; login defaults false.
Rendering and backup tests validate the intended role and preserve existing
cluster/backup wiring. The role has not been applied to the live cluster.

Read-only discovery on 15 October 2026 confirmed active account
`unidevidp@gmail.com`, GCP project `tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace `helivanta`.
CNPG `helivanta-postgres` had two instances and two ready instances, healthy.
Argo's `valuesObject.instances: 2` supplies that production value; this change
does not alter it.

Required ordering before accepting confidential uploads:

1. Review and approve the named CNPG role registration through GitOps; verify
   the actual PostgreSQL role flags and absence of memberships after reconcile.
2. Provision only the isolated `17-helivanta-files` approved resources through
   Atlantis at the reviewed current head. The saved plan has 17 additions and
   zero changes/deletions; no apply has been issued. Do not reuse a stale plan.
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
