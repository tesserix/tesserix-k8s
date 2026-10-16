# PharmaConnect private licence evidence activation

Story: tesserix/helivanta#1135; epic: tesserix/helivanta#1133.
Application implementation: `feat/1135-licence-evidence`.

Chart defaults remain disabled; production activation is explicit through the
owning Application values.

## Production status: 2026-10-16

Infrastructure PRs #1429, #1430 and #1431 are merged. The organisation-only GCS
bindings were applied through Atlantis. OpenBao credential projection is Ready;
the separate CNPG role has LOGIN, NOINHERIT, no elevated attributes and no
memberships. Both PostgreSQL instances and both Supply workers are Ready.
Application PR tesserix/helivanta#1165 and migration `0003_supply` are deployed on
image commit `faa2c6ff36e9a3014d84b395b03553f67b62081b`.

Synthetic production UI acceptance exposed a shared outbox policy referencing
`workforce_documents`: PostgreSQL checks that subquery's permissions even when
its CASE branch is not selected. The Supply worker correctly lacks HR access,
so completion cannot commit and the evidence stays unavailable. Do not grant
clinical permissions to resolve this error.

Repair PR tesserix/helivanta#1166 appends
`0018_workforce_worker_outbox_scope`, moving the existing HR checks into a
role-specific restrictive policy while retaining both workers' boundaries.
That new production migration and rollout await explicit approval. Verify the
full registry regression, then live synthetic scan, download, replay and
revocation after the approved release. Download/revocation acceptance and wider
licence verification are not complete. If bounded workflow retries have ended,
replay the synthetic workflow through the approved Temporal recovery procedure;
do not update lifecycle rows or provenance by hand.

## Approved release sequence

1. Review the exact app and infrastructure PRs, Terraform plan and local test
   evidence. Confirm `unidevidp@gmail.com`, project `tesseracthub-480811`, context
   `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, namespace
   `helivanta`, CNPG `helivanta-postgres` with two healthy instances.
2. Obtain specific approval for the new CNPG role, OpenBao credential/reader,
   GCS bindings, application migration and worker rollout. GitOps owns all
   Kubernetes changes; do not patch running workloads.
3. Merge the infrastructure preparation: CNPG registers
   `helivanta_supply_evidence_worker` without LOGIN, inheritance, memberships,
   BYPASSRLS, SUPERUSER, CREATEDB or CREATEROLE. Its separate KSA is
   `helivanta-supply-evidence-worker`. Confirm role existence before the app hook.
4. Apply only the reviewed additive stack-17 Terraform plan. The three new GCS
   bindings give this KSA GET on quarantine, CREATE/GET on released objects,
   bounded to `t/<tenant>/o/organisation/...` by IAM conditions. Do not destroy or
   replace buckets, keys, existing bindings or data. The read role excludes list.
5. Generate a cryptographically random URI-safe password with the approved
   secret-service writer. Store only the `password` property at
   `helivanta/production/helivanta-supply-evidence-worker-db-password` in OpenBao.
   Do not print, put in Git, reuse the HR password or pass a credential in a URL.
   The new 15-minute reader is bound to the exact KSA/namespace and exact path.
6. Through a reviewed GitOps activation, set PostgreSQL
   `supplyEvidenceWorker.credentials.enabled=true` and `supplyEvidenceWorker.login=true`.
   Confirm ESO Ready and the exact NOINHERIT/non-elevated role. Verify credentials
   only through authentication outcomes; never dump Secret values.
7. Merge the app after local/hosted tests pass. Its existing pre-upgrade hook
   applies `0003_supply`, including forced RLS, immutable source-revision FK,
   column-scoped worker privileges and restrictive audit/outbox policies.
   API credentials and worker credentials must both fail unauthorized transitions.
8. After the exact image is available through Kargo, set API
   `supplyEvidence.enabled=true` through GitOps. The worker runs two replicas of
   the same promoted API artifact using `/app/supply-evidence-worker`. It shares
   the scanner and Temporal frontend, with a separate task queue and database/
   Kubernetes identity. It receives no NATS, owner/system DB or session secrets.
9. Verify IAM with synthetic organisation objects and denied staff/patient keys,
   denied list/overwrite/delete, scanner definitions younger than 24 hours,
   healthy probes, clean API/worker logs and no secret or document content in
   Temporal histories. Test actual synthetic browser upload, queued state,
   clean download, rejected file, retry, revocation and cross-tenant/party denial.
   Record exact image, migration, Kargo and Argo evidence before acceptance.

The new worker reuses the established worker resource envelope and admission
settings. Check namespace ResourceQuota and simultaneous rolling surges before
activation. No hospital count, namespace-wide access or real customer data is
needed for acceptance. Alert rules are prepared; actual Prometheus evaluation
and delivery must be checked rather than inferred from manifest presence.

## Failure handling

- Keep new uploads quarantined if ClamAV, GCS or Temporal is uncertain. Repair
  dependencies, then retry the same workflow or explicit committed attempt.
- A conflicting retained Temporal receipt is an operational incident; never
  acknowledge it as success just because a workflow ID exists.
- If the worker lacks IAM, first inspect its KSA and the three conditional
  bindings. Never grant bucket-wide objectUser/admin or clinical paths.
- A stale scanner keeps readiness false and bytes inaccessible. Restore current
  definitions through the owning scanner process.
- Revoke a released evidence item through the API to prevent future downloads;
  retained metadata/objects and immutable licence history stay intact.
- Any production rollback needs its own explicit approval. Disable new acceptance
  and restore the previous application artifact through GitOps while retaining
  evidence tables and objects. Never drop the additive schema or delete buckets
  as a rollback shortcut.

A clean scan does not verify a licence, approve a business or authorize trading.
Independent maker/checker review and country policy approval remain separate work.
