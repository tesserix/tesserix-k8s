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

## Regression and live acceptance

Run the chart tests on every route, identity or workload-policy change:

```sh
uv run --with pytest --with pyyaml python -m pytest tests/test_helivanta_global_api.py tests/test_helivanta_global_boundary.py -q
helm lint charts/apps/helivanta-global-api charts/apps/helivanta-istio charts/apps/helivanta-shell
```

The cutover adds `tests/test_helivanta_global_cutover.py`; run it as well. Keep
the application route-registry, forged-header, timeout, body-limit and real
session/revocation tests, plus all three browser E2E phases, in the source CI.
A passing chart render cannot substitute for the following live assertions:

| Probe | Required result |
| --- | --- |
| Public `/login` | 200 |
| Connector `/readyz` from the shell | 200 |
| Public `/api/v1/iam/me/permissions` without credentials | 401 |
| Registered MediCore, workforce, pharmacy, supply, lab and emergency GET routes without credentials | 401 |
| Unknown product route | 404 |
| Exact internal hospital-enrolment POST without credentials | 401 |
| Direct shell-to-owner `/v1/iam/me/permissions` after boundary enforcement | mesh 403 |
| Same protected route through connector after enforcement | owner 401 |

All connector responses above must include `Via: 1.1 helivanta-global-api`.
Repeat protected probes with forged user/tenant headers; they must remain denied.
Do not print patient bodies, cookies or tokens. Verify the deployed image digest,
dedicated service account, native Istio sidecar, two ready replicas, zero crash
loops and healthy existing API/shell. Use synthetic tenants for authenticated
browser checks; never create clinical or financial records merely to smoke-test
production. Dependency failures and retry/timeout cases belong in isolated tests.

On 2026-10-24 source CI passed the Go suite and all browser phases (54 main,
1 idle-session and 1 renewal journey). The release frontend build and 827 local
tests passed, but the frontend audit reports Zod advisory GHSA-mrhx-c7xc-m3w5;
no frontend image promotion is included. Infra PR #1519 passed all 14 gates.
The staged connector reached two ready replicas, with shell-to-connector
readiness 200 and all protected owner probes 401, unknown route 404, and the
expected Via header. Runtime digest matched
`sha256:5dea64c9593f6f0b601ff8d0f4c1e69401cb291738d312b041a13f0bc84f0269`.
These checks establish the routing slice, not every domain workflow or absent
product API. Record public cutover and final boundary evidence in their rollout PRs.
