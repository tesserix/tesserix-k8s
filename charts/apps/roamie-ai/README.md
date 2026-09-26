# Roamie AI candidate deployment

Disabled by default. Owns private manager, specialist workers and product MCP.
No Argo Application is activated by this change. Booking/Klook are separate packages
and require separately reviewed workloads after provider activation.

Before enabling, verify backend-signed profile snapshots and mobile revision checks,
registry-generated model/MCP/A2A routes and caller identities. Set
`profileBoundaryVerified` and `registryRoutesVerified` only after those tests pass.
Build and scan images, configure real immutable digests and provision ExternalSecret
remote references. Do not use placeholder secrets for live provider access.

Review namespace, waypoint, API service-account name, gateway principals, NetworkPolicy
and MCP allowed-host configuration against the target cluster. Probes explicitly set
the service Host header. Confirm /readyz reflects dependency readiness in smoke tests.

```sh
helm lint .
helm template roamie-ai . --namespace roamie
```

An enabled render fails unless both verification gates and all image digests are set.
Production rollout requires explicit approval and the owning GitOps delivery process.
No cluster mutation has been performed.
