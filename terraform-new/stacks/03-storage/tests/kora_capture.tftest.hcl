mock_provider "google" {}
mock_provider "google-beta" {}
override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}
run "meal_photos_are_private_archived_and_deletable" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    create_kms_keyring = false
    enable_cmek        = false
    secrets            = []
  }
  assert {
    condition     = google_storage_bucket.kora_captures.public_access_prevention == "enforced" && google_storage_bucket.kora_captures.uniform_bucket_level_access && !google_storage_bucket.kora_captures.force_destroy
    error_message = "Meal photos must remain private and bucket deletion must refuse retained objects."
  }
  assert {
    condition     = length(google_storage_bucket.kora_captures.lifecycle_rule) == 1 && one(one(google_storage_bucket.kora_captures.lifecycle_rule).action).type == "SetStorageClass" && one(one(google_storage_bucket.kora_captures.lifecycle_rule).action).storage_class == "ARCHIVE" && one(one(google_storage_bucket.kora_captures.lifecycle_rule).condition).age == 90
    error_message = "Archive at 90 days without an age-based deletion policy."
  }
  assert {
    condition     = google_storage_bucket.kora_captures.soft_delete_policy[0].retention_duration_seconds == 0 && !google_storage_bucket.kora_captures.versioning[0].enabled
    error_message = "Account erasure must not retain recoverable image versions."
  }
  assert {
    condition     = google_storage_bucket_iam_member.kora_capture_api.member == "serviceAccount:kora-api-prod@synthetic-project.iam.gserviceaccount.com" && google_storage_bucket_iam_member.kora_capture_api.role == "roles/storage.objectUser"
    error_message = "Only the API workload receives object access through this policy."
  }
}
