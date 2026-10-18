# Helivanta dispatch workflow deployment

This adds the workflow process and scoped credential. It does not activate citizen
booking, approve clinicians or declare a hospital ready to receive a patient.
The API/web, document and evidence workers share their existing GAR delivery;
`/app/emergency-worker` is built into that same reviewed API artifact.

1. Merge the OpenBao exact-path policy, Temporal mesh peer and CNPG NOLOGIN role.
   The managed identity is `helivanta_emergency_worker`, NOINHERIT and non-bypass.
2. Provision a new URL-safe password at
   `kv/helivanta/production/helivanta-emergency-worker-db-password` through the
   approved secret writer. Use CAS/create-only semantics and preserve an existing
   value. Do not copy an API/owner credential or add a GCP Secret Manager fallback.
3. Enable `emergencyWorker.credentials.enabled` and `emergencyWorker.login` in the
   owning Postgres values. Wait for the ExternalSecret and CNPG role reconciliation.
4. Approve application migrations `0004_emergency` and `0005_emergency` and merge
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
before enabling. New templates set only memory limits and roll with no surge.

Stop new reservations by disabling the feature through GitOps; retain the role,
records and committed capacity. Staff cancellation/reconciliation remains available.
Never release capacity merely because a workflow failed or a device is offline.
Do not roll back to API code that cannot reconcile existing assignments. Capture
workflow and database metadata before an approved reset or other recovery action.
