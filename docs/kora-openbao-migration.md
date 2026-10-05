# Kora OpenBao migration

Status: migration completed on 2026-09-27. Tracking: https://github.com/tesserix/tesserix-k8s/issues/1191

Use KV v2 mount `kv`, field `value`. Production paths are `kora/app/kora-*`; development paths are `kora-development/app/kora-*`. Preserve existing Kubernetes Secret names and data keys. Shared registry/bootstrap credentials and platform credentials remain in GCP.

| GCP source | Pinned version | OpenBao path | Consumer namespaces |
|---|---:|---|---|
| dev-kora-document-intelligence-signing-key | 2 | kora-development/app/kora-document-intelligence-signing-key | devai |
| dev-kora-langfuse-org-public-key | 1 | kora-development/app/kora-langfuse-org-public-key |  |
| dev-kora-langfuse-org-secret-key | 1 | kora-development/app/kora-langfuse-org-secret-key |  |
| dev-kora-langfuse-public-key | 1 | kora-development/app/kora-langfuse-public-key | devai, observability |
| dev-kora-langfuse-secret-key | 1 | kora-development/app/kora-langfuse-secret-key | devai, observability |
| dev-kora-ocr-workload-identity-keys | 3 | kora-development/app/kora-ocr-workload-identity-keys | document-intelligence |
| prod-agentic-registry-kora-deploy-key | 1 | kora/app/kora-registry-deploy-key | kora |
| prod-agentic-registry-kora-deploy-key-sha256 | 4 | kora/app/kora-registry-deploy-key-sha256 | agentregistry-system |
| prod-kora-ai-agents-api-key | 1 | kora/app/kora-ai-agents-api-key | agentgateway-system, kora |
| prod-kora-ai-gateway-api-key | 1 | kora/app/kora-ai-gateway-api-key | agentgateway-system, kora |
| prod-kora-api-platform-admin | 1 | kora/app/kora-api-platform-admin | kora, tesserix |
| prod-kora-apple-key-id | 1 | kora/app/kora-apple-key-id | kora |
| prod-kora-apple-private-key | 1 | kora/app/kora-apple-private-key | kora |
| prod-kora-apple-team-id | 1 | kora/app/kora-apple-team-id | kora |
| prod-kora-bff-internal-hmac-key | 1 | kora/app/kora-bff-internal-hmac-key | kora, tesserix |
| prod-kora-database-url | 3 | kora/app/kora-database-url | kora |
| prod-kora-expo-access-token | 1 | kora/app/kora-expo-access-token | kora |
| prod-kora-gemini-api-key | 1 | kora/app/kora-gemini-api-key |  |
| prod-kora-langfuse-org-public-key | 1 | kora/app/kora-langfuse-org-public-key |  |
| prod-kora-langfuse-org-secret-key | 1 | kora/app/kora-langfuse-org-secret-key |  |
| prod-kora-langfuse-public-key | 1 | kora/app/kora-langfuse-public-key | observability |
| prod-kora-langfuse-secret-key | 1 | kora/app/kora-langfuse-secret-key | observability |
| prod-kora-mcp-internal-key | 2 | kora/app/kora-mcp-internal-key | kora |
| prod-kora-ocr-workload-identity-keys | 2 | kora/app/kora-ocr-workload-identity-keys | document-intelligence |
| prod-kora-openai-api-key | 1 | kora/app/kora-openai-api-key |  |
| prod-kora-postgresql-password | 1 | kora/app/kora-postgresql-password | global |
| prod-kora-sandbox-anonymization-salt | 1 | kora/app/kora-sandbox-anonymization-salt | kora |
| prod-kora-sandbox-reader-password | 1 | kora/app/kora-sandbox-reader-password | kora |
| prod-kora-sandbox-sync-source-url | 1 | kora/app/kora-sandbox-sync-source-url | kora |
| prod-kora-sandbox-sync-target-url | 1 | kora/app/kora-sandbox-sync-target-url | kora |
| prod-kora-vertex-api-key | 1 | kora/app/kora-vertex-api-key | agentgateway-system |
| prod-support-platform-kora-mcp-key | 2 | kora/app/kora-mcp-key | agentgateway-system, kora |

The evals onboarding operator now reads/writes Kora project credentials in OpenBao; the console credential-status tile reads scoped OpenBao metadata. Dormant Kora-only provider and organization credentials were preserved in OpenBao after review; they are not granted broad runtime access.

Stage using `scripts/migrate_kora_secrets.py --plan-json`: the plan pins enabled source versions and the CLI accepts only the reviewed mapping. Destinations use create-only CAS=0, policy validation, byte equality and token revocation from the shared migration implementation. Temporary writer permissions are create/read on exact paths, without update/delete.

Acceptance: fresh ESO synchronization, byte equality (including rendered/derived Secret fields), ready workloads, API/database/AI/identity checks, writer retirement, and encrypted OpenBao backup plus isolated restore. Capture GCP resource metadata, IAM, enabled version payloads in a KMS-encrypted archive and verify it before approved source deletion. Keep the issue open until every criterion is met.

## Cutover and credential producers

All 32 sources were copied and byte-verified on 2026-09-27. Recovery archive: `gs://tesseract-prod-backups-in/openbao/kora-migration/20260927T083021Z/gcp-sources.json.gz.kms`. This includes GCP resource, IAM and version metadata plus enabled version payloads, encrypted with the OpenBao backup KMS key and GCS CMEK. Local evidence is private under `/tmp/kora-openbao-evidence`; values never enter Git.

The evals onboarding operator uses `--openbao-products=kora` and a five-minute Kubernetes-auth role limited to create/read/update on the two production Langfuse project credentials. Mapped failures never fall back to GCP, and writes use CAS. Other products retain their existing source until migrated individually. Source: tesserix/tesserix-operators#15 and #16, image `main-91fedba`.

The console metadata role can read only the two legacy Kora provider-key metadata paths, never their payloads. The existing credential-health inventory is preserved; age means the current OpenBao storage-version age, including migration. Source: tesserix/tesserix-home#637.

Kora's gateway also consumes `prod-devai-anthropic-api-key`; that shared DevAI-owned credential remains for the DevAI migration. Kora-only dormant credentials are preserved in OpenBao without broadening reader access. The 34 live bindings keep their Kubernetes Secret names and keys. Four Langfuse fields receive the formatting correction described below; all other rendered values are preserved.

## Langfuse credential formatting

Both existing development and production Langfuse project key pairs include surrounding whitespace. Raw Basic authentication returns 401; trimming the same keys returns 200 with distinct project scopes. OpenBao preserves the source bytes. ESO trims only the two DevAI Langfuse environment values and the inputs to the two OTel Basic-auth strings. These four rendered fields across three Kubernetes Secrets intentionally differ from the old hash baseline. All other fields must match exactly. The evals reconciler trims the public key when comparing it with Langfuse's API listing, preventing an unnecessary rotation. No new credentials are minted.

The pre-existing evals onboarding organization API 403 is tracked separately in #1194. Project-scoped credentials work after trimming; the organization permission failure is a separate platform dependency.

### Runtime verification follow-up

The agents' pinned GHCR OCI index was no longer available, preventing fresh pods from starting. The cached linux/amd64 manifest and config were recovered read-only from a running node; all ten compressed layers were fetched from GHCR and SHA-256 checked against that manifest. The identical platform image is preserved in GAR at `global/recovered/ai-agents@sha256:c65f8c5af90c21b895e11d0b47f910bb0bd99b2dc05e393c38cb40a2a790b152`. No application code or credential changed during image recovery.

OTel ingest requires a pod-template change to consume the normalized Langfuse credentials because its existing environment variables are fixed at pod startup. The `openbao-v1` annotation triggers that rollout through GitOps. End-to-end trace delivery must pass after rollout before source deletion.


## Live acceptance after storage recovery — 2026-09-27

All 34 live bindings use OpenBao and are Ready. All 22 Kubernetes Secret maps
match the original hash baseline except the four reviewed Langfuse formatting
corrections. No live ExternalSecret references any of the 32 GCP originals.
Before deletion, all originals were present and their latest enabled versions
matched the migrated versions. The user explicitly approved deletion of the
32 named inventory entries; all were deleted and verified absent.

Kora API, agents, company console, OTel ingest and OpenBao are Synced/Healthy.
API readiness, signed BFF catalog and federation dependency checks passed;
invalid signatures were rejected. Fresh agents generated a 3072-dimension
embedding through the gateway; an invalid gateway key was rejected. MCP
stateless discovery, tool listing and read-only nutrition lookup passed using
the migrated credentials. Console metadata reads passed and payload reads were
denied. Development and production Langfuse credentials authenticated with
distinct project scopes.

Shared telemetry disk pressure blocked repeat testing and was repaired by the
approved PR #1198. Six spans through both gateways and a further span from Kora's
agents reached the Langfuse v4 observations API. See
[storage recovery](telemetry-storage-recovery.md) for timing and the remaining
historical metrics backlog. The legacy traces API returns 404 in v4 events-only
mode and must not be used as an ingestion failure signal.

Backup `20260927T092106Z-3024d1f1dd83` passed isolated restore in 20.329 seconds;
an independent read-only restore passed in 17.881 seconds. The dedicated recovery
bucket contained exactly three retained snapshots. The encrypted original-source
archive above remains available. Temporary migration writer permissions and
tokens were removed/revoked.

Issue #1191 is complete after approved source deletion and post-deletion checks.
Separate platform onboarding permissions (#1194), image retention (#1196),
telemetry capacity/backlog (#1197), and historical sandbox-sync deadline failures
are not represented as fixed by the secret migration. No interactive mobile or
human sign-in session was exercised.


## Approved source deletion and final verification

On 2026-09-27, the user approved deleting all 32 GCP source resources listed in
the inventory above. Before deletion, the remote encrypted archive was downloaded,
compared byte-for-byte, decrypted, and checked against all current resource
metadata, IAM policies and enabled versions. Every capture matched. Deletion
was restricted to the exact reviewed inventory; the project listing subsequently
confirmed all 32 originals absent. Private audit:
`/tmp/kora-openbao-evidence/source-deletion-journal.jsonl`.

All 22 ExternalSecrets freshly reconciled after deletion at
`2026-09-27T10:04:48Z`. All 34 bindings remained Ready, and all target Secret maps
matched the expected values. API readiness, signed BFF/federation calls, a real
3072-dimension gateway embedding, MCP nutrition lookup, console metadata access,
development/production Langfuse authentication and a trace from the running
agents pod all passed. Invalid credentials/signatures and console payload access
were rejected. The Kora applications and OpenBao remained Synced/Healthy.

Final backup `20260927T100516Z-bb1833b41e3a` passed isolated restore in 18.573
seconds and retained exactly three recovery points. The original-source encrypted
archive remains at the recovery location documented above. Shared
`prod-devai-anthropic-api-key` was verified still present; no platform/shared
secret was included in this deletion. Separate platform follow-ups remain open.

The Kora API reader has read-only access to the production OCR identity source.
`kora-ocr-client` extracts only `kora-prod-v1` into its target Secret; the full
identity map is not retained in the API namespace. Missing or malformed signing
keys block reconciliation. Production OCR ingress permits only the Kora API
service account; API egress permits only the upload and job API components.

Kora API account-status verification uses `kora/app/kora-firebase-api-key` through the namespace-bound production reader and required `kora-firebase-client` Secret. The existing Firebase public client key is provisioned directly in OpenBao; it is not committed to chart values.
