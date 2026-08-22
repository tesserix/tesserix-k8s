# ADR 0003: Enforce Kora user identity at the AI waypoint

## Context

Kora's user-facing AI path is limited to 120 requests per minute with a burst of
20, buffers at most 16 MiB, has a 120-second request timeout, and runs two
AgentGateway replicas. The existing latency SLO is not documented, so this
change must not add a new workload or an external authorization hop.

The Kora API verifies the app user's Firebase token and delegates it in
`X-Kora-End-User-Token`. A2A calls must retain that token so the agent service
and its subsequent model call remain user-scoped. Model routes must remove the
header before Vertex or another provider receives the request.

The generated `kora-ai` Service opted out of the namespace waypoint while its
`RequestAuthentication` and `AuthorizationPolicy` selected the generated
gateway pods. In ambient mode that path did not provide the L7 waypoint needed
to validate the custom JWT header. A production probe showed that requests
with a missing or malformed delegated token reached AgentGateway instead of
being rejected at the identity boundary.

The protected assets are user health context, model access, provider
credentials, and per-user authorization. Threats include an unauthenticated
mesh caller, a compromised workload outside Kora, a forged Firebase token, and
accidental forwarding of a real user token to a model provider.

## Options considered

1. Keep pod selectors on the waypoint-opted-out Service. Rejected because the
   observed path did not enforce the L7 JWT predicates.
2. Reimplement Firebase JWT authorization inside AgentGateway. Rejected because
   it duplicates the mesh identity policy and does not combine workload SPIFFE
   identity and the app-user principal at one existing trust boundary.
3. Enrol the generated Service in the existing namespace waypoint and attach
   both Istio policies to that Service. Chosen because it uses the established
   ambient Service policy pattern and adds no deployment or external call.

## Decision

- Label the generated `kora-ai` Service with
  `istio.io/use-waypoint: waypoint`.
- Attach `RequestAuthentication` and `AuthorizationPolicy` with a Service
  `targetRef`, not a workload selector.
- Require both the allowlisted Kora workload SPIFFE principal and a verified
  Firebase request principal for generative and A2A traffic. Keep the existing
  path-specific machine exception for bulk embeddings.
- Admit only the namespace waypoint to the AgentGateway pods at the Kubernetes
  NetworkPolicy boundary. The waypoint preserves the original workload
  principal for L7 authorization.
- Preserve `X-Kora-End-User-Token` on `kora-a2a` and remove it on every
  provider-bound `kora-ai` rule.

## Failure behavior

If the waypoint or Firebase JWKS validation is unavailable, user-scoped AI
requests fail closed before AgentGateway. Existing Registry or route-sync
outages leave the last accepted gateway snapshot serving. Duplicate Registry
reconciliation is idempotent. AgentGateway or Vertex failure remains a bounded
request failure under the existing timeout and does not bypass authorization.

## Rollout, rollback, and cost

Roll out through the `kora-ai-gateway` Argo application. Verify that missing and
malformed delegated tokens are denied, a short-lived signed-in user token can
complete A2A and model calls, both HTTPRoutes remain Accepted, and the Gateway
remains Programmed. Rollback is one Git revert, though it restores the known
authorization gap and is therefore only a short-term availability measure.

The change adds no pods, datastore, secret, or external request. Its steady
cost is one additional hop through the already-running namespace waypoint.
