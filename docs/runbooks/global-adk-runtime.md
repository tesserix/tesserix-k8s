# Global ADK runtime

Owner: Tesserix AI platform

The consumer endpoint is
`http://agentgateway-mcp.agentgateway-system.svc.cluster.local:8080`.
AgentGateway runs in `agentgateway-system`; the warm backend pool and stable
`adk-runtime` alias run in `devai`.

Start with read-only inspection of the active account, project, kube context,
and both namespaces. Never print access tokens, Kubernetes Secret data, or the
GCP Secret Manager value.

## Triage

1. Check that `agentgateway-mcp` has two available replicas on different zones,
   its PDB allows one disruption, and its Service has ready endpoints.
2. Check that `devai-api` has at least three ready replicas across zones,
   `adk-runtime` selects those pods, and its PDB has `minAvailable: 2`.
3. Inspect `HTTPRoute/global-adk-runtime`, both `AgentgatewayPolicy` objects,
   `AgentgatewayBackend/global-adk-runtime`, and their Accepted/ResolvedRefs
   conditions.
4. Check both ExternalSecrets and only their Ready conditions. A missing
   `prod-global-adk-runtime-upstream-token` or mismatched projection causes 401;
   do not read the credential to compare it manually.
5. Separate 401 (issuer, audience, role, expiry, upstream projection), 404
   (capability not admitted), 409 (human gate), 429 (rate limit), and 503
   (Registry, model gateway, or runtime composition unavailable).
6. Correlate AgentGateway access logs by verified subject/client id and DevAI
   logs by trace id. Do not log request bodies or tokens.
7. For missing cross-replica live events, inspect Redis connectivity and relay
   errors. Durable run state and per-run logs remain the recovery source.

## Recovery

- A failed backend pod should be replaced automatically. If two or more remain
  unavailable, stop onboarding and diagnose scheduling, readiness, image pull,
  configuration, Redis, and Registry dependencies before considering a rollout.
- A failed gateway pod should leave one serving replica. If the Service has no
  ready endpoint, callers must fail closed; never direct them to `adk-runtime`.
- If only one client fails, verify its Zitadel role and namespace admission.
  Do not rotate the shared upstream bearer for a caller-specific problem.
- If a release is incompatible, remove the global route first and revert the
  owning GitOps release. There is no database migration to reverse.

## Escalation and revocation

Page the platform owner when either HA alert persists, identity may have been
forged, another tenant may be exposed, or the shared upstream bearer may be
compromised. Revoke a normal caller by removing its machine role/client and
namespace egress admission. An already issued JWT remains valid until its short
expiry. Rotate the shared bearer only for compromise of the AgentGateway-to-
runtime trust boundary, because rotation interrupts every consumer.
