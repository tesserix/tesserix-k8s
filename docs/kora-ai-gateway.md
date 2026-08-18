# Kora private AI gateway rollout

## Decision

Kora text generation uses a private Agent Gateway v1.4.1 data plane in the
`agentgateway-system` namespace. Embeddings, image identification, and
transcription remain direct Vertex/Gemini calls. Agent Gateway authenticates
Kora, applies request limits and prompt guards, invokes the private token
optimizer over Envoy ExtProc, and then routes to Vertex, Anthropic, or xAI. Kora's
`ai_usage_events` remains the billing and budget reconciliation authority;
gateway and optimizer telemetry is operational evidence, not a second ledger.

```text
Kora API
  -> private ClusterIP Agent Gateway
       -> ExtProc token-optimizer
            -> RTK proof: pass through
            -> JSON/MCP/RAG/conversation: Headroom
            -> older plain text: LLMLingua-2
       -> structured JSON: Vertex -> Anthropic -> xAI
       -> conversation: Anthropic -> Vertex -> xAI
```

RTK is a producer-side CLI wrapper. The gateway never reconstructs or reruns a
shell command. It accepts RTK pass-through only when the trusted
`x-kora-rtk-applied` classification is true; Kora always sends false. Missing
or unknown context classifications bypass optimization instead of guessing.

## Capacity and SLO assumptions

The initial gate assumes 10 requests/second peak, request bodies no larger than
256 KiB, and two gateway plus two optimizer replicas. Each optimizer permits
one compression at a time because the measured LLMLingua-2 working set peaked
near 1.52 GB. The chart therefore requests 2 GiB and limits 3 GiB per optimizer
pod. Gateway requests 256 MiB per pod. These are starting limits, not evidence
of production capacity.

The target is 99.9% monthly availability for the AI path. Gateway overhead
excluding model and optimization time should stay below 50 ms p99. Compression
has a 750 ms deadline and fails open. The current 4,005-token M1 benchmark was
about 874 ms observed maximum, so compression promotion is blocked until the
representative quality set and production-class latency gate pass.

## Trust boundaries and data handling

The valuable assets are customer prompts, provider credentials, the Kora-to-
gateway client key, and usage/cost records. Relevant threats are a compromised
application pod, an authenticated user attempting prompt injection, a
compromised dependency, and an operator with excess secret access.

- The gateway is a ClusterIP and NetworkPolicy admits client traffic only from
  Kora API pods in the `kora` namespace. Kora egress is limited to the
  `kora-ai` gateway on its application and ambient-mesh ports. Istio
  authorization additionally requires the exact
  `cluster.local/ns/kora/sa/kora-kora-api` workload identity on port 8080.
- Strict API-key authentication reads a platform key from GCP Secret Manager
  through two namespace-local ExternalSecrets. Kora receives only the client
  key; Anthropic and xAI credentials exist only in `agentgateway-system` and
  cannot authenticate as clients.
- Vertex uses ambient Google credentials through Workload Identity; no service
  account JSON is stored in Git or Kubernetes. The data-plane KSA is `kora-ai`
  and impersonates the existing `agentgateway-llm` GSA only after an explicit
  Workload Identity binding is approved.
- ExtProc receives typed attributes created by Agent Gateway. Client headers
  are not read directly by the optimizer.
- Prompt and response bodies, API keys, user identifiers, and credentials are
  excluded from logs, metrics, and traces.
- Credit-card and SSN prompts are rejected. Email and phone values are masked.
  Two narrowly scoped instruction-override patterns are rejected only on this
  Kora route; there is no broad keyword denylist over structured tool data.

## Failure behavior

| Failure | Behavior |
| --- | --- |
| Optimizer unavailable, times out, or rejects an unsafe mutation | ExtProc fails open and sends the original prompt |
| Eligible prompt remains over the hard budget | Optimizer returns stable HTTP 422; callers must not retry |
| Primary provider is unhealthy | Agent Gateway advances to the next priority group |
| All providers are unavailable | Kora receives the gateway error; application deadlines bound the call |
| Client API key is absent or invalid | Gateway rejects before provider routing |
| Provider secret is absent | That backend is not usable; do not enable Kora cutover |
| OTLP is unavailable | AI traffic continues; telemetry export degrades |

## Release gates

The two Kora AI child Applications deliberately have no automated sync. Do not
manually sync them, and do not set `AI_GATEWAY_ENABLED=true`, until all of the
following are true:

1. Verify the pinned token-optimizer digest
   `sha256:8991783841b991c6cd09537009dd10849f1ed87dc844b1b9caed92f72d6bda6d`
   matches the successful release workflow and retain its SBOM/provenance.
2. Confirm `prod-kora-ai-gateway-api-key` and the existing
   `prod-devai-anthropic-api-key` remain available through Secret Manager.
   xAI stays disabled until a real `prod-kora-xai-api-key` credential exists;
   never create or substitute a placeholder credential.
3. Apply the Terraform-managed Workload Identity user binding for
   `agentgateway-system/kora-ai` and confirm the existing `agentgateway-llm`
   GSA retains only `roles/aiplatform.user` at project scope. The original
   `agentgateway-system/agentgateway` binding remains in place for the shared
   data plane.
4. Confirm Agent Gateway and Gateway API CRDs are healthy, then verify the
   `AgentgatewayBackend`, `HTTPRoute`, and every `AgentgatewayPolicy` reports an
   accepted/attached condition.
5. Run golden evaluations for answer quality, JSON schema preservation,
   prompt-injection behavior, hard-budget responses, provider failover, and
   usage reconciliation. Promotion requires no statistically meaningful
   quality regression and the agreed token-saving threshold.
6. Canary by enabling the Kora feature flag for a controlled deployment and
   compare token counts, cost, latency, 4xx/5xx rates, and fallback rates.

Rollback is a single Kora values change: set `aiGateway.enabled` to false. That
restores the existing Gemini/OpenAI-compatible routing while leaving the
gateway available for diagnosis. Do not delete CRDs during rollback. Keep
Agent Gateway xDS mode `either` during the v1.0.1-to-v1.4.1 transition; move to
TLS-only only after every data plane is confirmed on v1.4.1.

## Cost envelope

The initial optimizer reservation is 4 GiB of memory across two replicas and
the gateway reservation is 512 MiB across two replicas. If the existing GKE
nodes have that headroom, the immediate infrastructure cost is shared capacity;
otherwise the scheduler may require additional node capacity. The only measured
token result so far is a 44.7% reduction on one 4,005-token CPU benchmark, so it
is not a production savings forecast. Promotion requires representative Kora
quality evaluations and provider-specific input/output token accounting against
the authoritative `ai_usage_events` ledger.
