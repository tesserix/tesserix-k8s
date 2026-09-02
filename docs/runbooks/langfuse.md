# Langfuse for DevAI evaluations

Langfuse is DevAI's trace-level observability sink. It does not replace the
durable evaluation database or become another global product dashboard.

## UI and source of truth

- **DevAI → Analytics → Usage & Quality** is the primary UI for pass rates,
  costs, tokens, p95 latency, scorer dimensions, failures, and attribution for
  Agents, prompts, skills, tools, and MCP servers.
- **Trace details** opens Langfuse for operator-level investigation.
- PostgreSQL `eval_runs` and `eval_case_results` remain authoritative. Export is
  fail-open and cannot change a quality gate or publication result.
- DevAI exports numeric scores plus Agent/suite/count/cost/token/latency/failed
  case metadata. It does not export prompts, model responses, secrets, or PII.

```text
DevAI eval → PostgreSQL → DevAI Analytics and publish gates
          └→ fail-open Langfuse → infra-postgres + ClickHouse + Valkey + GCS
```

The official chart is pinned to `2.1.0` (Langfuse v4). Bundled data services
are disabled. The Application is manual-sync while observability is parked.

## SLO and capacity

- UI/API availability: 99.9% monthly; interactive UI p99 under 2 seconds.
- Ingestion is asynchronous/fail-open and cannot reduce DevAI availability.
- Initial envelope: 100 concurrent DevAI runs, 50-case suites, 10 eval runs/min.
- PostgreSQL target RPO/RTO: 15/60 minutes via continuous GCS backup/WAL.
- ClickHouse target RPO/RTO: 24 minutes/2 hours; PostgreSQL scorecards continue.

## Prerequisites

Do not sync Langfuse until an explicitly approved rollout has:

1. Recreated the node pool documented in `docs/observability-park.md`.
2. Created bucket `tesserix-langfuse-prod-in`, GSA
   `langfuse-prod@tesseracthub-480811.iam.gserviceaccount.com`, bucket IAM, and
   Workload Identity for `observability/langfuse`.
3. Created GCP secrets `prod-langfuse-postgresql-password`,
   `prod-langfuse-salt`, `prod-langfuse-encryption-key`,
   `prod-langfuse-nextauth-secret`, `prod-langfuse-google-client-id`,
   `prod-langfuse-google-client-secret`, `prod-langfuse-init-user-password`,
   `prod-devai-langfuse-public-key`, and `prod-devai-langfuse-secret-key`.
4. Registered OAuth callback
   `https://langfuse.tesserix.app/api/auth/callback/google` and DNS/TLS.

Use cryptographically secure values and never place them in Git or logs. The
pinned project keys bootstrap the `tesserix/devai` project idempotently and are
the same keys injected into DevAI.

## Revival order

Each live mutation requires explicit approval. Use Argo CD, not `kubectl apply`.

1. Capture Argo, PVC, CNPG, and parked-replica state in the change record.
2. Recreate capacity; provision bucket/IAM/secrets; wait for ExternalSecrets.
3. Revive Keeper, ClickHouse, and global Valkey. ClickHouse 26.4 satisfies the
   Langfuse v4 requirement of at least 25.12.
4. Sync infra-postgres and verify the managed role/database are Ready.
5. Manually sync Langfuse; verify 2 web + 2 worker pods, PDBs, spread, migrations,
   GCS, and Google OAuth.
6. Roll DevAI, run a known suite, and match run ID/pass rate/scorer dimensions
   between DevAI Analytics and Langfuse.

## Validation and rollback

Run the focused pytest, Helm lint/template, official Langfuse chart render,
`scripts/validate-argocd-apps.py`, and Kustomize builds for infrastructure and
external secrets. Never persist rendered Secrets.

Rollback sets DevAI telemetry to `noop`, then stops Langfuse through GitOps.
Retain PostgreSQL, GCS, ClickHouse and PVC data. Do not downgrade a data-bearing
ClickHouse cluster; restore parked desired state and investigate first.

The parked estate already carries roughly 390 GiB observability storage
(~USD 68/month), 32 GiB monitoring storage (~USD 5/month), and needs at least
three Spot nodes when revived. Measure two weeks before setting GCS retention.
