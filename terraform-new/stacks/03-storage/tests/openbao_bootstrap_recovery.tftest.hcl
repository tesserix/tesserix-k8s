mock_provider "google" {}
mock_provider "google-beta" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}

run "bootstrap_material_is_separate_and_not_pruned" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    create_kms_keyring = false
    enable_cmek        = false
    secrets            = []
  }
  assert {
    condition     = google_storage_bucket.openbao_bootstrap.name != google_storage_bucket.openbao_recovery.name && google_storage_bucket.openbao_bootstrap.versioning[0].enabled && length(google_storage_bucket.openbao_bootstrap.lifecycle_rule) == 0
    error_message = "Bootstrap material must survive snapshot pruning in its own versioned bucket."
  }
  assert {
    condition     = google_storage_bucket.openbao_bootstrap.uniform_bucket_level_access && google_storage_bucket.openbao_bootstrap.public_access_prevention == "enforced" && !google_storage_bucket.openbao_bootstrap.force_destroy
    error_message = "Recovery storage must be private and refuse destructive bucket deletion."
  }
  assert {
    condition     = toset([for binding in google_storage_bucket_iam_member.openbao_bootstrap : binding.role]) == toset(["roles/storage.objectCreator", "roles/storage.objectViewer"])
    error_message = "Bootstrap may read/create records, never overwrite or delete them."
  }
  assert {
    condition     = alltrue([for binding in google_storage_bucket_iam_member.openbao_bootstrap : binding.member == "serviceAccount:openbao-bootstrap@synthetic-project.iam.gserviceaccount.com"])
    error_message = "Routine backup/test identities must not inherit bootstrap recovery access."
  }
  assert {
    condition     = google_kms_crypto_key.openbao_bootstrap.name == "openbao-bootstrap-key"
    error_message = "Bootstrap material must use its own KMS key."
  }
}
