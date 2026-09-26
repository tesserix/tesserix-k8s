# GitHub integration

Terraform plans and applies are owned by Atlantis. GitHub Actions does not
receive a GCP identity or static service-account key.

The active workflows are:

- `.github/workflows/terraform.yml`: formatting and offline Terraform
  validation only.
- Atlantis: enforces mergeability and branch freshness (review is optional for apply); applies the
  saved plan only when someone comments `atlantis apply` (all planned projects)
  or `atlantis apply -p <project>`; merges after all affected projects apply
  successfully. No workflow posts apply comments automatically.

GitHub App permissions, webhooks, Secret Manager inputs, bootstrap ordering,
and failure handling are documented in
[`ATLANTIS_RUNBOOK.md`](ATLANTIS_RUNBOOK.md).

Do not restore the former Workload Identity Federation/static-key Actions
workflow. It was a second apply authority and allowed a manually dispatched
apply or destroy outside the reviewed Atlantis plan.
