# ADR 0003: Validate Kora user identity at native AgentGateway

## Context

Kora's user-facing AI path is limited to 120 requests per minute with a burst of
20, buffers at most 16 MiB, has a 120-second request timeout, and runs two
AgentGateway replicas. The existing latency SLO is not documented, so the
identity boundary must not add a new workload or external authorization call.

The Kora API verifies the app user's Firebase token and delegates it in
`X-Kora-End-User-Token`. A2A calls retain that token so downstream agent and
model calls stay user-scoped. Model routes remove it before Vertex or another
provider receives the request. Bulk food-index embeddings are machine work and
do not require an app-user token.

AgentGateway owns its Istio certificate, originates HBONE, and deliberately
sets its generated pods to `istio.io/dataplane-mode: none`. Enrolling its
Service in an Istio destination waypoint caused the waypoint to attempt an
inbound ambient hop the native data plane does not terminate. A production
probe timed out. With the Service opted out, selector-based Istio JWT rules did
not enforce the custom L7 header; a missing or malformed token reached
AgentGateway before failing on the intentionally invalid model body.

The protected assets are user health context, model access, provider
credentials, and per-user authorization. Threats include an unauthenticated
caller with a leaked client key, a compromised workload, a forged Firebase
token, and accidental forwarding of a real user token to a model provider.

## Options considered

1. Put the native AgentGateway Service behind the namespace destination
   waypoint. Rejected because the generated pods are intentionally outside the
   ambient inbound data plane and the observed path timed out.
2. Rely on selector-based Istio `RequestAuthentication` for the custom header.
   Rejected as the primary identity control because the observed native path
   did not enforce the L7 JWT predicate.
3. Use AgentGateway's native JWT policy at named HTTPRoute rules. Chosen because
   it validates the Firebase token where routing is actually performed, can
   read the delegated custom header, and adds no proxy or external auth call.

## Decision

- Keep the generated Service on `istio.io/use-waypoint: none`, as required by
  the native AgentGateway transport, and retain namespace/pod NetworkPolicy
  allowlists plus strict AgentGateway API-key authentication.
- Fetch Firebase JWKS over TLS through a dedicated `AgentgatewayBackend` and
  cache it for five minutes.
- Give every model rule a stable name. Attach strict native Firebase JWT
  authentication to `conversation`, `structured`, and `default`, and to the
  complete `kora-a2a` route. Leave only `embedding` machine-scoped.
- Preserve `X-Kora-End-User-Token` on `kora-a2a`. The destination Kora waypoint
  revalidates it before the agent Service. Remove it on all provider-bound
  `kora-ai` rules.
- Retain the existing Istio workload policy as defense in depth, but do not
  treat it as the user-JWT enforcement point for the native gateway.

## Failure behavior

Missing, malformed, expired, wrong-issuer, or wrong-audience tokens fail closed
at AgentGateway on user-scoped rules. A JWKS refresh failure uses the cached key
set; if no usable set exists, user traffic fails closed. Registry or route-sync
outages leave the last accepted snapshot serving. The embedding exception
still requires the private network path and gateway client credential.

## Rollout, rollback, and cost

Publish the route names, JWKS backend, and JWT policy through Agentic Registry,
then reconcile the direct-Service Helm settings through Argo CD. Verify 401 for
a malformed token, rejection for a missing token on each user-scoped rule, a
successful signed-in A2A/model journey, no token on provider routes, Accepted
policies/routes, and a Programmed Gateway.

Rollback is one Git revert plus the Registry's prior revision. It removes the
user authorization boundary and is therefore only a short-term availability
measure. The design adds no pod or datastore; the only steady cost is a cached
JWKS HTTPS refresh per gateway replica.
