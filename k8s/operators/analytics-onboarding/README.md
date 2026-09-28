# Analytics onboarding

Claims in `claims/` reconcile OpenPanel projects through its Manage API and
publish each write client ID at `<product>/app/<product>-openpanel-client-id`
in OpenBao. DevAI and Langfuse are the reviewed production products. New claims
require an explicit product allowlist entry and exact-path policy grant.

The namespace-bound operator identity has create/read/update access only to
those two paths. Root credentials arrive through a separate ESO reader limited
to OpenPanel's root client ID and secret. Writes compare values and use KV-v2 CAS;
retries reuse the existing project and unchanged values create no new version.

The operator has no delete finalizer. Removing a claim leaves the OpenPanel
project and OpenBao record in place; cleanup requires separate approval. It has
no GCP Secret Manager fallback or Workload Identity grant. See
`docs/openpanel-openbao-migration.md` for source retirement and recovery checks.
