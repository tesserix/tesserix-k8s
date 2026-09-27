# Coordinated fe3dr secret migration

Tracks #1159. The six coordinated application sources are already staged in
OpenBao with unchanged values. They must not be deleted from GCP until every
listed consumer is reconciled and its rendered Kubernetes value verified.

| Source suffix | Consumers |
|---|---|
| `postgresql-password` | API/worker, CNPG app credentials, database backup namespace |
| `bff-internal-hmac-key` | API, BFF, tesserix company |
| `google-weather-api-key` | API, Roamie trip manager |
| `support-hook-secret` | HomeChef Otto, shared support router |
| `mcp-key` (`prod-support-platform-homechef-mcp-key`) | HomeChef MCP, gateway, support router |
| `platform-admin-password` | tesserix HomeChef platform admin bootstrap |

## Access design

ESO uses a dedicated `fe3dr-secret-reader` ServiceAccount in each cross-product
consumer namespace. Each `read-fe3dr-<namespace>` role binds that exact identity
and grants read on only its listed `kv/data/homechef/homechef-api/fe3dr-*` paths.
The read allowlists contain no wildcards, listing, write, delete or admin rights.
The identity does not automount into workload pods. Namespace administrators
already control the resulting Kubernetes Secrets; the new store does not grant
access to the rest of the API prefix or other consumers' credentials.

OpenBao bootstrap persists the policies and roles; the same chart owns the
reader ServiceAccounts and `openbao-fe3dr-shared` namespaced stores. ESO's
existing network route to OpenBao is sufficient; consumers get no direct network
grant. Existing API/BFF stores retain their own prefixes, including the BFF HMAC
copy. This introduces five token identities and bounded per-refresh reads, not
request-time calls or additional pods. Values, destination keys and templates
are preserved, including CNPG password trimming.

## Deployment and validation

Deploy policy/store reconciliation before accepting consumer readiness. A brief
store-not-ready condition retains the old target; it must resolve before GCP
cleanup. Verify each store Ready and each intended/denied path with its own
identity, then ESO current generation, target equality and consumer health.
Do not rotate the database password or trigger a database migration. Validate
existing API database connectivity and backup credentials without a destructive
restore into production. Verify all shared consumers before deleting any source.

The independently verified snapshot already includes these staged values.
Capture source metadata, IAM and enabled versions to an independently encrypted
recovery archive before deletion. Check fresh GCP source versions have not
changed since staging. Record cleanup evidence and recovery locations in #1159.

Before deletion, rollback is a GitOps reversal of the consumer source mappings.
After deletion, recreate sources from the recovery capture before reversing.
Removing a bootstrap entry does not delete its persisted role/policy; explicitly
retire grants after consumers are removed instead of assuming pruning revokes
access. Keep critical KMS/bootstrap/platform/recovery secrets in GCP.
