resource "google_storage_bucket" "kora_captures" {
  name                        = "kora-prod-captures-in"
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
    retention_duration_seconds = 0
  }
  encryption {
    default_kms_key_name = "projects/${var.project_id}/locations/asia-south1/keyRings/tesseract-prod-in-keyring/cryptoKeys/kora-document-data-key"
  }
  lifecycle_rule {
    action {
      type          = "SetStorageClass"
      storage_class = "ARCHIVE"
    }
    condition {
      age                   = 90
      matches_storage_class = ["STANDARD"]
    }
  }
  labels = merge(var.common_labels, { product = "kora", purpose = "meal-captures", data_class = "restricted" })
}

resource "google_storage_bucket_iam_member" "kora_capture_api" {
  bucket = google_storage_bucket.kora_captures.name
  role   = "roles/storage.objectUser"
  member = "serviceAccount:kora-api-prod@${var.project_id}.iam.gserviceaccount.com"
}
