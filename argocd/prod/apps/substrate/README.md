# Agent Substrate — SUPERSEDED, see argocd/prod/infrastructure/

The staged `substrate.yaml` / `substrate-crds.yaml` that used to live here were
deleted on 2026-07-31. Substrate is deployed now, from:

- `argocd/prod/infrastructure/substrate-crds.yaml`
- `argocd/prod/infrastructure/substrate.yaml`

both pinned to chart `0.0.6` and wired into
`argocd/prod/infrastructure/kustomization.yaml` (sync-wave -5, before kagent
enables substrate at -3).

The copies here were never wired into any kustomization and still carried
`targetRevision: PIN-ME`, so syncing one would have failed — or, worse, been
"fixed" by pinning it and ending up with two Applications fighting over the same
release. That is why they are gone rather than updated.

Original context, still useful: the ordered runbook is
`devai/docs/agentic/SUBSTRATE-SETUP.md` (step 1 = the GKE-Sandbox gVisor node
pool, step 2 = pin chart versions, step 3 = sync the apps, step 4 = enable
substrate on kagent). Tracking: tesserix/devai #70 (GO/NO-GO), #71 (install),
epic #69.

Operational note: `ate-api-server` depends on the `valkey-cluster` StatefulSet in
`ate-system`. If all six valkey pods are rescheduled at once they keep the old
peer addresses in `nodes.conf`, gossip stops (`cluster_state:fail`,
`cluster_stats_messages_received:0`) and ate-api — and therefore
`kagent-controller` — crash-loops. Recover with `valkey-cli cluster meet <ip>
6379` for each peer's current pod IP; slots and data survive.
