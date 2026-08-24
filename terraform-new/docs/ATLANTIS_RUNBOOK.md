# Atlantis bootstrap and operations runbook

## Safety boundary

Atlantis controls production Terraform for GCP project
`tesseracthub-480811` and the production GKE cluster. Creating or rotating
secrets, importing state, applying Terraform, syncing Argo CD, or changing a
GitHub ruleset is a production mutation and requires explicit approval for that
specific action. Do not put secret values, kubeconfigs, access tokens, or
service-account keys in this repository or command output.

Before any mutation, record and verify:

```bash
gcloud auth list --filter=status:ACTIVE --format='value(account)'
gcloud config get-value project
KUBECONFIG=~/.kube/gke-prod kubectl config current-context
KUBECONFIG=~/.kube/gke-prod kubectl config view --minify -o jsonpath='{..namespace}'
```

The intended targets are the active authorized operator, project
`tesseracthub-480811`, the production GKE context, and namespace `atlantis`.

## One-time bootstrap order

The state bucket and Atlantis Google service account predate Atlantis as an
apply authority, so an authorized operator must bootstrap them once. Do these
steps from a reviewed branch before allowing the Argo CD Application to sync.

1. Adopt the existing state bucket with
   `scripts/bootstrap-state-bucket.sh`. Run it without arguments first for the
   read-only preflight and capture. With separate explicit approval, set
   `CONFIRM_STATE_BUCKET_IMPORT=tesseract-terraform-states` and rerun with
   `--execute`. The import writes Terraform state but does not change the
   bucket. Review the resulting plan separately before applying the change that
   enables object versioning.
2. From `stacks/06-workload-identity`, initialize against the checked-in
   `workload-identity` backend and review a saved targeted plan for only:
   `google_service_account.atlantis`,
   `google_project_iam_member.atlantis_project_roles`, and
   `google_service_account_iam_member.atlantis_workload_identity`. Apply that
   saved plan only during an explicitly approved production change. This is the
   only keyless identity the Atlantis KSA uses.
   Kubernetes, Helm, and the legacy `local-exec` bootstrap resources obtain a
   fresh short-lived token through `scripts/gke-auth.sh` for each client
   session. In Atlantis it uses the GKE metadata server and the bound GSA;
   locally it uses the active `gcloud` identity. `scripts/kubectl-gke.sh`
   creates an ephemeral CA-verified kubeconfig and never stores the token.
3. Create the GCP Secret Manager entries listed below through the approved
   secret-management process. Do not create placeholder Kubernetes Secrets.
4. Create and install the GitHub App, configure repository protections, and
   confirm the approval relay has `issues: write` through its scoped
   `GITHUB_TOKEN` permission.
5. After an explicitly approved rollout, allow the production infrastructure
   app-of-apps to create the `atlantis` Application. Verify the ExternalSecrets
   are Ready, the PVC is Bound, the pod uses the `atlantis` KSA, and
   `https://atlantis.tesserix.app/healthz` responds before enabling the webhook.

Do not use `terraform init -migrate-state` for the existing stacks. Their
checked-in backend prefixes already name the live GCS objects.

The corresponding operator commands are deliberately split into plan and
apply. The two apply commands are allowed only after their own explicit
production-change approvals:

```bash
# Read-only preflight and capture.
./scripts/bootstrap-state-bucket.sh

# Approved state adoption; imports state and creates a plan, but does not apply.
CONFIRM_STATE_BUCKET_IMPORT=tesseract-terraform-states \
  ./scripts/bootstrap-state-bucket.sh --execute
terraform -chdir=stacks/00-state-bootstrap show 00-state-bootstrap.tfplan

# Approved bucket-hardening change only.
terraform -chdir=stacks/00-state-bootstrap apply 00-state-bootstrap.tfplan

# Prepare the keyless Atlantis identity without touching unrelated resources.
terraform -chdir=stacks/06-workload-identity init -reconfigure -input=false
terraform -chdir=stacks/06-workload-identity plan \
  -input=false \
  -var-file=../../environments/prod/terraform.tfvars \
  -target=google_service_account.atlantis \
  -target=google_project_iam_member.atlantis_project_roles \
  -target=google_service_account_iam_member.atlantis_workload_identity \
  -out=atlantis-bootstrap.tfplan
terraform -chdir=stacks/06-workload-identity show atlantis-bootstrap.tfplan

# Approved identity bootstrap only.
terraform -chdir=stacks/06-workload-identity apply atlantis-bootstrap.tfplan
```

## GitHub App

Create a repository-scoped GitHub App for `tesserix/tesserix-k8s` with webhook
URL `https://atlantis.tesserix.app/events`, content type `application/json`, and
a unique high-entropy webhook secret. Subscribe to pull request, pull request
review, issue comment, and push events.

Use these minimum repository permissions:

- Checks: read
- Commit statuses: read and write
- Contents: read and write
- Issues: read and write
- Metadata: read
- Pull requests: read and write

Store the App ID, installation ID, private key, and webhook secret only in GCP
Secret Manager. Contents write is required for Atlantis to merge a pull
request after every affected project applies. If GitHub reports an
authorization error, verify the installation covers this repository before
expanding any other permission.

## Secret Manager inputs

The chart expects these secret IDs:

| Purpose | GCP Secret Manager ID |
|---|---|
| GitHub App ID | `prod-atlantis-github-app-id` |
| GitHub App installation ID | `prod-atlantis-github-app-installation-id` |
| GitHub App private key | `prod-atlantis-github-app-private-key` |
| Webhook HMAC secret | `prod-atlantis-webhook-secret` |
| Web UI username | `prod-atlantis-basic-auth-username` |
| Web UI password | `prod-atlantis-basic-auth-password` |
| Cloudflare API token | `prod-terraform-cloudflare-api-token` |
| Let's Encrypt email | `prod-terraform-letsencrypt-email` |
| Google OAuth client secret | `prod-terraform-google-oauth-client-secret` |
| ARC GitHub App ID | `prod-terraform-arc-github-app-id` |
| ARC App installation ID | `prod-terraform-arc-github-app-installation-id` |
| ARC App private key | `prod-terraform-arc-github-app-private-key` |

External Secrets maps them to `atlantis-vcs`, `atlantis-basic-auth`, and
`atlantis-terraform-vars`. Atlantis never mounts a Google service-account key.

## Repository protections

Keep code-owner review required on `main`, require at least one approval, and
dismiss stale approvals when new commits are pushed. Require the existing
validation checks appropriate to the changed paths. The relay independently
requires an `APPROVED` review tied to the current head, a successful
`atlantis/plan`, and all other checks to be complete without failure.

Atlantis server-side configuration is authoritative: the repository cannot
override its workflow, fork and draft PRs are ignored, and apply/import require
`approved`, `mergeable`, and `undiverged`. The apply step consumes the saved
plan. `automerge: true` merges only after every affected project applies
successfully.

## Verification and failure handling

For a harmless first test, change formatting or a description in one Terraform
stack and confirm the following order:

1. Atlantis publishes a successful plan status.
2. Nothing applies before a current-head approval exists.
3. After approval and successful checks, exactly one relay comment appears.
4. Atlantis applies the saved plan and only then merges the PR.

If apply fails, Atlantis does not merge. Fix the branch, wait for a fresh plan,
and obtain a new current-head approval. The relay intentionally does not retry
the same head/review combination. Use a manual `atlantis apply` comment only
after investigating the failure. Use `atlantis unlock` only after confirming no
plan or apply is running.

To suspend changes without deleting data, set `atlantis.disableApply: true` in
the wrapper chart through a reviewed GitOps change. Do not delete the
Application or PVC as an emergency stop.
