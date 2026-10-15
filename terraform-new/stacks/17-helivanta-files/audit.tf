locals {
  helivanta_audit_key_id     = "${local.helivanta_file_keyring}/cryptoKeys/helivanta-file-audit"
  helivanta_logging_identity = "service-${data.google_project.project.number}@gcp-sa-logging.iam.gserviceaccount.com"
}

resource "google_kms_crypto_key" "helivanta_audit" {
  name            = "helivanta-file-audit"
  key_ring        = local.helivanta_file_keyring
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"
  labels          = merge(var.common_labels, { product = "helivanta", purpose = "file-audit" })
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "helivanta_audit" {
  crypto_key_id = local.helivanta_audit_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${local.helivanta_logging_identity}"
  depends_on    = [google_kms_crypto_key.helivanta_audit]
}

resource "google_logging_project_bucket_config" "helivanta_files" {
  project        = var.project_id
  location       = var.kms_location
  bucket_id      = "helivanta-private-files"
  retention_days = 400
  description    = "Restricted Helivanta file access and administration evidence."
  cmek_settings {
    kms_key_name = local.helivanta_audit_key_id
  }
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_kms_crypto_key_iam_member.helivanta_audit]
}

resource "google_logging_project_sink" "helivanta_files" {
  project     = var.project_id
  name        = "helivanta-private-files"
  description = "Retain access/administration evidence for the four dedicated private-file buckets."
  destination = "logging.googleapis.com/projects/${var.project_id}/locations/${google_logging_project_bucket_config.helivanta_files.location}/buckets/${google_logging_project_bucket_config.helivanta_files.bucket_id}"
  filter      = "resource.type=\"gcs_bucket\" AND protoPayload.serviceName=\"storage.googleapis.com\" AND (${join(" OR ", [for bucket in google_storage_bucket.helivanta_files : "resource.labels.bucket_name=\"${bucket.name}\""])})"
  disabled    = false
}

resource "google_project_iam_audit_config" "helivanta_storage" {
  project = var.project_id
  service = "storage.googleapis.com"
  audit_log_config {
    log_type         = "DATA_READ"
    exempted_members = []
  }
  audit_log_config {
    log_type         = "DATA_WRITE"
    exempted_members = []
  }
  depends_on = [google_logging_project_sink.helivanta_files]
}
