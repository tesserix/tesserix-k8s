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

removed {
  from = google_storage_bucket_iam_member.onboarding_record_writer
  lifecycle {
    destroy = false
  }
}

resource "google_storage_bucket_iam_policy" "onboarding_records" {
  bucket = google_storage_bucket.onboarding_records.name
  policy_data = jsonencode({
    bindings = [{
      role    = google_project_iam_custom_role.onboarding_record_writer.id
      members = ["serviceAccount:zitadel-operator-gip-migrator@${var.project_id}.iam.gserviceaccount.com"]
      condition = {
        title      = "helivanta-production-records-only"
        expression = "resource.name.startsWith('projects/_/buckets/${google_storage_bucket.onboarding_records.name}/objects/helivanta/prod/tenants/')"
      }
    }]
  })
}
