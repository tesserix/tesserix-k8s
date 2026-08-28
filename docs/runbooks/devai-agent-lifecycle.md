# DevAI Agent lifecycle alerts

Owner: `devai-platform`

These alerts cover the Registry-to-DevAI import, sandbox, evaluation, and promotion path. Start with read-only inspection of the active account, project, cluster, context, and `devai` namespace. Do not delete a sandbox, retry a real-tool evaluation, change quota, or roll back production without specific approval.

## Triage

1. Inspect the `devai-api-worker` Deployment and Temporal workflow status for the affected operation.
2. Check lifecycle outbox age and pending count. A broker outage leaves rows unpublished and safe to replay; consumers deduplicate on `event_id`.
3. For `stuck`, inspect the terminal workflow step and cleanup activity. A sandbox is not destroyed until its durable status says so.
4. For capacity or quota pressure, compare live/pending sandboxes with the configured tenant and platform limits before proposing a scale or quota change.
5. For import/evaluation failures, separate Registry, OCI, model, tool/MCP, scorer, and storage dependency failures from Agent-quality failures.
6. For authentication failures, verify issuer, audience, JWKS health, and BFF trust configuration without logging tokens or credentials.

## Recovery

- Mock/replay/block evaluations are safe for the workflow retry policy.
- Real-tool evaluation activity failures are non-retryable after execution starts. Confirm external side effects and use a new approved request key for a manual rerun.
- Failed outbox publishing is automatically retried. Do not mark rows published manually.
- Cleanup failures remain `stuck`/backlogged for the TTL reaper. Capture sandbox state before any approved destructive cleanup.

## Escalation

Page the platform owner when a stuck workflow or cleanup backlog persists beyond the alert window, when another tenant may be exposed, or when signed artifact identity cannot be verified. Preserve workflow history, transition IDs, sandbox IDs, and redacted traces for the incident record.
