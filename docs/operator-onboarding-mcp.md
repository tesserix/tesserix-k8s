# Operator onboarding MCP deployment

The Registry-owned route is
`https://mcp.tesserix.app/mcp/onboarding/operator-onboarding-mcp`.
It serves the private onboarding API's stateless `/mcp` adapter on the API's
existing two replicas. No public Service, separate gateway, database or
superuser proxy is created.

Source and generated schemas live in
[`onboarding-service`](https://github.com/tesserix/onboarding-service/blob/main/docs/operator-onboarding-mcp.md).
Claude setup, tenant modelling, OAuth scopes and examples live in the
[Australis guide](https://github.com/tesserix/australis/blob/main/docs/guides/operator-onboarding-mcp.md).

| Desired state | Owner |
|---|---|
| MCP enablement / Gateway project | `charts/apps/onboarding-service/values-prod.yaml` |
| Gateway export and typed tools | `charts/apps/agentgateway-route-sync/files/onboarding/registry.yaml` |
| Catalog publication | `devai/devai-registry-bootstrap` via `templates/onboarding-seed.yaml` |
| Gateway-policy import | `agentgateway-system/agentgateway-route-sync` via the same template |
| Signed role definitions / exact machine grants | `charts/apps/zitadel-bootstrap/values.yaml` |
| Dedicated machine / one-time credential issue | `k8s/operators/zitadel/claims/onboarding.yaml` |
| Exact OpenBao writer and read-only namespace-bound reader | `charts/thirdparty/openbao/values.yaml` |
| Gateway egress / API ingress | Agentic Istio manifest and onboarding chart |

The machine `onboarding-mcp-claude-prod` receives only `agentgateway.onboarding`,
`onboarding.helivanta.read` and `onboarding.helivanta.create`. It has no adoption
or identity-management role. Its credential is published once at
`kv/onboarding/prod/app/onboarding-mcp-claude-prod`. The only Kubernetes reader
is `onboarding/onboarding-mcp-client`, with no Kubernetes RoleBinding. Its
OpenBao role has a five-minute TTL and read access to exactly that data path.
There are no new GCP Secret Manager dependencies or static Gateway upstream
keys. A missing source/role fails closed.

The API independently verifies Gateway and onboarding audiences and the exact
project/organization role projection. Only the caller's verified identity
controls authority. The generated Registry entry has no `credentialRef` that
could overwrite it with a shared service identity. The existing route-sync
controller exports the HTTPRoute; do not hand-create a duplicate route or
change the global prune floor.

Validation before merge: focused onboarding/chart and MCP security contracts,
bootstrap's 121 tests, changed-chart lint/render, API
PostgreSQL/race suite, and Australis client tests/type-independent Go checks.
Generate Registry metadata in the API repository and copy it unchanged here.
The runtime compiler test prevents schema/metadata drift at the source.

After GitOps reconciliation, verify every relevant Argo application is Healthy
and Synced, the Registry seed Job succeeded, the new machine claim is Ready,
and both API replicas use the released image. Wait for bootstrap's scheduled
grant reconciliation. Confirm the exported backend and route are Accepted.
Use only the scoped OpenBao reader to obtain the client secret, request a
short-lived OAuth token, then exercise initialize, tools/list, context,
retained hospital status, create/replay/conflict and completion through the
public Gateway. Do not print credentials or token payloads. Verify a generic
gateway token and an unauthenticated request cannot use the tools. Existing
console/API flows and customer identities must remain intact.

Rollback is a reviewed GitOps revert of MCP enablement/publication and the
API image pin. Removing a machine claim is not routine cleanup: inspect the
operator's deletion policy and retained credential first. Keep customer claims,
OpenBao history and held GCS receipts; disabling an MCP must not delete them.
