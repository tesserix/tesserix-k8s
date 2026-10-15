# Helivanta private-file activation

Tracks [helivanta #1105](https://github.com/tesserix/helivanta/issues/1105).

## Bounded audit provisioning permission

The approved apply created the audit key and Logging key grant, then stopped at
`logging.buckets.create` (403). Those two resources remain in the isolated
Terraform state. No deletion or replacement is required.

The proposed fix grants the existing
`tesseract-prod-atlantis@tesseracthub-480811.iam.gserviceaccount.com` deployment
identity a dedicated six-permission role: `logging.buckets.create/get/update`
and `logging.sinks.create/get/update`. These are project-scoped configuration
permissions, so they can also update other bucket or sink configurations in
the project; the grant is not restricted to the new resource names. It adds no
log-entry reading, object-byte access, log deletion or configuration deletion
permissions. Workload identities and secret readers stay unchanged.

This new IAM capability requires named user approval before apply. Review the
refreshed actual plan: expect the new role and binding plus the three remaining
Logging resources, with no existing-resource changes or destroys. Mock tests
assert the exact permissions and sole recipient; the isolated resource inventory
continues rejecting additions outside its reviewed list.

The user authorized the merged application rollout and additive migrations on
15 October 2026. Apply the combined roster/document API and UI through the
existing image-build → deploy branch → Kargo → Argo path. Keep the structurally
gated upload runtime inactive until its acceptance controls are proven. Existing
migration IDs and production roster history remain unchanged.

## Audit boundary

Read-only inspection found no project Storage/allServices Data Access audit
configuration and no folder/organization parent. The regional logging bucket
inventory is empty. Storage reads/writes therefore lack the expected attributable
Cloud Audit evidence. Metadata, actor identity and opaque object paths are assets;
another tenant, a compromised workload or an overbroad reader must not gain file
bytes or change access rules through this work.

Extend the isolated `17-helivanta-files` state with a Storage Data Access
configuration, dedicated regional log bucket, sink and separate KMS key. Record
`DATA_READ` and `DATA_WRITE`, with no exempted identities. GCP configures this at
project scope, so it enables logging for **all project Storage buckets**, not
only Helivanta. It does not change object access grants. The custom sink selects
exactly the four application/verification file buckets and stores their events
for 400 days in `asia-south1`, using a separate 90-day-rotation CMEK. Existing
project logging access remains unchanged; no new human, workload or sink reader
is granted access. The existing Logging service identity alone gets use of the
new key. Same-project bucket routing needs no additional project bucket-writer
grant. `_Default` routing remains unchanged and can retain its own encrypted copy.

An authorized read verified the existing Logging identity as
`service-849928263410@gcp-sa-logging.iam.gserviceaccount.com`. Its documented
project-number form is derived from the existing project lookup; Terraform does
not need to read or change project-level CMEK settings. The first Atlantis plan
was denied `logging.settings.get` on that unnecessary lookup. Removing the
lookup grants no additional provider permissions. Mock coverage checks a second
project number to prevent a cross-project key grant.

At the planning assumption of 10,000 files/month, eight 2-KiB audit records per
file are about 0.15 GiB/month and 2 GiB at 400 days. This excludes other buckets,
whose project-wide logging volume must be reviewed. Cloud Logging's free allowance
is shared; paid ingestion and extended retention vary with actual volume. No
fixed bill or legal retention requirement is inferred from this estimate.

Mock-provider tests verify service/type/no-exemption settings, exact bucket
filtering, regional retention and key identity. Atlantis must show only the
intended additions. Review the project-wide logging/cost scope before applying.
Then verify actual audit entries for synthetic workload-identity get/create and
denied list/delete/overwrite, including the expected principal and opaque object
scope; an empty query is not proof. Do not log or export file bytes/personnel.

Retain the protected log bucket/key and the historical records. Rollback of
application behavior disables new uploads; it does not destroy file metadata,
objects or audit history. Any audit-disable or retention-shortening decision is
a separate security change.

## Processing and monitored operation

Privately create the worker's credential through the established secret writer;
the API/owner credentials never enter the worker. Project the exact OpenBao path
and reconcile CNPG LOGIN through the owning chart. Verify flags, effective column
grants and forced RLS before starting workers. Prove GCS identity from actual
workloads, fresh ClamAV definitions and the production mesh, then enable upload
acceptance. Test clean, rejected, interrupted/retried, revoked and foreign-scope
requests with synthetic data through the actual UI.

The global monitoring operator/server/alertmanager are deliberately parked.
Existing alert routing explicitly excludes Helivanta. Restoration, recipient
choice and one synthetic delivery test require a named operational review;
do not silently unpark other products' notification routes. The pending user
question proposes the existing `slack-alerts` receiver. Neither rule manifests
nor a healthy application pod prove alert evaluation/delivery.

Observe and test the documented terminal-workflow reset procedure after a
synthetic database interruption. Never bypass scanning, manually set an available
status or edit historical migrations to repair a stalled file. Keep #1105 open
until exact-artifact live acceptance, operational detection and recovery pass.
