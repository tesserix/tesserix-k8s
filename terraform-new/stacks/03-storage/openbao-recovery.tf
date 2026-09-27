locals {
  openbao_recovery_ring = "projects/${var.project_id}/locations/${var.region}/keyRings/${var.kms_keyring_name}"
}

resource "google_kms_crypto_key" "openbao_backup" {
  name            = "openbao-backup-key"
  key_ring        = local.openbao_recovery_ring
  rotation_period = "7776000s"
  lifecycle {
    prevent_destroy = true
  }
}

data "google_storage_project_service_account" "openbao_backup" {
  project = var.project_id
}

resource "google_kms_crypto_key_iam_member" "openbao_backup_storage" {
  crypto_key_id = google_kms_crypto_key.openbao_backup.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.openbao_backup.email_address}"
}

resource "google_storage_bucket" "openbao_recovery" {
  name                        = "${var.project_id}-openbao-recovery-${var.environment}"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { app = "openbao", purpose = "verified-recovery", environment = var.environment }
  encryption {
    default_kms_key_name = google_kms_crypto_key.openbao_backup.id
  }
  versioning {
    enabled = false
  }
  soft_delete_policy {
    retention_duration_seconds = 0
  }
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_kms_crypto_key_iam_member.openbao_backup_storage]
}

resource "google_service_account" "openbao_recovery" {
  for_each     = toset(["backup", "test"])
  project      = var.project_id
  account_id   = "openbao-recovery-${each.key}"
  display_name = "OpenBao isolated recovery ${each.key}"
}

resource "google_service_account_iam_member" "openbao_recovery_workload" {
  for_each           = google_service_account.openbao_recovery
  service_account_id = each.value.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[openbao-recovery/openbao-${each.key == "backup" ? "backup" : "restore-test"}]"
}

resource "google_storage_bucket_iam_member" "openbao_recovery_objects" {
  for_each = google_service_account.openbao_recovery
  bucket   = google_storage_bucket.openbao_recovery.name
  role     = each.key == "backup" ? "roles/storage.objectAdmin" : "roles/storage.objectViewer"
  member   = "serviceAccount:${each.value.email}"
}

resource "google_kms_crypto_key_iam_member" "openbao_recovery_unseal" {
  for_each      = google_service_account.openbao_recovery
  crypto_key_id = "${local.openbao_recovery_ring}/cryptoKeys/openbao-unseal-key"
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${each.value.email}"
}

resource "google_storage_bucket_iam_member" "openbao_recovery_console_catalog" {
  bucket = google_storage_bucket.openbao_recovery.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:secret-service@${var.project_id}.iam.gserviceaccount.com"
  condition {
    title       = "recovery-catalog-only"
    description = "Console backend reads metadata, never snapshot objects"
    expression  = "resource.name == 'projects/_/buckets/${google_storage_bucket.openbao_recovery.name}/objects/catalog.json'"
  }
}
