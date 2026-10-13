mock_provider "google" {}
mock_provider "google-beta" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}

run "helivanta_backup_is_private_and_restore_is_read_only" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    region             = "asia-south1"
    create_kms_keyring = false
    enable_cmek        = false
    secrets            = []
  }
  assert {
    condition     = google_storage_bucket.helivanta_backup.uniform_bucket_level_access && google_storage_bucket.helivanta_backup.public_access_prevention == "enforced" && !google_storage_bucket.helivanta_backup.force_destroy && google_storage_bucket.helivanta_backup.location == "ASIA-SOUTH1"
    error_message = "Helivanta backups require private, deletion-protected regional storage."
  }
  assert {
    condition     = google_storage_bucket_iam_member.helivanta_backup_metadata["backup"].role == "roles/storage.legacyBucketReader" && google_storage_bucket_iam_member.helivanta_backup_metadata["restore"].role == "roles/storage.legacyBucketReader"
    error_message = "Barman must be able to read metadata on its dedicated bucket."
  }
  assert {
    condition     = google_storage_bucket_iam_member.helivanta_backup_objects["restore"].role == "roles/storage.objectViewer" && google_storage_bucket_iam_member.helivanta_backup_objects["backup"].role == "roles/storage.objectAdmin"
    error_message = "Restore verification must not modify backup objects."
  }
  assert {
    condition     = google_service_account_iam_member.helivanta_backup_workload["backup"].member == "serviceAccount:synthetic-project.svc.id.goog[helivanta/helivanta-postgres]" && google_service_account_iam_member.helivanta_backup_workload["restore"].member == "serviceAccount:synthetic-project.svc.id.goog[helivanta/helivanta-restore-check]"
    error_message = "Backup and restore must bind only their exact Kubernetes identities."
  }
}
