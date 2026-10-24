# Helivanta Global API rollout

Target: project `tesseracthub-480811`, GKE `tesseract-prod-in-gke`, namespace
`helivanta`, public host `helivanta.app`. Existing Zitadel and session authority
remain in the owning API. Global API has a separate mesh service account, no
application secrets, no database credentials and no migration hook.

## Ordered rollout

1. Publish and verify the API image containing `/app/global-api` from
   `tesserix/helivanta` commit `ede362a567dce01f6eaf31d8598cfe4eb95c4903`.
2. Merge the connector chart, namespace capacity, restricted NetworkPolicies and
   Argo application. Keep existing edge/shell destinations unchanged until both
   connector replicas are ready. Its platform readiness checks the current API.
3. Change the public `/api/v1/*` and exact internal hospital-enrolment route to
   the Global API service. Change shell runtime `apiUrl` to the same destination.
   The current shell image is compatible; its Next rewrite is bypassed by ingress.
   New shell images bake this same connector origin at build time.
4. Verify public login/branding, unauthenticated denials, downstream readiness,
   workload mTLS identities and `Via: 1.1 helivanta-global-api` response evidence.
   Enable `enforceOwnerBoundary` only after edge/shell cutover is verified. That
   DENY policy prevents direct gateway/shell access to product port 8080.

Keep the running product API image unchanged during this rollout. Its existing
Argo sync is failed at the migrate hook; newer main includes country-data
migrations outside the connector deployment. The source feature branch must not
be merged into main's automatic API promotion as part of this rollout.

## Capacity and access

Two connector replicas request 256 MiB application memory each, limit 1 GiB each,
and include an Istio native sidecar with 64/128 MiB memory requests/limits. No CPU
resources are set in the new chart; existing namespace/injector defaults apply.
The namespace quota increases requests.memory 6→8 GiB, limits.memory 16→20 GiB,
and limits.cpu 12→20 to admit sidecars/defaults and preserve hook headroom.
This raises admission ceilings, not purchased node capacity. Check actual admitted
resources and readiness after deployment. No autoscaling or new node pool is added.

The connector receives traffic only from ingress and shell mesh identities. Its
network egress allows DNS, Istiod certificate/control-plane traffic, and the
current API. It is excluded from namespace-wide permissive egress rules. HTTP
service URLs are protected by explicit STRICT mTLS at connector and owner.
API application checks still verify session/workload credentials, revocation,
tenant membership, permission and object scope.

## Recovery

The previous edge destination and shell `apiUrl` were
`helivanta-api.helivanta.svc.cluster.local:8080` (HTTP for runtime URL). Routing
rollback must first disable `enforceOwnerBoundary`, then restore both targets
through GitOps; it does not restore data or revert a migration. Obtain specific
approval before a live rollback. Do not delete the connector or its service
account to attempt recovery.
