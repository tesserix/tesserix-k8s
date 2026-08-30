# SRE AI investigator

Owner: `ai-platform`

The investigator is an internal, read-only agent in `ai-agents`. It is reached
through `agentgateway-mcp` in `agentgateway-system` at
`/a2a/v1/sre-investigator`. Start with read-only discovery and confirm the
active GCP account, project, Kubernetes context, namespace, and intended target
before proposing a production change. Never print Secret values or tokens.

## Triage

1. Confirm the Argo CD Application is Synced and Healthy. Inspect the
   `sre-ai-agent` Deployment, two ready pods, zone/hostname placement, Service
   endpoints, and PodDisruptionBudget in `ai-agents`.
2. Inspect the `sre-ai-agent` HTTPRoute, AgentgatewayBackend, and
   AgentgatewayPolicy in `agentgateway-system`. All parent and backend
   conditions must be Accepted, Programmed, and ResolvedRefs where applicable.
3. Inspect only the Ready conditions of `sre-ai-agent` ExternalSecrets. Do not
   read the generated Kubernetes Secrets to compare credentials.
4. Separate failures by boundary: 401/403 means Zitadel role, audience,
   upstream bearer, or mesh identity; 429 means local/global request limits;
   502/503 means service endpoints, AgentGateway, the model gateway, Vertex, or
   rate-limit dependency; timeout means the 20-second cluster read,
   45-second model call, or 90-second route budget was exhausted.
5. Verify the model path remains
   `ai-gateway.agentgateway-system.svc.cluster.local:8080/vertex/v1` and that
   only `cluster.local/ns/ai-agents/sa/sre-ai-agent` is admitted. Do not test by
   bypassing AgentGateway or adding temporary broad policy.
6. Use impersonated `kubectl auth can-i` checks to confirm the service account
   can get/list/watch the reviewed resources and cannot read Secrets or create,
   update, patch, or delete resources. Do not attach a broader role during an
   incident.
7. Correlate sanitized AgentGateway and application logs by trace/request ID.
   Do not log prompts, cluster payloads, API keys, bearer tokens, or Secret
   contents.

## Recovery

- A single unavailable replica should recover through the Deployment while the
  other replica serves traffic. Check scheduling and topology constraints
  before proposing more capacity.
- A rejected token is not recovered by weakening authorization. Correct the
  Zitadel grant or credential projection through its owning workflow.
- A stale image is recovered by pinning a reviewed immutable digest in Git.
  Never deploy a mutable tag or imperatively edit the Deployment.
- Registry publication is independent of execution. If discovery is stale,
  repair the SRE-only publisher after the live route is healthy; do not reuse
  another tenant's deploy key.

## Rollback

In GitOps, remove or disable the HTTPRoute first and wait for Argo CD to
reconcile it. Then revert the workload image or set the `sre-ai-agent` chart to
disabled. This prevents new calls before changing the backend. Production
rollback, secret rotation, RBAC removal, or resource deletion each requires
specific approval. Do not use direct `kubectl apply`, `edit`, `scale`, or
`delete` against Argo-owned resources.

## Escalation and evidence

Page `ai-platform` immediately for zero available replicas, possible
cross-tenant access, an authorization bypass, unexpected mutation capability,
or evidence that provider traffic bypassed the model gateway. Preserve the
Argo revision, immutable image digest, pod placement, PDB status,
ExternalSecret conditions, Gateway API conditions, sanitized request IDs, and
alert timeline.
