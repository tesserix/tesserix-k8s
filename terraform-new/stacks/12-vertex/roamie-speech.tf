resource "google_project_service" "roamie_speech" {
  project            = var.project_id
  service            = "speech.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_member" "roamie_workload_speech" {
  project = var.project_id
  role    = "roles/speech.client"
  member  = "serviceAccount:roamie-api-${var.environment}@${var.project_id}.iam.gserviceaccount.com"
}
