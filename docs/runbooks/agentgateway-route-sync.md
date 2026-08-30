# AgentGateway Registry sync runbook

## Scope and SLO

`agentgateway-route-sync-controller` continuously converges the authenticated
Agentic Registry export into Registry-owned `AgentgatewayBackend`,
`AgentgatewayPolicy`, and `HTTPRoute` objects in `agentgateway-system`. Two pods
run across zones; exactly one owns Lease `agentgateway-route-sync`.

- Control-plane availability: 99.9% monthly.
- Registry change to accepted gateway resource: p99 under 30 seconds.
- Full safety reconciliation: every five minutes.
- Data-plane behavior during control-plane failure: retain the last accepted
  Kubernetes/xDS state; never prune from an unavailable or invalid Registry.

The old `agentgateway-route-sync` CronJob remains as rollback. It is active
during shadow rollout and suspended, never deleted, after controller cutover.

## Read-only diagnosis

Use the production kubeconfig and confirm context before every command:

```bash
export KUBECONFIG="$HOME/.kube/gke-prod"
kubectl config current-context
kubectl -n agentgateway-system get deploy,pod,pdb,lease,cronjob \
  -l app.kubernetes.io/name=agentgateway-route-sync -o wide
kubectl -n agentgateway-system logs deploy/agentgateway-route-sync-controller \
  --all-pods --since=15m
```

Port-forward either replica to inspect process state. A follower is ready and
reports `leader: false`; one replica must report `leader: true`:

```bash
kubectl -n agentgateway-system port-forward \
  deploy/agentgateway-route-sync-controller 9090:9090
curl --fail http://127.0.0.1:9090/status
curl --fail http://127.0.0.1:9090/metrics
```

Compare desired ownership and gateway acceptance without displaying Secrets:

```bash
for resource in \
  agentgatewaybackends.agentgateway.dev \
  httproutes.gateway.networking.k8s.io \
  agentgatewaypolicies.agentgateway.dev; do
  kubectl -n agentgateway-system get "$resource" \
    -l app.kubernetes.io/managed-by=agentic-registry -o name
done

kubectl -n agentgateway-system get agentgatewaybackends.agentgateway.dev \
  -l app.kubernetes.io/managed-by=agentic-registry \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
kubectl -n agentgateway-system get httproutes.gateway.networking.k8s.io \
  -l app.kubernetes.io/managed-by=agentic-registry \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .status.parents[*].conditions[*]}{.type}{"="}{.status}{" "}{end}{"\n"}{end}'
```

## Alerts

- `AgentGatewaySyncRegistryStale`: Registry fetch/validation has not succeeded
  for two minutes. Check Registry pods and controller egress. Do not clear or
  delete live gateway resources; cached state is serving intentionally.
- `AgentGatewaySyncReconcileStale`: no successful safety reconciliation for ten
  minutes. Check Kubernetes RBAC, CRD availability, and acceptance conditions.
- `AgentGatewaySyncDrift`: desired names/specification differ for two minutes.
  Inspect the controller status error and the rejecting resource condition.
- `AgentGatewaySyncLeaderUnavailable`: metrics show zero or multiple leaders.
  Inspect the Lease and both pod logs. A healthy failover completes within the
  15-second lease duration.

Snapshot rejection is fail-closed. Common causes are a resource count below the
configured floor, count/digest/ETag mismatch, an oversized export, duplicate
names, an unapproved GVK, wrong namespace, missing Registry ownership, or a
server-managed `status` field. Repair the Registry artifact/export; never lower
the safety floor to make a partial snapshot apply.

## Shadow validation and active cutover

In `shadow` mode, `applied` and `pruned` stay zero. Wait for several 30-second
polls and at least one five-minute safety interval. Confirm two ready replicas,
exactly one leader, desired count equals actual count, drift is zero, and all
backends/routes are accepted. Exercise both the MCP gateway and global ADK
runtime through their normal authenticated paths.

Cutover is GitOps-only: set `controller.mode=active` and `cron.suspend=true` in
the chart in the same reviewed commit. Argo CD must report Synced/Healthy before
the controller is considered the writer. Do not imperatively patch the
Deployment or CronJob; self-heal will revert it and split ownership.

## Rollback

Rollback is one Git revert of the active-cutover commit. The revert returns the
controller to `shadow` (or `disabled`) and sets `cron.suspend=false`. Merge the
revert and let Argo CD reconcile it. Do not delete the controller, Lease, live
routes, backends, policies, or CronJob.

After rollback, confirm a new CronJob execution succeeds, its verified desired
count equals the live Registry-owned count, and MCP/ADK smoke requests still
pass. A controller crash between apply and prune can leave an extra stale
object; this is safe, and the CronJob's existing guarded prune removes it only
after a complete digest/count-verified export.
