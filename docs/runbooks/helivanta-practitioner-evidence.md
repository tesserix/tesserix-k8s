# Professional registry evidence worker

Status: proposed runtime integration for helivanta#169; not activated.

## Activation prerequisites

The application PR registers sixteen previously inactive professional-source
migrations (`0001_practitioner` through `0016_practitioner`) and packages
`/app/practitioner-evidence-worker`. Review and approve those exact migrations
before merging the application runtime change. All professional routes remain
compiled `unreleased`; enabling processing cannot enable clinical verification.

Before any live action, report the active authenticated cloud account, project,
Kubernetes context, namespace and intended resources. Obtain specific approval
for the migrations, dedicated OpenBao credential/CNPG LOGIN, three object-scoped
GCS grants and new two-replica workload. Do not reuse broad application, document,
supplier or pharmacy evidence credentials.

## Ordered delivery

1. Verify both repositories remain public and required CI checks pass for exact
   application/chart commits. Use the same signed Kargo API artifact for API,
   migration and professional worker.
2. With approval, apply the `17-helivanta-files` professional object-scoped grants.
   Only the `helivanta/helivanta-practitioner-evidence-worker` identity receives
   get access to quarantine and get/create access to released `practitioner`
   object-owner paths. No list/delete or unrelated owner paths are granted.
3. Enable only `practitionerEvidenceWorker.seed.enabled` in the PostgreSQL
   Application first. The dedicated job authenticates with its projected workload
   identity and five-minute OpenBao role, verifies exact-path create-only
   authority, and writes a fresh random URL-safe password with KV CAS 0 at
   `kv/helivanta/production/helivanta-practitioner-evidence-worker-db-password`.
   It reads metadata only, preserves existing versions, refuses deleted/destroyed
   history and revokes its own token. Verify successful job completion and safe
   status logs; never read the password into a terminal. Repeating the job does
   not rotate a credential. LOGIN and worker activation remain off at this stage.
4. Enable `practitionerEvidenceWorker.credentials.enabled` in the PostgreSQL
   Application values. Verify its dedicated SecretStore and ExternalSecret are
   ready, then enable `practitionerEvidenceWorker.login`. The role is
   `helivanta_practitioner_evidence_worker`, NOINHERIT, no memberships, no
   superuser/BYPASSRLS/CREATEDB/CREATEROLE. Confirm those attributes read-only.
5. Promote the compatible signed application artifact and let the owning migration
   job complete. Verify all sixteen migrations and real table-level grants/RLS.
   An image rebuild or green health probe alone does not prove migration success.
6. Enable `practitionerEvidence.enabled` in API Application values, retaining
   `documents.enabled` and `documents.acceptUploads`. Observe two updated/ready
   worker replicas, healthy Postgres/Temporal/scanner readiness, exact image
   digest and private-pipeline dependency health.
7. In authorized isolated fixtures, test tenant/out-of-scope denial, wrong-role
   refusal, clean exact-generation release, malware rejection, revoked evidence,
   stale generations and exhausted-workflow retry recovery. Verify audit and
   durable current file state through the owner. Delete no retained clinical or
   commercial records to manufacture success.

## Alarms and recovery

`HelivantaProfessionalEvidenceWorkerUnavailable` alerts after five minutes with
no available worker; `HelivantaProfessionalEvidenceWorkerRestarting` reports
repeated restarts. Check rollout identity, dedicated credential/role readiness,
Temporal namespace/task queue, scanner health/definition age and private GCS
permissions. Do not log secret values, evidence bytes or private subject details.

Unprocessed or failed evidence stays unavailable. The existing owner retains
scan attempts and generation-bound retry commands; use its authorized retry flow
after dependency recovery. Never edit evidence status in SQL, reuse another
worker role, bypass scanner checks or manually mark a file available.

Any live rollback/disable action requires its named approval. Roll back via the
owning GitOps/Kargo flow, preserving forward-only schema, evidence history and
quarantine/released objects. Restoring an old image is not reversing migrations.
No clinical authority or public file access may be introduced during recovery.

## Local checks

Focused rendered Helm tests cover default dormancy, exact credentials, missing
private-pipeline rejection, scanner/network isolation and scoped OpenBao reader.
The mocked Terraform plan asserts precisely three path-bound get/create grants.
Neither test is live IAM/cluster acceptance.

## Credential preparation evidence

The seed capability is tested through the actual initializer and rendered Helm
resources. Tests cover CAS-0 creation, repeat preservation, deleted/destroyed
history refusal, excessive-capability refusal and exact namespace/role binding.
The production seed selection does not enable database LOGIN or the evidence
worker. Use separate subsequent values changes only after compatible migrations,
artifact, role, scanner and capacity checks.
