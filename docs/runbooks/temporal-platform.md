# Temporal platform runbook

## Scope

This runbook covers the shared Temporal 1.31.2 service in `temporal-system`. HomeChef/FE3DR, DwellM8, and Postiz retain separate legacy clusters until their explicit migration.

## Triage

1. Check the `temporal-platform` and `temporal-platform-resources` Argo applications are Synced and Healthy.
2. Check frontend, history, matching, and worker Deployments have three available replicas spread across zones.
3. Check `infra-postgres` is healthy and both Temporal `Database` resources report `Applied`.
4. Check schema and namespace Jobs before restarting any server component.
5. Inspect service and persistence error metrics by Temporal Namespace. Do not inspect workflow payloads unless incident access has been approved.

When the frontend is unavailable, stop new starts at the product API and leave existing workflows queued. When a product worker is unavailable, restore its pollers before retrying or terminating executions.

## Upgrade

Create and verify a recoverable `infra-postgres` backup first. Upgrade one Temporal minor version at a time: latest patch of the current minor, schema hook, server rollout, then at least ten minutes for history shards to load before the next minor. Canary DwellM8 before HomeChef and Postiz. Do not skip minor versions.

## Rollback and recovery

Application rollback is a Git revert to the last compatible server image. A schema downgrade is unsupported. If persistence is damaged, stop server reconciliation and follow `docs/cnpg-backup-restore.md`; restore into a new cluster and validate namespace/workflow counts before endpoint cutover.

Workflow termination, namespace deletion, database deletion, and restore cutover require named production approval.
