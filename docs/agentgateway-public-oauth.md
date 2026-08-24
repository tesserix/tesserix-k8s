# Public AgentGateway OAuth

The production gateways use two exact Istio hosts and separate browser and
machine trust boundaries. The MCP catalog uses an isolated OAuth2 Proxy. The
standalone AgentGateway console uses AgentGateway's native Zitadel
authorization-code flow. Machine API paths require a Zitadel bearer token
validated by their AgentGateway listener.

| Host | Browser experience | Machine API |
|---|---|---|
| `https://mcp.tesserix.app` | Tesserix MCP catalog UI | `/mcp` and `/mcp/*`; role `agentgateway.mcp` |
| `https://agentgateway.tesserix.app` | Standalone writable AgentGateway LLM/MCP console | provider prefixes; role `agentgateway.models` |

The AgentGateway controller and xDS port `9978` remain cluster-private. Public
machine traffic enters through Istio and reaches only the xDS data-plane
listener on port `8081`; existing in-cluster clients use port `8080`. Browser
traffic reaches the standalone console listener on port `8082`. That process
has no `XDS_ADDRESS`, stores its configuration in PostgreSQL, and validates the
`agentgateway.models` role itself. The legacy xDS admin listener on `15000` and
its OAuth2 Proxy remain private during the migration and are not selected by
the public VirtualService.

## Browser access

Browser requests that are not machine API paths are redirected to
`https://auth.tesserix.app`. Access also requires the `agentgateway.models`
role, which is currently granted only to these verified operators:

- `samyak.rout@gmail.com`
- `mahesh.sangawar@gmail.com`

The two hosts use separate confidential clients and cookie keys. Their values
are delivered from GCP Secret Manager through External Secrets:

- `prod-agentgateway-mcp-ui-{client-id,client-secret,cookie-secret}`
- `prod-agentgateway-admin-ui-{client-id,client-secret,cookie-secret}`

Browser cookies are `Secure`, `HttpOnly`, and `SameSite=Lax`. Neither UI stores
a gateway bearer token. The MCP UI reads the existing Agentic Registry catalog;
it is not a second registry and has no separate catalog state. The
`agentgateway-admin-ui` Zitadel client must allow both callbacks during the
transition: `/oauth/callback` for the standalone console and
`/oauth2/callback` for the private legacy proxy.

## Threat model and decision

The protected assets are MCP tool authority, paid model capacity, the Solo
admin surface, catalog integrity, and browser sessions. Expected adversaries
are unauthenticated internet clients, a compromised machine client, an approved
human account used outside its intended UI, and a compromised upstream or pod.
Every internet-to-cluster crossing validates identity and authorization: UI
requests terminate at a host-specific Zitadel proxy and exact email allowlist;
machine requests terminate at a role-specific AgentGateway listener; service
calls use mesh identity. The controller, admin port, and registry remain
ClusterIP-only, and authorization failures fail closed.

A shared browser proxy or the existing DevAI BFF would use fewer pods, but was
rejected because one client, cookie key, or routing mistake would span both
gateways. A browser-side bearer-token playground was also rejected: it would
put machine credentials in browser storage and blur the human/machine boundary.

## Machine-token request

Each external agent must have its own Zitadel machine client. Do not share a
client across agents, environments, or customers.

Token endpoint:

```text
https://auth.tesserix.app/oauth/v2/token
```

Required scopes:

```text
openid
urn:zitadel:iam:org:project:id:387190457387450503:aud
urn:zitadel:iam:org:projects:roles
```

Example using credentials loaded into local environment variables:

```bash
curl --fail-with-body \
  --request POST \
  --user "${AGENTGATEWAY_CLIENT_ID}:${AGENTGATEWAY_CLIENT_SECRET}" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'scope=openid urn:zitadel:iam:org:project:id:387190457387450503:aud urn:zitadel:iam:org:projects:roles' \
  https://auth.tesserix.app/oauth/v2/token
```

The returned token must contain:

- issuer `https://auth.tesserix.app`
- audience `387190457387450503`
- a stable, unique `sub`
- the appropriate role in
  `urn:zitadel:iam:org:project:387190457387450503:roles`

AgentGateway validates the signature, issuer, audience, expiry, and role before
routing. Rate limits are keyed by the verified `sub`, so one client cannot use
another client's quota.

## Requests

Set the returned `access_token` as a bearer token:

```bash
curl --fail-with-body \
  --header "Authorization: Bearer ${AGENTGATEWAY_ACCESS_TOKEN}" \
  https://mcp.tesserix.app/mcp/<server-name>
```

MCP server paths are exported by the agent registry in the form
`/mcp/<server-name>`.

AI provider prefixes select the upstream backend and are removed before the
request is forwarded. For example:

```bash
curl --fail-with-body \
  --header "Authorization: Bearer ${AGENTGATEWAY_ACCESS_TOKEN}" \
  --header 'Content-Type: application/json' \
  --data '{"model":"<model>","messages":[{"role":"user","content":"hello"}]}' \
  https://agentgateway.tesserix.app/openai/v1/chat/completions
```

Available prefixes are `/anthropic`, `/openai`, `/vertex`, `/gemini`, `/groq`,
`/openrouter`, and `/nemoclaw`.

## Existing ADK production client

The initial ADK client is isolated under the client ID
`agentgateway-adk-prod`. Its credential values exist only in GCP Secret Manager:

- `prod-agentgateway-adk-client-id`
- `prod-agentgateway-adk-client-secret`

Never print, log, or commit these values. Workloads should consume them through
External Secrets or an equivalent workload-identity-authorized integration.

## Onboard or revoke an agent

For every new agent:

1. Create a distinct Zitadel machine client in the `AgentGateway` project.
2. Grant only `agentgateway.mcp`, `agentgateway.models`, or both as required.
3. Store the client ID and secret as separately named platform secrets in GCP
   Secret Manager.
4. Grant Secret Manager access only to that agent's workload identity.
5. Request a token and verify the expected issuer, audience, subject, and roles.
6. Confirm the agent receives `401` without a token, is denied with the wrong
   role, and can reach only its intended gateway with the valid token.

To revoke one agent without affecting others, remove its project-role grant and
revoke or rotate that machine client's secret. Disable the machine client for
immediate client-wide revocation. Existing short-lived tokens expire naturally;
do not delete shared gateway or signing resources.

## Limits and failure behavior

- MCP: 120 requests per minute per OAuth subject.
- Models: 60 requests per minute per OAuth subject.
- Model tokens: 200,000 per hour per OAuth subject.
- Rate limiting fails closed if the rate-limit service or its Valkey dependency
  cannot authorize the request.
- If Agentic Registry is unavailable, the MCP UI is unavailable but `/mcp/*`
  routing remains independent.
- If the standalone console is unavailable, model API prefixes remain
  independent.
- If Zitadel is unavailable, new browser logins and new machine tokens fail;
  existing browser cookies and cached JWKS continue only until their configured
  expiry.

The design envelope is two human UI users with less than 5 browser requests per
second per host; machine traffic is bounded by the subject limits above. The UI
target is 99.9% monthly availability and p99 under 300 ms at the edge, excluding
registry, MCP server, and model-provider time. Browser auth components run two
replicas with PodDisruptionBudgets. No new load balancer or catalog is
introduced.

The exact-host VirtualServices prevent either hostname from falling through to
the `vehicle-rental` wildcard route. Rolling back the Git commit restores the
previous desired state; it also restores the MCP public LoadBalancer and its
direct IP exposure, so rollback must be treated as a security-sensitive change.
