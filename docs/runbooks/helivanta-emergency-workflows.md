# Helivanta dispatch workflow deployment

This adds the workflow process and scoped credential. It does not activate citizen
booking, approve clinicians or declare a hospital ready to receive a patient.
The API/web, document and evidence workers share their existing GAR delivery;
`/app/emergency-worker` is built into that same reviewed API artifact.

1. Merge the OpenBao exact-path policy, Temporal mesh peer and CNPG NOLOGIN role.
   The managed identity is `helivanta_emergency_worker`, NOINHERIT and non-bypass.
2. Provision a new URL-safe password at
   `kv/helivanta/production/helivanta-emergency-worker-db-password` through the
   `emergencyWorker.seed.enabled=true` GitOps Job after the OpenBao and network
   policy changes reconcile. Use CAS/create-only semantics and preserve an existing
   value. Do not copy an API/owner credential or add a GCP Secret Manager fallback.
3. Enable `emergencyWorker.credentials.enabled` and `emergencyWorker.login` in the
   owning Postgres values. Wait for the ExternalSecret and CNPG role reconciliation.
4. Approve application migrations `0004_emergency`, `0005_emergency` and `0006_emergency` and merge
   the reviewed application release. Confirm the GAR artifact contains the new
   binary and the scoped grants exist before enabling its deployment.
5. Set `emergencyDispatch.enabled: true` in the owning API values. It enables the
   API orchestration client and the two workflow-worker replicas together. Verify
   the old `helivanta-documents-prod` namespace matches the API client; its name is
   retained for compatibility and workflows contain identifiers/operational state,
   not private incident payloads. Do not silently rename a live namespace.
6. Confirm both updated replicas are ready, database TLS is `verify-full`, the
   mounted CA contains only `ca.crt`, and the task queue is `emergency-dispatch-v1`.
   Check workflow starts, duplicate delivery, delayed acknowledgement, expiry and
   reconciliation with isolated synthetic identities and approved test policies.
7. Keep public booking disabled until the provider's named clinical/dispatch lead,
   qualification and receiving policies, retention operation and device/fallback
   evidence are approved. Synthetic fixture approvals cannot satisfy these gates.

The process has no cloud identity, private-document credential or OpenBao token.
It uses four database connections per pod, selected metadata columns and forced
RLS per dispatch. Network rules add DNS, Postgres, Temporal and the mesh control
plane only. Check all namespace-wide policies as well; NetworkPolicies are additive.
Two pods add 200m CPU requests and 256Mi memory requests before their sidecars.
The namespace LimitRange can add CPU limits at admission; check actual quota use
before enabling. New templates set explicit CPU limits and roll with no surge.

Stop new reservations by setting `emergencyDispatch.acceptNew=false` through GitOps; retain the role,
records and committed capacity. Staff cancellation/reconciliation remains available.
Never release capacity merely because a workflow failed or a device is offline.
Do not roll back to API code that cannot reconcile existing assignments. Capture
workflow and database metadata before an approved reset or other recovery action.

## Suspending new entry without stranding a trip

Keep `emergencyDispatch.enabled=true` while any reservation exists. Set
`emergencyDispatch.acceptNew=false` to suspend new reservations. This leaves API
outbox consumers, directed hospital notifications, durable timers and workers
running. The API receives `EMERGENCY_WORKFLOWS_ENABLED=true` independently of
`EMERGENCY_DISPATCH_ENABLED=false`. Existing crews and receivers can continue
transport, physical receipt and handover. Do not stop workers to suspend intake.

Each emergency worker has a 250m CPU limit and a 100m mesh proxy limit; two
replicas add 700m CPU of namespace limits. Verify current ResourceQuota admission
and node capacity before enabling. No surge is used during replacement.


The seed Job uses only a ten-minute projected service-account token and a
five-minute OpenBao token. Its exact-path policy can create the credential and
read version metadata, but cannot read the password, update it, delete it or
access another path. CAS 0 and create-only ACLs preserve concurrent initialization.
A soft-deleted/destroyed current version fails closed for approved recovery.
Existing secret values are never logged. The mesh uses a native sidecar so the
Job finishes cleanly. Keep the seed disabled until its policies are reconciled.

With the observed 10,750m namespace CPU limits, two workers add 700m, leaving
550m for the 500m migration hook. Recheck the live quota before each rollout;
this arithmetic is a snapshot, not a capacity guarantee. Worker deployment has
no surge. The temporary seed Job needs 200m and must complete before workers
are first enabled.
