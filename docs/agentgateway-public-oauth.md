# Public AgentGateway OAuth

The production agent gateways are exposed through two exact Istio hosts. Both
hosts require a Zitadel access token; neither redirects unauthenticated clients
to a browser login.

| Capability | Public URL | Required project role |
|---|---|---|
| MCP tools | `https://mcp.tesserix.app` | `agentgateway.mcp` |
| AI model providers | `https://agentgateway.tesserix.app` | `agentgateway.models` |

The AgentGateway controller and xDS port `9978` remain cluster-private. Public
traffic enters through Istio and reaches only the dedicated data-plane listener
on port `8081`. Existing in-cluster clients continue to use the mTLS listener on
port `8080`.

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
urn:zitadel:iam:org:project:id:386889024519799084:aud
urn:zitadel:iam:org:projects:roles
```

Example using credentials loaded into local environment variables:

```bash
curl --fail-with-body \
  --request POST \
  --user "${AGENTGATEWAY_CLIENT_ID}:${AGENTGATEWAY_CLIENT_SECRET}" \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode 'scope=openid urn:zitadel:iam:org:project:id:386889024519799084:aud urn:zitadel:iam:org:projects:roles' \
  https://auth.tesserix.app/oauth/v2/token
```

The returned token must contain:

- issuer `https://auth.tesserix.app`
- audience `386889024519799084`
- a stable, unique `sub`
- the appropriate role in
  `urn:zitadel:iam:org:project:386889024519799084:roles`

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

The exact-host VirtualServices prevent either hostname from falling through to
the `vehicle-rental` wildcard route. Rolling back the Git commit restores the
previous desired state; it also restores the MCP public LoadBalancer and its
direct IP exposure, so rollback must be treated as a security-sensitive change.
