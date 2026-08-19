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
| `files/config.yaml` (git) | binds and listeners, `ui:` block, access-log fields, `llm.policies.apiKey`, `mcp.policies`, the rate-limit and extProc pointers, the devai and kora routes |
| Postgres (`storage.mode: hybrid`) | models, providers, guardrails, virtual API keys, and the request-log store behind Costs / Analytics / Logs |

`llm.policies.apiKey` and `mcp.policies` must exist as objects in the file or
the DB-backed resources are rejected (`config_store.rs`).

The file is passed through Helm with `.Files.Get`, which does **not** re-template
it, so its `{{ .pgPassword }}` / `{{ .oidcClientId }}` / `{{ .oidcClientSecret }}`
placeholders survive to External Secrets, which renders the finished config into
a Secret. Editing the config therefore never touches Helm templating.

## Listeners

| Port | Name | Auth |
|---|---|---|
| 8080 | `mesh` | Istio mTLS principals only (AuthorizationPolicy) |
| 8081 | `public` | Zitadel JWT `strict` + CEL role check + remote rate limit |
| 8082 | `console` | native OIDC against Zitadel + CEL role check |
| 15021 | readiness | probes |

The console's OIDC is agentgateway's own (`ui.policies.oidc`), not oauth2-proxy,
so the 8 KiB request-head cap on the admin listener — the source of the earlier
HTTP 431 — is out of the path entirely.

## Product integration

**devai** keeps its current URLs. `/anthropic`, `/openai`, `/vertex`, `/gemini`,
`/groq`, `/openrouter`, `/nemoclaw` are explicit routes with `urlRewrite` to `/`
and `ai:` backends, so devai needs no change when it is cut over.

**kora** gets `/kora`: prompt guardrails (credit card and SSN rejected, email and
phone masked in both directions), the `token-optimizer:18080` extProc in
`failOpen` buffered mode, 120 req/min and 1M tokens/hour local limits, and a
120s timeout.

## Prerequisites

1. GCP Secret Manager key `prod-agentgateway-postgresql-password`.
2. Zitadel: add `https://agentgateway.tesserix.app/oauth/callback` to the
   existing agentgateway admin UI application's redirect URIs.
3. `agentgateway_config` and `agentgateway_logs` on `global-postgres` — declared
   in that chart's `postInitSQL` and created by the db-schema-bootstrap CronJob.

## Cutover

This chart is additive: nothing routes to it until devai and kora are repointed
and `agentgateway.tesserix.app` is moved off the oauth2-proxy upstreams. Those
are separate changes, along with retiring the xDS path for `ai-gateway` and
`agentgateway-route-sync`.
