resource "google_storage_bucket" "helivanta_backup" {
  name                        = "${var.project_id}-helivanta-backups-${var.environment}"
  project                     = var.project_id
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { app = "helivanta", purpose = "database-backup", environment = var.environment }
  versioning {
    enabled = true
  }
  soft_delete_policy {
    retention_duration_seconds = 604800
  }
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_service_account" "helivanta_backup" {
  for_each     = toset(["backup", "restore"])
  project      = var.project_id
  account_id   = "helivanta-db-${each.key}"
  display_name = "Helivanta database ${each.key}"
}

resource "google_service_account_iam_member" "helivanta_backup_workload" {
  for_each           = google_service_account.helivanta_backup
  service_account_id = each.value.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[helivanta/${each.key == "backup" ? "helivanta-postgres" : "helivanta-restore-check"}]"
}

resource "google_storage_bucket_iam_member" "helivanta_backup_objects" {
  for_each = google_service_account.helivanta_backup
  bucket   = google_storage_bucket.helivanta_backup.name
  role     = each.key == "backup" ? "roles/storage.objectAdmin" : "roles/storage.objectViewer"
  member   = "serviceAccount:${each.value.email}"
}

resource "google_storage_bucket_iam_member" "helivanta_backup_metadata" {
  for_each = google_service_account.helivanta_backup
  bucket   = google_storage_bucket.helivanta_backup.name
  role     = "roles/storage.legacyBucketReader"
  member   = "serviceAccount:${each.value.email}"
}
