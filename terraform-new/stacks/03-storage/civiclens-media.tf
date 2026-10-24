data "google_project" "civiclens_media" {
  project_id = var.project_id
}

resource "google_storage_bucket" "civiclens_reports" {
  name                        = "civiclens-prod-report-media-in"
  project                     = var.project_id
  location                    = "asia-south1"
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = false
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle {
    prevent_destroy = true
  }
  labels = merge(var.common_labels, {
    product = "civiclens", purpose = "private-report-photos", data_class = "restricted"
  })
}

resource "google_project_iam_custom_role" "civiclens_media" {
  project     = var.project_id
  role_id     = "civiclensReportMediaWriter"
  title       = "CivicLens private report media"
  description = "Immutable report photo creation and exact-generation retrieval; no listing, overwrite or deletion"
  permissions = ["storage.objects.create", "storage.objects.get"]
}

resource "google_storage_bucket_iam_member" "civiclens_media" {
  bucket = google_storage_bucket.civiclens_reports.name
  role   = google_project_iam_custom_role.civiclens_media.name
  member = "principal://iam.googleapis.com/projects/${data.google_project.civiclens_media.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/civiclens/sa/civiclens-api"
}
