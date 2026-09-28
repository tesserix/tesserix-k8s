resource "google_kms_crypto_key" "openbao_bootstrap" {
  name            = "openbao-bootstrap-key"
  key_ring        = local.openbao_recovery_ring
  rotation_period = "7776000s"
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "openbao_bootstrap_storage" {
  crypto_key_id = google_kms_crypto_key.openbao_bootstrap.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.openbao_backup.email_address}"
}

resource "google_kms_crypto_key_iam_member" "openbao_bootstrap" {
  crypto_key_id = google_kms_crypto_key.openbao_bootstrap.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:openbao-bootstrap@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_storage_bucket" "openbao_bootstrap" {
  name                        = "${var.project_id}-openbao-bootstrap-${var.environment}"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { app = "openbao", purpose = "independent-bootstrap", environment = var.environment }
  encryption {
    default_kms_key_name = google_kms_crypto_key.openbao_bootstrap.id
  }
  versioning {
    enabled = true
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_kms_crypto_key_iam_member.openbao_bootstrap_storage]
}

resource "google_storage_bucket_iam_member" "openbao_bootstrap" {
  for_each = toset(["roles/storage.objectCreator", "roles/storage.objectViewer"])
  bucket   = google_storage_bucket.openbao_bootstrap.name
  role     = each.value
  member   = "serviceAccount:openbao-bootstrap@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key_iam_member" "openbao_bootstrap_check" {
  crypto_key_id = google_kms_crypto_key.openbao_bootstrap.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  member        = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}
