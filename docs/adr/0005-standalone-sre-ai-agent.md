# ADR 0005: Run the SRE investigator as an isolated shared AI agent

- Status: Proposed
- Date: 2026-08-30
- Owners: Tesserix AI platform, SRE, security

## Context

The global ADK runtime is the default execution boundary for new AI agents. Its
stable consumer endpoint is the internal `agentgateway-mcp` Service and its
general `/a2a/v1/` route. Consumers do not depend on the `devai` namespace or
on the current DevAI implementation behind `adk-runtime.devai.svc`; those are
backend ownership details that can change without changing the client
contract.

The SRE investigator is an explicit exception to generic runtime execution. It
must remain continuously addressable, use a dedicated Kubernetes service
account, and watch cluster metadata. Giving those permissions to the global
runtime would enlarge the blast radius for every hosted agent. The
investigator therefore runs as a standalone service while sharing the same
authenticated AgentGateway entry point, identity policy, rate-limit service,
and Vertex model gateway as the rest of the AI platform.

The initial operating envelope is two replicas, spread across zones and nodes,
with a PodDisruptionBudget of one and a rolling update that keeps all existing
replicas available. Admission is limited to 60 requests per minute per replica
with a burst of ten. An end-to-end request may take 90 seconds; model calls are
limited to 45 seconds and Kubernetes reads to 20 seconds. The initial model is
`gemini-2.5-flash` through the Workload-Identity-backed internal Vertex route.

## Decision

1. Run `sre-ai-agent` in the product-neutral `ai-agents` namespace with a
   dedicated service account. Its ClusterRole permits read-only pod, event,
   pod-log, and Deployment access; it cannot read Secrets or mutate resources.
2. Route only `/a2a/v1/sre-investigator` from the internal
   `agentgateway-mcp` Gateway to the standalone service. This more-specific
   route intentionally wins over the global runtime's general `/a2a/v1/`
   route. No public LoadBalancer or Ingress is created.
3. Require a strict Zitadel JWT containing `agentgateway.runtime` at the
   Gateway. AgentGateway replaces caller-controlled identity headers and
   injects a dedicated upstream bearer. The application independently checks
   that bearer before serving its Agent Card or A2A requests.
4. Admit model traffic only from
   `cluster.local/ns/ai-agents/sa/sre-ai-agent` to the existing private Vertex
   gateway route. NetworkPolicy and Istio authorization enforce workload
   admission. AgentGateway replaces the SDK bearer with
   Workload-Identity-backed GCP authorization before calling Vertex. There is
   no direct provider fallback.
5. Use distinct Secret Manager values for upstream and model-gateway
   credentials. Agentic Registry publication also uses a tenant-scoped
   `AGENTIC_REGISTRY_SRE_DEPLOY_KEY`; the existing Kora deploy key is not
   reused. Registry publication provides discovery, not execution authority.
6. Keep the chart disabled until the reviewed source PR is merged and its
   immutable `ai-agents-sre` digest is pinned. Enabling by a mutable tag is not
   allowed.

## Failure behavior

One unavailable replica removes redundancy and pages as a warning; zero
available replicas pages as critical and AgentGateway returns an upstream
failure. Invalid or missing JWTs and upstream credentials fail closed. A rate
limiter outage fails closed. A missing ExternalSecret prevents a healthy
rollout. Model-gateway or Vertex failure is returned as a dependency error and
does not cause direct Internet egress. Kubernetes API timeouts yield bounded,
read-only diagnostic failure rather than a mutation or an unverified answer.

The general global runtime route remains available if this specific agent is
disabled. Conversely, a global runtime backend failure does not silently send
the SRE request to another agent because the specific route has one reviewed
backend.

## Cost

The fixed cost is two small pods at 256 MiB requested and 512 MiB limited each,
plus negligible shared Gateway, metrics, and Secret Manager overhead. No new
load balancer, database, or dedicated model gateway is created. Vertex token
usage is the dominant variable cost and is bounded by authenticated per-replica
request limits. The isolation cost is accepted because sharing Kubernetes
credentials with the global runtime would create a materially larger security
and operational blast radius.

## Rollout

Merge the agent source only after local and protected CI pass, then pin the
published image digest. Provision both Secret Manager values without exposing
them and provision the SRE-only Registry deploy key. Merge the GitOps change,
verify two ready replicas in distinct zones, PDB health, ExternalSecret Ready
conditions, route Accepted/ResolvedRefs conditions, and positive plus negative
authentication tests. Publish the Registry manifest only after the live route
passes those checks.

## Rollback

First remove or disable the specific HTTPRoute in Git so no new calls reach an
unhealthy or vulnerable backend. After Argo CD reconciles that change, revert
the workload image or set the chart back to disabled and reconcile. Preserve
logs and conditions for the incident. Do not delete credentials, rotate
secrets, or remove RBAC as part of routine rollback; each is a separate,
explicitly approved action. Target route withdrawal is five minutes.

## Consequences

New ordinary agents still use the global, product-neutral ADK runtime. The SRE
investigator has a stable shared AI-platform address without granting its
cluster visibility to other agents. The trade-off is one additional workload,
specific route, credential set, and on-call surface that the AI platform must
maintain.
