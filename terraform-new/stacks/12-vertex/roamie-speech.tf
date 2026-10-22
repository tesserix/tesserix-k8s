resource "google_project_service" "roamie_speech" {
  project            = var.project_id
  service            = "speech.googleapis.com"
  disable_on_destroy = false
}
