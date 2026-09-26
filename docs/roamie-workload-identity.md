# Roamie workload identities

Zitadel bootstrap declares eight JWT machine users in the TESSERIX organization:
`roamie-trip-manager`, `roamie-trip`, `roamie-food`, `roamie-routes`,
`roamie-activities`, `roamie-shopping`, `roamie-memories`, `roamie-exchange`.

The existing AgentGateway project (`387190457387450503`) declares two
`machineRoles`: `roamie.manager` and `roamie.models`. The manager receives both;
each specialist receives only model access. The reconciler rejects any attempt
to assign a machine-only role through human grants. Existing operator and platform
workload grants remain unchanged.

Client secrets are minted once after machine creation and stored in Secret
Manager. Bootstrap never reads or rotates them. Runtime JSON maps each logical
agent name to its exact Zitadel subject, client ID and client secret; duplicate
subjects/clients are rejected by the agent runtime. Never place secrets here.

Gateway route policies must bind both the role and expected subject. The manager
alone may invoke specialist A2A and the product MCP. Distinct specialist identities
permit model access only. The product MCP independently verifies the manager's
JWT and organization role before granting `roamie:travel:read`.

This PR provisions identities only. The AI workload chart remains disabled.
Activation additionally requires immutable images, synced workload secrets,
registry-owned route acceptance, the Roamie profile migration and an end-to-end
identity probe. Obtain explicit approval before deploying this identity change
or applying the production profile migration.

## Runtime configuration follow-up

The AI chart binds the manager and specialists to separate refreshing OAuth
credential maps, shares only the A2A delegation key, and supplies the API and
manager with the same stable personal identity key. The namespace-local
waypoint is created before enrolled workloads so service authorization policies
can enforce their caller identities. The MCP requires the manager's exact
Zitadel subject and TESSERIX organization.

The chart remains disabled until registry routes and the authenticated profile
boundary have been verified. Rendering with test overrides is not production
verification. Agent image digests are from successful Publish run 36220844786.
