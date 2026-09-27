# Roamie OpenBao migration

Tracked in [#1176](https://github.com/tesserix/tesserix-k8s/issues/1176).

Roamie application secrets use KV v2 `value` entries under `roamie/app/roamie-*`;
development credentials use `roamie-development/app/roamie-*`. Platform bootstrap,
infrastructure and recovery secrets remain in GCP Secret Manager. The shared weather
key remains at its existing fe3dr OpenBao path.

## Scope and consumers

30 product-owned sources: 29 production and one development. Eighteen sources feed
27 ExternalSecret fields across Roamie, agentgateway-system, agentregistry-system,
document-intelligence and global. Three database credentials are copied unchanged.
The other twelve entries preserve ten specialist OAuth bundles, a schema digest and
the registry publisher key. Current repository runtime/workflows do not fetch these
from GCP Secret Manager; registry publishing uses the existing GitHub Actions secret.
Do not rotate or remove that GitHub secret during this migration.

Six namespaced Kubernetes identities receive exact-path read-only access. Application
readers do not receive the archival OAuth bundles or raw registry publisher key.

## Execution and recovery

`scripts/migrate_roamie_secrets.py --plan PLAN.json` validates without mutation;
`--policy` emits exact-path create/read permissions. Execute using a short-lived
Kubernetes-auth token with policy `roamie-migrate-reviewed`, `--execute`, `--account`
and `--journal`. Plans pin numeric GCP source versions. Existing unequal destinations
fail closed. Values stay in memory; the journal contains metadata only. Remove the
temporary role/policy after staging; tokens are revoked by the migration helper.

Before cutover, compare source/destination bytes, verify reader denials and back up
source metadata/IAM and all enabled versions. Restore the post-copy Raft snapshot in
an isolated node and compare all 30 values/versions. Recovery artifacts for this run:
`gs://tesseract-prod-backups-in/openbao/roamie-migration/20260927T040512Z/`.
The source archive is KMS-encrypted and the Raft snapshot uses OpenBao encryption.
Access requires the platform KMS key and backup-bucket permissions. Existing bucket
retention/lifecycle governs these artifacts; migration does not shorten it.

Terraform stacks 07 and 15 release the three database credentials with
`removed` blocks using `destroy = false`. The previous stack-15 resources contained
only `roamie-prod`, confirmed against remote-state index metadata. Future GCP-backed
products use filtered `database_gcp` resources. Review Atlantis plans before apply;
no unrelated changes or destruction are part of this handoff.

After GitOps cutover, check current ExternalSecret generations, unchanged target
bytes, workload readiness and authenticated dependency calls. Delete the reviewed
GCP originals only after acceptance and recovery verification. Then force a fresh
ExternalSecret reconciliation and recheck the application and GCP inventory.
Before deletion, rollback is the chart source revert; after deletion, restore the
archived GCP values/IAM first or repair the OpenBao source while keeping current
Kubernetes Secret data. A Git revert alone cannot restore deleted GCP sources.

## Reviewed mapping

| GCP source | Pinned version | OpenBao path |
|---|---|---|
| `dev-roamie-api-ocr-key` | 1 | `roamie-development/app/roamie-api-ocr-key` |
| `prod-agentic-registry-roamie-deploy-key` | 1 | `roamie/app/roamie-registry-deploy-key` |
| `prod-agentic-registry-roamie-deploy-key-sha256` | 1 | `roamie/app/roamie-registry-deploy-key-sha256` |
| `prod-document-intelligence-roamie-db-password` | 1 | `roamie/app/roamie-document-intelligence-db-password` |
| `prod-roamie-activities-oauth` | 1 | `roamie/app/roamie-activities-oauth` |
| `prod-roamie-agents-api-key` | 1 | `roamie/app/roamie-agents-api-key` |
| `prod-roamie-agents-gateway-clients` | 3 | `roamie/app/roamie-agents-gateway-clients` |
| `prod-roamie-api-ocr-key` | 1 | `roamie/app/roamie-api-ocr-key` |
| `prod-roamie-api-places-key` | 1 | `roamie/app/roamie-api-places-key` |
| `prod-roamie-delegation-key` | 1 | `roamie/app/roamie-delegation-key` |
| `prod-roamie-entry-guidance-oauth` | 1 | `roamie/app/roamie-entry-guidance-oauth` |
| `prod-roamie-exchange-oauth` | 1 | `roamie/app/roamie-exchange-oauth` |
| `prod-roamie-food-oauth` | 1 | `roamie/app/roamie-food-oauth` |
| `prod-roamie-manager-api-key` | 1 | `roamie/app/roamie-manager-api-key` |
| `prod-roamie-manager-gateway-clients` | 1 | `roamie/app/roamie-manager-gateway-clients` |
| `prod-roamie-manager-identity-key` | 1 | `roamie/app/roamie-manager-identity-key` |
| `prod-roamie-manager-subject` | 1 | `roamie/app/roamie-manager-subject` |
| `prod-roamie-mcp-api-token` | 1 | `roamie/app/roamie-mcp-api-token` |
| `prod-roamie-mcp-delegated-token` | 1 | `roamie/app/roamie-mcp-delegated-token` |
| `prod-roamie-memories-oauth` | 1 | `roamie/app/roamie-memories-oauth` |
| `prod-roamie-postgresql-password` | 1 | `roamie/app/roamie-postgresql-password` |
| `prod-roamie-postgresql-runtime-password` | 1 | `roamie/app/roamie-postgresql-runtime-password` |
| `prod-roamie-profile-signing-key` | 1 | `roamie/app/roamie-profile-signing-key` |
| `prod-roamie-routes-oauth` | 1 | `roamie/app/roamie-routes-oauth` |
| `prod-roamie-shopping-oauth` | 1 | `roamie/app/roamie-shopping-oauth` |
| `prod-roamie-travel-mcp-key` | 1 | `roamie/app/roamie-travel-mcp-key` |
| `prod-roamie-travel-schema-digest` | 2 | `roamie/app/roamie-travel-schema-digest` |
| `prod-roamie-trip-manager-oauth` | 1 | `roamie/app/roamie-trip-manager-oauth` |
| `prod-roamie-trip-oauth` | 1 | `roamie/app/roamie-trip-oauth` |
| `prod-roamie-weather-oauth` | 1 | `roamie/app/roamie-weather-oauth` |
