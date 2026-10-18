# Helivanta registry cutover

This is a prepared maintenance change. Do not apply it without approval for the
PostgreSQL switchover and single-instance antivirus restart. It follows the shared
Istio hub change in [PR 1464](https://github.com/tesserix/tesserix-k8s/pull/1464).
The staff application release `9285628e61030794310efb7382b61f94db4aa916` is already
running and stays at that commit throughout the cutover.

## Scope and expected effects

- Istiod remains at two replicas on version 1.29.6. Its image hub moves to the
  existing GCP Docker Hub remote repository, including future injected proxies.
- Helivanta PostgreSQL remains at two instances on the existing **16.4 image
  digest** `sha256:99be063781d171d3971089b49c992706bdab9ccbd2b57cdf126c7542773aedfe`.
  Changing its repository can cause a controlled rolling update and primary
  switchover. Connections may briefly retry. This changes no database schema,
  role, password, storage volume or retention policy.
- A GitOps pod annotation refreshes the six meshed application/scanner workloads
  after the injector uses the GCP hub. Application images remain at `9285628`.
  Existing application deployments retain no-surge rolling updates.
- ClamAV retains its existing single replica and Recreate strategy. Scanning can
  pause while it restarts and reloads definitions. Documents remain quarantined
  and processing retries; do not bypass scanning to shorten the maintenance.
- Future schema-bootstrap clients use a pinned `postgres:16-alpine` GCP mirror.
  Future restore checks use the unchanged PostgreSQL digest through GCP.

Terminal historical Job/Pod records keep their original image references for
forensic accuracy. Audit active/pending pods and desired workload templates;
historical records make no further registry pulls and must not be deleted just
to make an image-reference audit pass.

## Before applying

1. Confirm the active GCP account/project and kube context. Intended target is
   `tesseracthub-480811`, `gke_tesseracthub-480811_asia-south1_tesseract-prod-in-gke`,
   namespaces `istio-system` and `helivanta`.
2. Obtain approval for this named maintenance and any registry-only rollback.
3. Capture the current desired Git revision, Argo application image parameters,
   cluster image/primary/replica status, and successful backup/WAL-archive metadata.
   Store no environment dump, token, kubeconfig or credential value.
4. Confirm PostgreSQL 2/2, continuous archiving healthy, and a completed recoverable
   backup. Confirm the current primary uses the exact digest above. The mirror
   must resolve that same digest before proceeding.
5. Confirm all application/scanning workers are ready. ResourceQuota currently
   measures 11,450m/12 CPU and 14,720Mi/16Gi memory limits; recheck admission
   headroom. Do not add surge replicas or change resource quotas implicitly.

## Apply and verify

1. Apply the shared hub change first through its owning GitOps application.
   Verify two healthy Istiod replicas and the injector configuration hub before
   applying the Helivanta refresh. No mTLS or authorization setting changes.
2. Merge the approved `fix/helivanta-registry-cutover` change through GitOps.
   Watch standby readiness, primary switchover, application and scanner readiness.
   Do not delete database pods/PVCs or manually bypass reconciliation.
3. Verify every active/pending Helivanta application, database, init and injected
   proxy image starts with `asia-south1-docker.pkg.dev/`. Verify actual running
   application digests match the release evidence, not just their tags.
4. Verify PostgreSQL remains 2/2 with continuous archiving; application and
   document/evidence/emergency workers return to 2/2 and ClamAV to 1/1.
5. Verify both live Temporal workflow and activity pollers, the scoped worker
   database role, synchronized ExternalSecret status and signed-in pages.
6. Repeat anonymous origin API checks (401), public `/ambulance` access (200),
   pharmacy read smoke checks and quota measurement. Leave new reservations off.

## Stop and recovery

If the mirror cannot serve an existing digest or readiness does not return,
stop the cutover and use the approved GitOps registry rollback. Restore only the
previous image references/hub/refresh annotation. Keep the verified application
commit, schema migrations, OpenBao credential and clinical feature gates intact.
Do not rotate credentials, downgrade PostgreSQL, restore over live data or delete
storage as part of an image-registry change.
