# Foundation Stack - Enable Required GCP APIs
# State: stacks/prod/foundation/default.tfstate
# Dependencies: 00-state-bootstrap

# Enable required GCP APIs
resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = var.disable_on_destroy

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_document_ai_processor" "generic_ocr" {
  project      = var.project_id
  location     = var.document_ai_location
  display_name = var.document_ai_processor_display_name
  type         = "OCR_PROCESSOR"

  depends_on = [google_project_service.apis["documentai.googleapis.com"]]
}

resource "google_project_iam_member" "document_intelligence_worker_document_ai_user" {
  project = var.project_id
  role    = "roles/documentai.apiUser"
  member  = "serviceAccount:kora-doc-worker@${var.project_id}.iam.gserviceaccount.com"

  depends_on = [google_document_ai_processor.generic_ocr]
}

resource "google_project_iam_member" "document_intelligence_sandbox_worker_document_ai_user" {
  project = var.project_id
  role    = "roles/documentai.apiUser"
  member  = "serviceAccount:kora-dev-doc-worker@${var.project_id}.iam.gserviceaccount.com"

  depends_on = [google_document_ai_processor.generic_ocr]
}

resource "google_project_iam_member" "github_actions_compute_network_viewer" {
  project = var.project_id
  role    = "roles/compute.networkViewer"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "github_actions_dns_reader" {
  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "github_actions_role_viewer" {
  project = var.project_id
  role    = "roles/iam.roleViewer"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "github_actions_pubsub_viewer" {
  project = var.project_id
  role    = "roles/pubsub.viewer"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "github_actions_identity_platform_viewer" {
  project = var.project_id
  role    = "roles/identityplatform.viewer"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}
