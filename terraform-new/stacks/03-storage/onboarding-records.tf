# Customer intent and receipts contain identifiers only; credentials remain in OpenBao.
resource "google_storage_bucket" "onboarding_records" {
  name                        = "${var.project_id}-onboarding-records-${var.environment}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  default_event_based_hold    = true
  labels                      = { app = "zitadel-operator", purpose = "onboarding-records", environment = var.environment }
  versioning { enabled = true }
  retention_policy { retention_period = 189216000 }
  lifecycle { prevent_destroy = true }
}

resource "google_project_iam_custom_role" "onboarding_record_writer" {
  project     = var.project_id
  role_id     = "onboardingRecordWriter"
  title       = "Create and verify held onboarding revisions"
  permissions = ["storage.objects.create", "storage.objects.get"]
}

resource "google_storage_bucket_iam_member" "onboarding_record_writer" {
  bucket = google_storage_bucket.onboarding_records.name
  role   = google_project_iam_custom_role.onboarding_record_writer.name
  member = "principal://iam.googleapis.com/projects/849928263410/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/identity-operator/sa/zitadel-operator"
  condition {
    title      = "helivanta-production-records-only"
    expression = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.onboarding_records.name}/objects/helivanta/prod/tenants/')"
  }
}
