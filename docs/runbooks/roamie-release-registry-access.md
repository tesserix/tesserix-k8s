# Roamie fallback registry readers

Roamie's verified Cloud Build fallback images are stored in the existing
`asia-south1/global` Artifact Registry repository in `tesseracthub-480811`.
Kargo discovers the verified deploy tag there, and GKE nodes pull its immutable
digest for the migration Job and API Deployment. Both existing identities
need `roles/artifactregistry.reader` on this repository:

- `kargo-controller@tesseracthub-480811.iam.gserviceaccount.com`
- `849928263410-compute@developer.gserviceaccount.com`

The binding exposes images throughout the shared `global` repository to these
existing production identities. It grants no write access or project-wide
role. The pre-existing `atelet` binding must be preserved.

Run `bash scripts/setup-roamie-release-registry-access.sh` to inspect the
current policy and proposed readers. After approval for the production rollout,
capture the current policy privately outside Git, then run the same command
with `--apply`. The script checks the active GCP account and project, adds only
the two repository reader bindings, and preserves all other IAM members.

Validate with `bash scripts/tests/test-roamie-release-registry-access.sh`
and ShellCheck. After applying, verify Warehouse discovery, the migration
Job and both ready API replicas. The publishing source and return to GHCR
are documented in `tesserix/kargo-manifests`,
`docs/roamie-cloud-build-fallback.md`.
