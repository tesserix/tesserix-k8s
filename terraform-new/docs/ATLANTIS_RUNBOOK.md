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

## Stack-scoped projects and commands

Each key under `stacks` in `terraform-new/dependencies.yaml` is an Atlantis
project name. A `*.tf` change inside one stack automatically plans only that
project. `depends_on` and `execution_order_group` order the affected projects;
they do not add unchanged dependency stacks to the plan.

The deliberate shared-path exceptions are:

- `terraform-new/environments/prod/terraform.tfvars` plans every project.
- `terraform-new/modules/**/*.tf` plans `06-workload-identity`, the only stack
  that consumes the shared modules directory.
- YAML and YAML template changes directly under `09-github-arc` plan only
  `09-github-arc`.

Use the project name with `-p` to operate on one saved plan. For example:

```shell
# Replan only this project.
atlantis plan -p 12-vertex

# Apply only this project's saved plan after all apply requirements pass.
atlantis apply -p 12-vertex

# Plan every project Atlantis detects as modified in the PR.
atlantis plan

# Apply every saved plan in dependency and execution-group order.
atlantis apply

# Discard every saved plan and Atlantis lock for the PR.
atlantis unlock
```

Atlantis v0.47.1 does not support `-p` for unlock. Use the lock link in the
Atlantis plan comment for a project-specific unlock. Use `atlantis unlock`
only when every PR plan and lock should be discarded, and only after confirming
no plan or apply is running. If a plan includes an unexpected create, change,
or destroy, do not apply it; unlock and investigate the state or source drift.

### Pull request feedback

Atlantis writes both project-specific and aggregate commit statuses to the
pull request. Affected projects report `atlantis/plan: <project>` and
`atlantis/apply: <project>`; the aggregate checks are `atlantis/plan` and
`atlantis/apply`. The required `atlantis/apply` check blocks merging until all
affected saved plans apply successfully. A failed or missing project status
keeps the aggregate status from succeeding.

A green `0/0 projects` aggregate status means Atlantis processed the pull
request but no production Terraform project matched the changed paths. This is
expected for documentation, repository configuration, and manual-only test
project changes. It does not mean Terraform ran a plan. A production stack
`*.tf` change must instead show its named project status and a nonzero project
count; investigate the `when_modified` rules if it reports zero.

Atlantis also adds detailed pull request comments for plan and apply commands.
The plan comment includes the plan diff, the project name, usable targeted
commands, and a project-specific lock link. These comments and statuses are the
normal operator feedback path, so users do not need Kubernetes access or pod
logs to understand a plan or apply result.

### Intentional failure smoke test

The manual-only `atlantis-failure-smoke` project exercises failed plan feedback
without a backend, provider, resource, or production stack. Its autoplan is
disabled, so normal pull requests never run it. Use it only on a disposable
pull request by commenting:

```shell
atlantis plan -p atlantis-failure-smoke
```

The expected result is a failed `atlantis/plan: atlantis-failure-smoke`
project status, a failed aggregate `atlantis/plan` status, and an Atlantis
comment containing `Intentional Atlantis failure smoke test`. This failure
occurs during input validation, before Terraform can contact any provider or
backend. Do not merge and never apply the disposable pull request; close it
after confirming the statuses and comment. If Atlantis retained a PR lock, use
the project-specific lock link or the PR-wide `atlantis unlock` command as
appropriate.

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
