# Public OCR sandbox

Host: `ocr-test.tesserix.app`. Product: `ocr-sandbox`. Namespace:
`document-intelligence`. This is independent of Kora's existing development OCR
release named `document-intelligence-sandbox`.

The adapter chart serves the OCR-only site/API. The product registry creates a
separate upload API, job API, scanner and execution workers, a one-day Temporal
namespace, four private CMEK buckets, and dedicated Google identities. Two
separate databases/roles on global-postgres hold core OCR metadata and adapter
sessions; no new PostgreSQL cluster or disk is allocated.

All three credentials are created once inside OpenBao with CAS=0 by a narrowly
scoped bootstrap Job. ESO reader roles are namespace-bound. The bootstrap never
prints credentials, rotates existing values or exports them into Terraform.
The cleanup identity can list/delete objects and read policy on only the four
sandbox buckets. Existing Kora/Roamie resources remain untouched.

Rollout gates:
1. Merge/build the application image and set the immutable tag in adapter values.
2. Apply stack 15's reviewed additive plan, then merge this GitOps change.
3. Verify OpenBao bootstrap/readers, CNPG roles/databases, schema bootstrap,
   Temporal registration, private OCR workers, adapter readiness and ingress.
4. Enable adapter admission with the public `/v1/` route still blocked. Test
   synthetic fixtures through the adapter, inspect real results, and verify GCS
   generations are absent after completion, rejection and abandoned sessions.
5. Set `publicAPIEnabled: true` only after qualification. Verify public API and
   browser flows, cross-session isolation and shared budget behavior.

Limits: one image/session, 4 MiB/12MP, 15-minute sessions, 60 requests/session/min,
10 sessions/source network/hour, 1,000 sessions/day and 100 uploads/day. The ingress
adds 120 requests/minute per gateway replica for this host. It aggregates traffic,
not per-person identity; the adapter intentionally does not trust forwarded IPs.
At most 100 admitted pages/day (roughly 3,100/month) can reach OCR; provider OCR,
KMS, storage/operations and additional worker memory still have costs. There is
no generative model spend. Track the `ocr-sandbox` product in OCR/Cloud billing.

Normal cleanup runs independently of the browser and verifies deletion before
reporting success. The one-day GCS lifecycle is only an outage backstop. Source
image recovery/versioning is intentionally disabled; result/page artifacts expire
with sessions. Provider retention policies remain separate. Shared PostgreSQL
backups retain non-image job/session metadata under the existing recovery policy.
No training use is enabled by this sandbox.

Rollback: set `publicAPIEnabled: false` and `admissionEnabled: false` through Git,
leaving the adapter cleanup worker running until its ledger drains. Keep databases
and buckets; do not delete the ledger or roll back its schema while cleanup is
outstanding. All bucket destruction is Terraform-protected. If the adapter image
itself fails, block ingress first and restore the last qualified image.

Observe readiness, HTTP 429/5xx, cleanup retry logs and ledger pending-cleanup age.
This small demo does not add a paging SLO; any inability to verify cleanup is a
reason to close public admission and repair the dependency before reopening.
