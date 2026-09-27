# Kora OpenBao migration

Tracking: https://github.com/tesserix/tesserix-k8s/issues/1191

Use KV v2 mount `kv`, field `value`. Production paths are `kora/app/kora-*`; development paths are `kora-development/app/kora-*`. Preserve existing Kubernetes Secret names and data keys. Registry credentials and shared platform credentials remain in GCP.

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
| prod-kora-ocr-workload-identity-keys | 1 | kora/app/kora-ocr-workload-identity-keys | document-intelligence |
| prod-kora-openai-api-key | 1 | kora/app/kora-openai-api-key |  |
| prod-kora-postgresql-password | 1 | kora/app/kora-postgresql-password | global |
| prod-kora-sandbox-anonymization-salt | 1 | kora/app/kora-sandbox-anonymization-salt | kora |
| prod-kora-sandbox-reader-password | 1 | kora/app/kora-sandbox-reader-password | kora |
| prod-kora-sandbox-sync-source-url | 1 | kora/app/kora-sandbox-sync-source-url | kora |
| prod-kora-sandbox-sync-target-url | 1 | kora/app/kora-sandbox-sync-target-url | kora |
| prod-kora-vertex-api-key | 1 | kora/app/kora-vertex-api-key | agentgateway-system |
| prod-support-platform-kora-mcp-key | 2 | kora/app/kora-mcp-key | agentgateway-system, kora |

The evals onboarding operator creates/reads Langfuse credentials in GCP. The console credential-status tile checks GCP metadata. Complete these dependencies before deleting affected originals. Dormant direct-provider and Langfuse organization credentials require explicit ownership review; absence of an ESO consumer alone does not prove they are unused.

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
