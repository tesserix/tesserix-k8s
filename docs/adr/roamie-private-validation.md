# Roamie workload validation before customer activation

The chart currently requires live identity and registry verification before any
workloads can start. That prevents validating the MCP service and worker path.
The API bridge remains disabled, but its future activation must not accidentally
expose an unverified manager.

Use a validation-only rollout of the existing three workloads (two replicas
each), with an unconditional waypoint DENY policy on the trip-manager Service.
Keep both verification flags false. Worker and MCP access still require the
existing exact gateway SPIFFE identity, workload keys and manager OAuth role and
subject. Normal serving continues to require both verification flags. No profile
or preference checks are relaxed in application code.

The assets are personal profiles, delegation credentials and paid model access.
Untrusted callers, other workload identities and accidental API activation must
not reach the manager in this mode. Native MCP transport resources are imported
through the registry, with manager-only policy already attached; the MCP catalog
keeps generated-route export disabled to avoid two route owners.

Validation allows zero customer RPS and at most one synthetic request/second.
Existing parsers bound payloads; no new data is persisted. The readiness objective
is all six pods ready within ten minutes; dependency failure must remain closed.
Compute requests total 600m CPU and 1536Mi memory, plus the namespace waypoint;
model charges are limited to explicit small smoke requests. Capacity and latency
for customer traffic are outside this preflight rollout.

This is reversible GitOps configuration and requires named rollout approval.
Do not claim end-to-end verification from readiness alone. Before serving, verify
real authenticated profile isolation, signed A2A exchange, MCP schema/identity,
model response and both manager reviews. Removing validationOnly without both
verification flags fails Helm rendering. Rollback must preserve the DENY boundary
until the API bridge is known disabled; imported native routes need registry
reconciliation rather than a direct Kubernetes deletion.
