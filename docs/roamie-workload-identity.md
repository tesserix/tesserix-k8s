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
