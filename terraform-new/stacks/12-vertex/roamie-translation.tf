resource "google_project_iam_member" "roamie_workload_translation" {
  project = var.project_id
  role    = "roles/cloudtranslate.user"
  member  = "serviceAccount:roamie-api-${var.environment}@${var.project_id}.iam.gserviceaccount.com"
}
