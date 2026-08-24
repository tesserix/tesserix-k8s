# agentgateway console (standalone)

`charts/apps/agentgateway-console` runs agentgateway v1.4.1 **without**
`XDS_ADDRESS`. That single difference is the whole point of the chart.

## Why standalone

`ui.rs` decides the console's mode from one condition:

```rust
gateway_mode: if app.state.xds.address.is_some() { Xds } else { Standalone }
```

The UI reads that from `/api/runtime`; `useConfigDumpMode()` turns `xds` into
"dump mode", and `Shell.tsx` then hides the entire LLM group (Models, Providers,
Policies, Guardrails, Virtual API Keys, Costs, Analytics, Logs, Client Setup,
Chat Playground), the MCP group (Servers, Policies, Tool Playground), and Raw
Configuration. Under the controller the config is owned by xDS, so every write
path is disabled by design. No Zitadel role and no proxy allow-list changes
that — only dropping `XDS_ADDRESS` does, which the `Gateway` +
`AgentgatewayParameters` mechanism cannot do because the controller injects it.
Hence a plain Deployment.

## Config ownership

| Layer | Owns |
|---|---|
| `files/config.yaml` (git) | listeners, OIDC/JWT/authorization, baseline providers and wildcard model mappings, global guardrails and limits, and the devai and kora routes |
| GCP Secret Manager + ESO | PostgreSQL/OIDC credentials and the standalone Anthropic, OpenAI, and Gemini platform keys; secret values are rendered only into the Kubernetes Secret and pod environment |
| GKE Workload Identity | ambient Vertex credentials for the standalone, DevAI, and Kora data planes; no service-account JSON is mounted |
| Postgres (`storage.mode: hybrid`) | console-created overlays, virtual API keys, and the request-log store behind Costs / Analytics / Logs |
| Agentic Registry | production xDS backend, route, and policy desired state for `ai-gateway`, `kora-ai`, and `agentgateway-mcp` |

`llm.policies.apiKey` and `mcp.policies` must exist as objects in the file or
the DB-backed resources are rejected (`config_store.rs`).

The file is passed through Helm with `.Files.Get`, which does **not** re-template
it, so its `{{ .pgPassword }}` / `{{ .oidcClientId }}` / `{{ .oidcClientSecret }}`
placeholders survive to External Secrets, which renders the finished config into
a Secret. Provider entries refer only to environment-variable names; ESO copies
the platform key values from Secret Manager into that same Kubernetes Secret.
Editing the config therefore never exposes a credential to Helm or Git.

## Listeners

| Port | Name | Auth |
|---|---|---|
| 8080 | `mesh` | Istio mTLS admission; standalone model calls also require a Zitadel JWT, role authorization, and virtual key |
| 8081 | `public` | Zitadel JWT `strict` + CEL role check + virtual key + remote rate limit |
| 8082 | `console` | native OIDC against Zitadel + CEL role check |
| 15021 | readiness | probes |

The console's OIDC is agentgateway's own (`ui.policies.oidc`), not oauth2-proxy,
so the 8 KiB request-head cap on the admin listener — the source of the earlier
HTTP 431 — is out of the path entirely.

## Provider and model baseline

The standalone console declares reusable Anthropic, OpenAI, Gemini, and Vertex
providers and wildcard models named `anthropic/*`, `openai/*`, `gemini/*`, and
`vertex/*`. The prefix is stripped before provider egress. Anthropic, OpenAI,
and Gemini use platform credentials synced by ESO; Vertex uses ambient
Application Default Credentials from the `agentgateway-llm@` Workload Identity.

LLM requests require both controls:

- a Zitadel bearer JWT with audience `387190457387450503` and the
  `agentgateway.models` role, which identifies and authorizes the caller;
- a virtual API key in `x-tesserix-virtual-api-key`, which provides a separately
  revocable gateway credential and usage identity.

Virtual keys are created and rotated in the console and stored in Postgres;
their values are never committed. The dedicated header deliberately does not
reuse `Authorization`, which remains available to JWT and legacy provider-key
flows. Missing or invalid JWTs, roles, or virtual keys fail closed. Global
request guardrails reject credit-card, SSN, and common prompt-injection patterns,
mask email and phone input, and mask credit-card, SSN, email, and phone output,
including streaming responses.

## Product integration

**devai** keeps its current xDS URL on `ai-gateway:8080`. `/anthropic`,
`/openai`, `/vertex`, `/gemini`, `/groq`, `/openrouter`, and `/nemoclaw` are
Registry-owned provider routes. The DevAI Vertex route uses the existing
`agentgateway-llm@` Workload Identity. The valid
`prod-devai-vertex-api-key` remains synchronized through ESO as a rollback
credential, but is not injected by the active Solo v1.4.1 route.

**kora** keeps its current xDS URL on `kora-ai:8080`. The gateway verifies the
delegated Firebase user JWT, removes it before provider egress, applies prompt
guardrails and the `token-optimizer:18080` extProc, and routes generation and
embeddings to Vertex through Workload Identity with Anthropic fallback. The A2A
route continues to use separate ESO-managed client and upstream agent keys.

**agentic registry** remains the production owner of xDS backends, routes, and
policies. `agentgateway-route-sync` pulls the signed desired state every five
minutes and applies it idempotently. The standalone file baseline does not cut
over or replace those generated gateways.

## Onboarding a product

New production consumers should be registered in Agentic Registry and attached
to the generated xDS gateway. Direct standalone access is reserved for an
explicit migration or diagnostic path. Add one entry to `consumers` in the
chart values to admit its workload identity to the standalone mesh listener;
that entry drives both the AuthorizationPolicy principals and NetworkPolicy:

```yaml
consumers:
  - namespace: mark8ly
    serviceAccounts:
      - otto
```

The application must also forward the signed logged-in user JWT and a provisioned
virtual key. mTLS proves which workload made the call; it does not replace user
authorization. Gateway-owned core providers need no caller provider key. A
legacy passthrough provider route may still carry its provider credential in
`Authorization`; the virtual key always uses its dedicated header.

```
http://agentgateway-console.agentgateway-system.svc.cluster.local:8080/<provider>
```

`<provider>` is one of `anthropic`, `openai`, `gemini`, `vertex`, `groq`,
`openrouter`, `nemoclaw`. Paths below the prefix are the provider's own, so
`/openai/v1/chat/completions` works unchanged. `vertex` needs no key: the
gateway signs with its own Workload Identity, so the caller's KSA needs no GCP
binding of its own.

Per-request attribution flows through headers the access log records:
`x-devai-tenant-id`, `x-devai-user-id`, `x-devai-run-id`, `x-devai-agent`,
`x-kora-ai-capability`.

External provider prefixes on `agentgateway.tesserix.app` still terminate on
the xDS `ai-gateway:8081`, where native Zitadel JWT policy and per-subject remote
rate limits apply. Browser fallback alone terminates on the standalone console
at port 8082.

## Prerequisites

1. GCP Secret Manager keys `prod-agentgateway-postgresql-password`,
   `prod-agentgateway-oidc-cookie-secret` (32 bytes, hex),
   `prod-devai-anthropic-api-key`, `prod-devai-openai-api-key`, and
   `prod-devai-gemini-api-key`.
2. Zitadel: add `https://agentgateway.tesserix.app/oauth/callback` to the
   agentgateway admin UI application's redirect URIs, and grant the
   `agentgateway.models` role to anyone who should reach the console.
3. `agentgateway_config` and `agentgateway_logs` on `global-postgres`, owned by
   the `agentgateway` role — both reconciled by CNPG `Database` CRs.
4. The console KSA bound to `agentgateway-llm@` for Workload Identity, and
   NetworkPolicy egress to `169.254.169.254:80` so the token fetch succeeds.

## Cutover

Browser traffic on `agentgateway.tesserix.app` is served directly by this
gateway's console listener on port 8082. Its built-in OIDC policy owns
`/oauth/callback`; do not put the browser fallback behind the legacy xDS admin
OAuth proxy. The provider prefixes on that host still route to the xDS
`ai-gateway`; moving them, retiring that gateway and unwiring
`agentgateway-route-sync` are separate changes.

The deployment suppresses the AgentGateway startup scope that prints the fully
rendered configuration. Secret-backed PostgreSQL URLs must never appear in pod
logs; all other AgentGateway info-level telemetry remains enabled.
