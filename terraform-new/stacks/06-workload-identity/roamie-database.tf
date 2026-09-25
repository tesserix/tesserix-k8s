resource "google_service_account" "roamie_database_backup" {
  project      = var.project_id
  account_id   = "roamie-db-backup-${var.environment}"
  display_name = "Roamie CNPG backup and restore"
}

resource "google_service_account_iam_member" "roamie_database_backup_workload" {
  service_account_id = google_service_account.roamie_database_backup.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[roamie/roamie-postgres]"
}

resource "google_storage_bucket_iam_member" "roamie_database_backup_objects" {
  bucket = "${var.project_id}-roamie-db-backups-${var.environment}"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.roamie_database_backup.email}"
}

resource "google_storage_bucket_iam_member" "roamie_database_backup_metadata" {
  bucket = "${var.project_id}-roamie-db-backups-${var.environment}"
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.roamie_database_backup.email}"
}
