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
No credential value was read, printed or committed during activation.

Application PR tesserix/helivanta#1166 is merged and deployed at
`5e73de6475d68be315c9254334a6cef576454709`. After explicit approval, the normal
Argo migration hook applied `0018_workforce_worker_outbox_scope`. The HR outbox
predicate is now restricted to the HR role; the Supply worker still has no
SELECT privilege on HR document identifiers or filenames. Both workers retain
their restrictive outbox boundaries. The release also preserves initial upload
chronology under clock correction without changing timestamps on replay.

Main CI [38855558825](https://github.com/tesserix/helivanta/actions/runs/38855558825)
and image workflow
[38855558429](https://github.com/tesserix/helivanta/actions/runs/38855558429)
succeeded. Kargo promotion `prod.01m51jwpjb1f6ppcady5wy5qc5.66bb7eb` succeeded.
API, shell, HR document workers and Supply evidence workers each have two ready,
updated replicas on the exact release, with zero restarts. Observed digests:

- API and both worker types: `sha256:6987a22be5b702494d81b24b5e22112d39eb588509a27dc1b31506e5e981aef0`.
- Shell: `sha256:00c7b2e402df1e8f1537252759e95c830e99b1101fc1d579e12a884de7fd4de6`.

All Helivanta Argo applications are Synced/Healthy. CNPG has two healthy
instances. Synthetic signed-in YES HOSPITAL acceptance on 2026-10-16 verified:

- The formerly failed synthetic scan completed after a narrowly scoped Temporal
  reset at its first workflow task. No lifecycle row, provenance, permission or
  object was repaired by hand.
- The UI showed Ready; a new browser download was 179 bytes and matched the
  synthetic source SHA-256
  `a4d936d98cd9b0e4ed3c021b0d68e37dd9172c76d22329c013c104fd089b9059`.
  A fresh filesystem baseline excluded historical downloads from this result.
- Replaying the completed workflow retained one evidence row, one published
  available event, the same object generation and scan/upload timestamps.
- A new image uploaded through the UI reached Ready through the normal
  NATS/Temporal/ClamAV path, without workflow recovery.
- Both synthetic records were revoked through the UI. A second tab retaining
  its stale Download button received a not-found error after revocation; no
  download file appeared. Retained rows and audit history were preserved.
  Each record has one published available event and one published revoked event.
- ClamAV reported engine 1.5.4 and definitions 28154 dated
  `2026-10-15T06:24:22Z`, younger than 24 hours during these scans. Unsupported
  text evidence was rejected without another record during initial acceptance.

Live acceptance proves the synthetic same-tenant lifecycle and stale-client
revocation. Cross-tenant and denied clinical/bucket operations are covered by
local real-database tests and reviewed IAM conditions; they are not claimed as
live negative probes using a second production tenant or GCS identity.
Both API replicas and both HR/Supply worker pairs had no ERROR, panic or
SQLSTATE records during post-release inspection. JetStream's
`supply-evidence-scan` and `workforce-document-scan` consumers each had zero
pending, unacknowledged or redelivered messages.

Monitoring remains an explicit operational gap: the Supply PrometheusRule exists,
but production Prometheus and Alertmanager StatefulSets have desired replicas
zero and their services have no endpoints. Alert evaluation and delivery were
therefore not exercised. Track this under application metrics #606 and the
platform monitoring issue tesserix/tesserix-k8s#710; restoring monitoring needs
its own reviewed GitOps change and rollout approval.

Licence verification, country-policy approval, trading approval and wider B2B
acceptance remain open under #1135, #1133 and parent #979. A clean image never
constitutes a verified licence or permission to trade.

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
