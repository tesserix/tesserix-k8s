data "google_project" "project" {
  project_id = var.project_id
}

data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

data "google_kms_key_ring" "existing" {
  name     = var.kms_keyring_name
  location = var.kms_location
  project  = var.project_id
}

locals {
  helivanta_file_keyring = data.google_kms_key_ring.existing.id
  helivanta_file_key_id  = "${local.helivanta_file_keyring}/cryptoKeys/helivanta-private-files"
  helivanta_file_read    = "projects/${var.project_id}/roles/helivantaPrivateFileRead"
  helivanta_file_buckets = {
    prod_quarantine         = { environment = "prod", purpose = "quarantine" }
    prod_released           = { environment = "prod", purpose = "released" }
    verification_quarantine = { environment = "verification", purpose = "quarantine" }
    verification_released   = { environment = "verification", purpose = "released" }
  }
  helivanta_file_grants = {
    prod_api_upload     = { bucket = "prod_quarantine", identity = "helivanta-api", role = "roles/storage.objectCreator" }
    prod_api_retry      = { bucket = "prod_quarantine", identity = "helivanta-api", role = local.helivanta_file_read }
    prod_api_download   = { bucket = "prod_released", identity = "helivanta-api", role = local.helivanta_file_read }
    prod_worker_read    = { bucket = "prod_quarantine", identity = "helivanta-document-worker", role = local.helivanta_file_read }
    prod_worker_promote = { bucket = "prod_released", identity = "helivanta-document-worker", role = "roles/storage.objectCreator" }
    prod_worker_verify  = { bucket = "prod_released", identity = "helivanta-document-worker", role = local.helivanta_file_read }
    verify_upload       = { bucket = "verification_quarantine", identity = "helivanta-file-verifier", role = "roles/storage.objectCreator" }
    verify_read         = { bucket = "verification_quarantine", identity = "helivanta-file-verifier", role = local.helivanta_file_read }
    verify_promote      = { bucket = "verification_released", identity = "helivanta-file-verifier", role = "roles/storage.objectCreator" }
    verify_release      = { bucket = "verification_released", identity = "helivanta-file-verifier", role = local.helivanta_file_read }
  }
}

resource "google_kms_crypto_key" "helivanta_files" {
  name            = "helivanta-private-files"
  key_ring        = local.helivanta_file_keyring
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"
  labels          = merge(var.common_labels, { product = "helivanta", purpose = "private-files" })
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "helivanta_files" {
  crypto_key_id = local.helivanta_file_key_id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
  depends_on    = [google_kms_crypto_key.helivanta_files]
}

resource "google_project_iam_custom_role" "helivanta_file_read" {
  project     = var.project_id
  role_id     = "helivantaPrivateFileRead"
  title       = "Helivanta private file read"
  description = "Read an authorized exact object without listing bucket contents."
  permissions = ["storage.objects.get"]
}

resource "google_storage_bucket" "helivanta_files" {
  for_each                    = local.helivanta_file_buckets
  name                        = "${var.project_id}-helivanta-${each.value.environment}-${each.value.purpose}"
  project                     = var.project_id
  location                    = upper(var.kms_location)
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  encryption {
    default_kms_key_name = local.helivanta_file_key_id
  }
  versioning {
    enabled = true
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  labels = merge(var.common_labels, {
    product    = "helivanta", environment = each.value.environment, purpose = each.value.purpose,
    data_class = each.value.environment == "prod" ? "restricted" : "synthetic"
  })
  lifecycle {
    prevent_destroy = true
  }
  depends_on = [google_kms_crypto_key_iam_member.helivanta_files]
}

resource "google_storage_bucket_iam_member" "helivanta_files" {
  for_each   = local.helivanta_file_grants
  bucket     = google_storage_bucket.helivanta_files[each.value.bucket].name
  role       = each.value.role
  member     = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/helivanta/sa/${each.value.identity}"
  depends_on = [google_project_iam_custom_role.helivanta_file_read]
}

output "helivanta_file_buckets" {
  description = "Dedicated private application and isolated synthetic verification buckets."
  value       = { for name, bucket in google_storage_bucket.helivanta_files : name => bucket.name }
}
