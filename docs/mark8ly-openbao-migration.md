# Mark8ly OpenBao migration

Tracked in [#1209](https://github.com/tesserix/tesserix-k8s/issues/1209).

## Reviewed scope

55 named application/legacy sources, including 17 isolated UAT destinations.
40 live ESO bindings produce 33 Kubernetes Secrets across mark8ly, tesserix,
openpanel, monitoring, agentgateway-system and support-platform. The shared
Mark8ly MCP key belongs to Mark8ly. Shared registry and critical platform keys
remain in GCP. See [the inventory](mark8ly-openbao-inventory.csv).

Six additional test-scoped tenant sources are tracked privately, outside the
application inventory. Do not flatten them into shared app paths or publish
owner IDs. The live carrier-reference verifier examined six slots: three Bao
references resolved and three were empty; no GCP references were found.

## Access phase (not migration completion)

Six namespace-bound readers receive read-only access to exactly their observed
Mark8ly application dependencies. The temporary `mark8ly-migrate-reviewed` role
is bound only to `openbao/mark8ly-migration-writer`, has a 15-minute TTL and grants
create/read on the 55 reviewed destinations. It cannot update or delete values.
App readers do not receive tenant-path access. Existing tenant runtime roles
remain unchanged. The temporary writer must be retired after staging.

The reusable `scripts/migrate_product_secrets.py` checks the reviewed catalog,
source uniqueness, pinned versions and exact destinations. It reuses the existing
CAS=0 copy/readback implementation, rejects differing existing values, journals
metadata only and revokes its token on exit. A partial retry accepts identical
copies; it never silently overwrites a changed credential.

Recovery archive (download/decrypt/equality verified):
`gs://tesseract-prod-backups-in/openbao/mark8ly-migration/20260927T123848Z/gcp-sources.json.gz.kms`.
It includes source metadata, IAM and all enabled versions for the 55 named sources.
Private evidence: `/tmp/remaining-openbao-evidence/mark8ly/` (0700).

Baseline: all Mark8ly Deployments ready at their desired replica counts. Existing
image parameters are captured and must be preserved during parent app sync.
Secret targets have a hash-only baseline; no payload is committed to this repo.

## Acceptance before source deletion

Archive and verify tenant entries separately; stage and byte-verify copies;
cut over ESO bindings and producers through GitOps; verify fresh reconciliation,
full Secret hashes, actual application/readiness/provider behavior and tenant
runtime reads. Run a fresh verified OpenBao backup and isolated restore. Remove
temporary write access. Delete only accepted sources under the approved migration
scope, verify absence and rerun application checks before starting Postiz.

Rollback before deletion: revert consumer references through GitOps while keeping
copies intact. After deletion, restoring GCP sources requires the encrypted source
archive and its KMS key. No new services or persistent volumes are introduced;
access objects and the small KV inventory add negligible ongoing cost.

Threat model: application and per-tenant credentials must remain inaccessible to
other namespaces and tenant owners. GCP IAM, Kubernetes identity, exact OpenBao
ACLs and server-derived tenant scope are the authorization boundaries. Migration
logs contain counts and metadata, never payloads.
