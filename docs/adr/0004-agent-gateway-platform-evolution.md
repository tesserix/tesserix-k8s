# ADR 0004: Stabilize AgentGateway and build a portable gateway control plane

- Status: Proposed
- Date: 2026-08-23
- Owners: Tesserix platform, identity, AI platform

## Context

Production runs AgentGateway v1.4.1 in
`agentgateway-system`. The controller and all three generated data planes are
healthy and programmed:

- `agentgateway-mcp` for Registry-exported MCP routes;
- `ai-gateway` for shared DevAI model/provider routes;
- `kora-ai` for Kora model, embedding, and A2A routes.

Agentic Registry owns the portable backend, route, and policy desired state.
`agentgateway-route-sync` verifies the Registry export and applies it every five
minutes. Helm still owns Gateways, `AgentgatewayParameters`, workload/network
security, the Kora A2A route, rate-limit infrastructure, and telemetry ingress.
The standalone `agentgateway-console` is a fourth process with no
`XDS_ADDRESS`; its writable configuration is stored in PostgreSQL.

The initial production envelope is 10 requests/second peak, 256 KiB ordinary
request bodies, 99.9% monthly AI-path availability, and less than 50 ms p99
gateway overhead. Kora's optimizer has a 750 ms fail-open deadline. Public UI
traffic is below 5 requests/second per host with a 300 ms p99 edge target. MCP
is limited to 120 requests/minute/subject. Public models are limited to 60
requests/minute/subject and 200,000 tokens/hour/subject.

The current system provides more than HTTP ingress. It owns multi-provider
model selection and fallback, Vertex Workload Identity signing, MCP and A2A
routing, JWT and API-key enforcement, prompt guards, request and token limits,
ExtProc optimization, and OTLP usage evidence. A replacement must preserve each
capability or explicitly retire it.

## Audit findings

The read-only production audit used account `unidevidp@gmail.com`, project
`tesseracthub-480811`, context
`gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`, and namespace
`agentgateway-system`.

1. Zitadel login succeeds, but the public fallback was wired to the legacy
   OAuth proxy. `/` reached Agentic Registry and `/ui`, `/api`, and
   `/config_dump` reached the xDS `ai-gateway`. The standalone console service
   was never selected. This contradicts `docs/agentgateway-console.md`.
2. The standalone console uses `https://agentgateway.tesserix.app/oauth/callback`,
   while the reconciled Zitadel client declared only `/oauth2/callback` for the
   legacy proxy. Both redirects are required during transition.
3. AgentGateway logs the fully rendered standalone config at info during
   startup. That config contains Secret-backed PostgreSQL URLs. The startup
   scope must be suppressed without disabling normal request telemetry.
4. Kora's generated Service opts out of the destination waypoint because a
   previous direct enrollment timed out with AgentGateway's native HBONE data
   plane. Its selector-based Istio `AuthorizationPolicy` therefore reports
   `UnsupportedValue`: ztunnel omits `requestPrincipals`, methods, and paths.
   Native `kora-user-auth` correctly enforces Firebase JWTs on the user-scoped
   AgentGateway route rules, but the Istio policy must not be represented as a
   working L7 enforcement point.
5. A 24-hour gateway aggregate contained 7,399 successful Kora responses, 64
   embedding `429` responses, six JWT rejections, and six malformed-request
   `503` responses. The JWT failures show fail-closed native validation. The
   embedding throttles show that bulk indexing needs a quota independent from
   interactive user traffic.
6. The remote rate-limit service is healthy now, but one replica restarted
   three times after Valkey connection resets. Public gateway policies fail
   closed, so a Valkey outage becomes a model/MCP availability outage.
7. MCP per-server scopes are implemented but disabled until matching Zitadel
   grants exist. The capability prober is also disabled pending its image and
   machine client. Catalog declarations are therefore not yet continuously
   verified against the served tools.
8. The usage path is
   `AgentGateway -> ai-usage-ingest -> NATS JetStream -> ai_usage_events -> platform-api -> console`.
   Each hop can fail without affecting gateway health. An ingest pod being
   ready proves only that it is listening, not that the console ledger is
   fresh.
9. `charts/thirdparty/agentgateway` is a deprecated v1.2.1 wrapper scaled to
   zero. Production is installed from the upstream v1.4.1 OCI charts. The old
   wrapper must not be referenced by an Argo application and should be removed
   only after repository consumers confirm they do not use it.
10. No Crossplane CRDs are installed in production.

## Identity contract

User identity and workload identity are different controls and both are
required for user-owned health data:

```text
Firebase login
  -> Kora API verifies the ID token and object ownership
  -> delegates the signed token in X-Kora-End-User-Token
  -> L7 identity boundary verifies issuer, audience, expiry, and subject
  -> AgentGateway re-verifies the signed token on user-scoped route rules
  -> route/model selection
  -> remove the delegated token before provider egress
```

The gateway must authorize the authenticated application user, not infer a user
from a source IP, namespace, or arbitrary header. The mesh identity remains a
defence-in-depth admission control so a compromised unrelated workload cannot
spend model capacity. Machine-only food-index embeddings are the explicit
exception and require a separate workload-scoped quota.

A waypoint is a valid L7 identity boundary only when it is demonstrably on the
request path. Attaching the native AgentGateway Service directly is not the
current solution because that path timed out and the generated pods deliberately
use `istio.io/dataplane-mode: none`. The follow-up experiment is a dedicated,
ambient-compatible identity-front-door Service: the waypoint verifies and
forwards the original signed token, and the native gateway independently
revalidates it. It may be promoted only if signed-in A2A, model, embedding, and
failure-path tests pass at 10 requests/second and add less than 20 ms p99. Do
not trust a waypoint-derived plain user header or disable native JWT validation.

## Capability comparison

| Capability | Solo AgentGateway | GKE Gateway + Cloud Service Mesh | Apigee X/hybrid | GCP API Gateway | Envoy Gateway + extensions | Direct Vertex + Model Armor |
| --- | --- | --- | --- | --- | --- | --- |
| Private GKE routing, mTLS, workload identity | Yes | Strong | Hybrid-dependent | Poor fit | Strong | Not a gateway |
| JWT/OAuth and per-route authorization | Yes | Strong with Istio policy | Strong | Strong for OpenAPI APIs | Requires ext-auth/policy | Application-owned |
| Requests and token quotas per verified subject | Yes | Request limits need an extension; no native model-token accounting | Request quota strong; model tokens custom | Request quotas only | Custom rate-limit descriptors | Application-owned |
| Multi-provider model normalization and fallback | Yes | No | Custom policy/backend | No | Custom filters/adapters | Vertex only |
| Vertex Workload Identity signing | Yes | Backend/application-owned | Custom integration | Backend-owned | Custom backend auth | Native |
| MCP and A2A protocol routing | Yes | HTTP routing only | HTTP routing only | HTTP routing only | Custom extensions | No |
| Prompt/response guardrails | Yes | Add Model Armor/custom filter | Policies plus Model Armor/custom callout | No | Custom filter/Model Armor | Model Armor for supported Vertex flows |
| ExtProc token optimization | Yes | Envoy-specific integration required | Custom callout | No | Yes, with owned extension | No |
| OTLP AI usage attributes | Yes | Generic telemetry; model attributes custom | Analytics strong; ledger mapping custom | Generic metrics | Custom but portable | Vertex usage only |
| Registry-driven hot policy | Existing | Adapter required | Adapter required | Adapter required | Adapter required | Model catalog only |

GCP API Gateway is not a drop-in replacement for this estate. It is designed
for OpenAPI-described public APIs and would leave model normalization, MCP,
A2A, token accounting, ExtProc, provider fallback, and private GKE service
integration to custom components. Apigee is the strongest GCP-managed API
management option, but it still needs an agent/model policy layer and adds a
new cost and latency envelope. GKE Gateway and Cloud Service Mesh are the best
GCP-native network and identity substrate, not a complete agent gateway.

## Decision

1. Stabilize AgentGateway now. Route the public browser fallback to the
   standalone console on port 8082, allow both transition callback URIs, and
   suppress the secret-bearing startup config log.
2. Keep native signed-user JWT validation on Kora user routes. Treat the
   selector-based Istio L7 policy as non-enforcing until a waypoint front door
   passes the experiment above. Preserve workload NetworkPolicy/API-key
   admission and provider-bound token removal.
3. Keep Agentic Registry as the hot desired-state owner. Define a canonical,
   vendor-neutral gateway contract for providers, model capabilities, route
   rules, identity requirements, guardrails, timeouts, quotas, and telemetry.
   Reconcile that contract through adapters: Solo today, then a GCP/Envoy or
   Apigee adapter if evaluation succeeds.
4. Do not move the full data plane directly to GCP API Gateway. Evaluate GKE
   Gateway/Cloud Service Mesh as the identity/network front door and Envoy
   Gateway or Apigee as a possible policy data plane. Use Direct Vertex and
   Model Armor only for the Vertex backend and guardrail subset.
5. Separate interactive per-user limits from machine embedding/indexing
   limits. Interactive policies key distributed limits by verified `jwt.sub`;
   indexing keys by a verified workload/API-key identity. No user journey may
   share a local bucket with bulk vector ingestion.
6. Integrate management into Tesserix Console through `platform-api`, not by
   granting the browser Kubernetes, Registry deploy-key, or Crossplane access.
   Reads aggregate Gateway/route/policy health, Registry reconciliation status,
   usage freshness, quota health, and provider state. Writes create an audited
   canonical Registry revision and display asynchronous adapter status.

## Crossplane boundary

Crossplane may own slow-moving cloud infrastructure:

- Google service accounts and least-privilege IAM bindings;
- Secret Manager secret metadata and workload access, never secret values in
  Git or composition outputs;
- VPC, Private Service Connect, DNS, certificates, Cloud Armor, and managed
  gateway resources;
- environment compositions for standard SLO alerts, budgets, and quota
  configuration.

Crossplane must not own Registry artifacts, per-user authorization decisions,
model fallback order, MCP server publication, or five-minute route convergence.
Those remain Registry/GitOps concerns. Argo CD installs and upgrades Crossplane;
Crossplane must not server-side-apply the same Kubernetes objects as Argo or
Registry. ProviderConfig uses Workload Identity and no long-lived service
account key.

Installing Crossplane is a production platform change. It requires a separate
design review covering CRD lifecycle, provider pinning, RBAC, reconciliation
blast radius, backup/restore, and an explicitly approved rollout.

## Console API contract

The console should expose these server-side views:

- gateways: programmed/accepted status, version, replicas, and last reconcile;
- routes/policies: canonical revision, adapter revision, attachment, and drift;
- identity: issuer/audience/role or scope requirements, never raw tokens;
- providers: enabled state, capability, region, credential reference health,
  and breaker/fallback counters;
- usage: last event timestamp, requests/tokens/cost source, and unpriced count;
- limits: configured subject/workload quotas, limiter/Valkey health, and `429`
  counts;
- MCP: Registry status, last successful probe, verified capabilities, and
  required server scope.

Every mutation records actor, tenant, before/after revision, approval policy,
and reconciliation outcome. The API returns `202 Accepted` for asynchronous
changes and never claims success until the adapter reports the applied
revision.

## Migration and rollback

1. **Stabilize:** land the console route/callback/log fixes; verify a fresh and
   one-hour-old Zitadel session, console writes, provider prefixes, and absence
   of rendered secrets in new pod logs.
2. **Close evidence gaps:** alert on usage-ledger freshness, Registry export
   age, route/policy attachment, rate-limit dependency health, and disabled MCP
   scopes/probes. Give embeddings their own quota.
3. **Canonical contract:** make Registry export vendor-neutral objects plus a
   Solo adapter. The console writes only canonical revisions.
4. **Shadow:** deploy the candidate adapter and data plane privately. Use
   synthetic and consented golden traffic; never mirror raw health prompts by
   default. Compare authorization, answers, provider choice, tokens, p50/p95/p99
   overhead, error rate, and cost.
5. **Canary:** route 1%, 5%, 25%, then 100% of explicitly selected traffic.
   Each stage runs for at least one peak window and automatically stops on an
   authorization regression, greater than 0.1% absolute 5xx increase, p99
   overhead above 50 ms, or usage-ledger divergence.
6. **Decommission:** after 30 stable days, capture the final xDS/Registry state,
   obtain explicit approval, remove public xDS admin paths, then remove unused
   proxy/wrapper resources. Never delete AgentGateway CRDs as part of rollback.

Rollback changes the Istio route back to Solo, selects the last known-good
Registry revision, and retains the existing xDS snapshot. Target recovery is
under five minutes. Credential rotation, production cutover, xDS removal, and
resource deletion each require action-specific approval.

## Consequences

The immediate change fixes the observed console path without risking model or
MCP traffic. Solo remains a temporary but functional data plane while Tesserix
removes vendor lock-in from the control-plane contract. GCP services can take
over the network, identity, IAM, and guardrail subsets incrementally. The cost
is a period of dual adapters and explicit conformance testing; that cost is
smaller than recreating hidden AI/MCP behavior after a direct gateway swap.
