# Roamie registry-owned routes

The existing route-sync identity imports eight native resources through Registry's
`/v0/agentgateway/import` endpoint. The seed job never applies gateway resources
directly. Route-sync subsequently reconciles the registry export; the existing
27-resource platform seed and pruning floor are unchanged.

This activation candidate enables `roamieSeed.enabled` after all eight workload
subjects were provisioned and their OAuth tokens verified. The manager subject and seven
specialist subjects must be distinct numeric Zitadel IDs. Manager-only A2A/MCP
policies verify the exact subject and the TESSERIX organization in the project's
`roamie.manager` role claim. Model access accepts only those eight subjects and
requires the organization-scoped `roamie.models` role. JWT validation also
requires the fixed issuer and project audience.

Before activation, provision `prod-roamie-agents-api-key` and
`prod-roamie-travel-mcp-key`, and publish the product MCP manifest in the `roamie`
registry namespace. The MCP catalog entry must export the service-selector route
`roamie-roamie-travel-mcp`; its matching manager-only policy is in this seed.
The product MCP independently verifies the manager's signed OAuth token. Verify
header propagation, schema digest, route acceptance and negative identity cases
against the running gateway before enabling the API bridge.

Gateway resources were validated against the installed CRD schemas with server
dry-run only; this does not prove live routing or authorization. Test subjects
are fixture values, never production configuration. The seed enables the declared gateway routes; AI workloads and the customer API
bridge remain disabled in their separate charts.

Activation changes shared route-sync configuration and the gateway's upstream
secret inventory, so it requires a named production rollout approval. Rollback
must restore the previous registry desired state through its owning seed; merely
disabling this additive importer does not delete previously imported objects.

On 2026-09-26 all eight machine subjects were provisioned by Zitadel bootstrap
and independently verified with real signed OAuth tokens: issuer, project
audience, exact subject, token lifetime, role set and organization membership.
Initial client secrets and workload keys are stored in Secret Manager. No
existing credentials were rotated. The source chart now includes those verified
public subjects and enables the import in this unmerged activation candidate.
Do not merge until the named production rollout is approved.
