# GitHub integration

Terraform plans and applies are owned by Atlantis. GitHub Actions does not
receive a GCP identity or static service-account key.

The active workflows are:

- `.github/workflows/terraform.yml`: formatting and offline Terraform
  validation only.
- `.github/workflows/atlantis-auto-apply.yml`: after a current-head approval,
  a successful Atlantis plan, and successful checks, posts one idempotent
  `atlantis apply` comment.
- Atlantis: enforces approval, mergeability, and branch freshness; applies the
  saved plan; merges after all affected projects apply successfully.

GitHub App permissions, webhooks, Secret Manager inputs, bootstrap ordering,
and failure handling are documented in
[`ATLANTIS_RUNBOOK.md`](ATLANTIS_RUNBOOK.md).

Do not restore the former Workload Identity Federation/static-key Actions
workflow. It was a second apply authority and allowed a manually dispatched
apply or destroy outside the reviewed Atlantis plan.
