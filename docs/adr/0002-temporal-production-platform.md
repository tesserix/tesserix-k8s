# ADR-0002: Shared Temporal platform for AI workflows

## Context

DevAI has a Temporal adapter and worker but production keeps them disabled. HomeChef/FE3DR, DwellM8, and Postiz run separate Temporal 1.28 clusters with histories that cannot be moved by changing an endpoint. Mark8ly has no Temporal workflow implementation yet. The platform must add durable AI execution without mixing end-user authorization, exposing workflow histories, or disrupting existing executions.

The initial AI workload is below 20 workflow starts per second with activity payloads below 1 MiB. The target is 99.9% monthly availability, p99 start latency below 500 ms inside GKE, RTO below 30 minutes, and RPO below 5 minutes. DwellM8 money movement requires a separate 99.95% review and remains disabled.

## Decision

Deploy the official Temporal Helm chart 1.6.0 at its immutable release commit, running Temporal Server 1.31.2 in `temporal-system`.

- Run frontend, history, matching, and internal worker with three replicas, disruption budgets, and zone/host spreading.
- Use `infra-postgres` directly, with declarative CNPG `Database` resources for `temporal_platform` and `temporal_platform_visibility`. Use SQL advanced visibility; do not add Elasticsearch.
- Encrypt PostgreSQL transport, disable the public UI and admin-tools Deployment, and keep the frontend private.
- Permit frontend ingress only from explicitly onboarded product namespaces. Product users never connect to Temporal directly; product APIs enforce tenant ownership.
- Create one Temporal Namespace per product, not per end user. Workflow IDs and product persistence must include the verified tenant identifier. A Temporal Namespace is an operational boundary, not an end-user authorization boundary.
- Keep legacy clusters and histories in place. Upgrade them sequentially through 1.28.4, 1.29.7, 1.30.6, and 1.31.2 before any later cutover.
- DevAI fails closed when its configured Temporal backend is unavailable. Existing in-process fallback remains a local-development mode only.

When PostgreSQL is unavailable, new starts fail and existing histories remain durable. When a product worker is unavailable, workflow tasks remain queued and alert; activities must be idempotent because delivery is at least once.

## Consequences

The platform adds about 6 GiB of requested memory and may cause one additional `e2-standard-8` Spot node, approximately USD 58/month at the repository's current estimate. A three-node on-demand pool would improve the failure domain at roughly USD 582/month and is required before money movement uses this platform.

Rollback removes the new application endpoint while retaining both databases. Legacy products keep their existing endpoints throughout this rollout. Schema rollback is not supported; every future minor upgrade requires a recoverable backup, sequential schema update, canary, and observation window.

Self-hosted Temporal has no built-in tenant RBAC. Network isolation and application-mediated access reduce exposure, but a custom authorizer or separate cluster is required if products become mutually untrusted. Mark8ly is only namespace-ready until a business workflow and worker are implemented.

## Alternatives

- One cluster per product provides a stronger security boundary but multiplies server fleets, databases, backups, and upgrades.
- Temporal Cloud removes server operations but does not satisfy the requested GKE deployment.
- Elasticsearch visibility adds cost and failure modes without a current search-attribute requirement.
