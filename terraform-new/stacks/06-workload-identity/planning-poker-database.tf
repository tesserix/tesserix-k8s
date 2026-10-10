resource "google_service_account_iam_member" "planning_poker_database_backup_workload" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/app-secrets-infra-prod@${var.project_id}.iam.gserviceaccount.com"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[planning-poker/planning-poker-postgres]"
}
