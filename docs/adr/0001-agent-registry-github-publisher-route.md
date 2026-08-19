# ADR 0001: Agent Registry GitHub publisher route

- Status: Accepted
- Date: 2026-08-19

## Context

The public Registry host, `aregistry.tesserix.app`, is served through a
Cloudflare Tunnel. Cloudflare Free-plan Bot Fight Mode challenges GitHub-hosted
Actions runners before `POST /v0/apply` reaches Istio or the Registry. Standard
Bot Fight Mode cannot be skipped for one path with a WAF custom rule.

Publishing is a low-volume control-plane operation: a manual run writes two
manifests, each a few KiB, at less than one request per second. The target is
99.9% availability during a requested publish and completion within 30 seconds
per manifest. Registry reads are not coupled to this route and remain available
if publishing is unavailable.

Assets worth protecting are Registry integrity, tenant isolation, the Kora
deploy key, and the ability to change Agent Cards. Threat actors include the
unauthenticated internet, a workflow from another repository or branch, and a
caller holding only one of the two credentials. The trust boundaries are the
external Istio gateway and the Registry application.

## Decision

Serve `publish.aregistry.tesserix.app` as a DNS-only A record on the reserved
external Istio load balancer. The hostname accepts only exact `POST /v0/apply`
requests and is not routed through Cloudflare, so Bot Fight Mode remains enabled
for the public Registry host.

Require two independent credentials:

1. Istio validates a short-lived GitHub OIDC token from
   `https://token.actions.githubusercontent.com`, audience
   `agentregistry-publisher.tesserix.app`, repository `tesserix/ai-agents`, ref
   `refs/heads/main`, event `workflow_dispatch`, and the exact `publish.yml`
   workflow reference.
2. Registry validates the existing `X-Agentic-Registry-Deploy-Key` and grants
   only `registry:read registry:write` within tenant `kora`.

The workflow obtains OIDC at runtime and never stores it. The deploy key remains
in the protected GitHub secret. Reapplying an identical manifest is idempotent.
The workflow retries transient transport failures with a hard attempt and time
limit; it does not retry application-level validation failures.

## Consequences

- Cloudflare protection is unchanged for public reads and browser access.
- A compromised deploy key alone cannot reach the publisher route, and a valid
  GitHub token alone cannot write Registry data.
- DNS, certificate, gateway, route, and authorization remain GitOps-managed.
- The external load balancer already exists. A dedicated, label-filtered
  ExternalDNS controller uses a 32 MiB request and 64 MiB limit so DNS ownership
  and rollback are isolated to the publisher A record.
- If OIDC or the external gateway is unavailable, publication fails closed and
  existing Registry content is unchanged. A later manual dispatch safely
  retries the operation.

## Alternatives considered

- Disable Bot Fight Mode zone-wide: rejected because it weakens every public
  `tesserix.app` hostname.
- Upgrade to Super Bot Fight Mode and skip one path: viable later, but adds plan
  cost to solve a two-request control-plane workflow.
- Use a static second edge secret: rejected in favor of short-lived,
  repository-bound GitHub OIDC.
- Publish through an imperative Kubernetes Job: rejected because it bypasses
  GitOps and expands GitHub's cluster permissions.

## Rollback

Revert the GitOps and workflow commits. Argo CD removes the publisher resources,
ExternalDNS removes the A record, and the workflow returns to a non-publishing
state until another route is selected. Registry data and public read routing are
unchanged.
