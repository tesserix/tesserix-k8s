mock_provider "google" {}
mock_provider "google-beta" {}
override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}
override_resource {
  target          = google_project_iam_custom_role.onboarding_record_writer
  override_during = plan
  values          = { id = "projects/synthetic-project/roles/onboardingRecordWriter" }
}
run "onboarding_records_cannot_be_pruned_by_the_writer" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    create_kms_keyring = false
    enable_cmek        = false
    secrets            = []
  }
  assert {
    condition     = google_storage_bucket.onboarding_records.versioning[0].enabled && google_storage_bucket.onboarding_records.default_event_based_hold && length(google_storage_bucket.onboarding_records.lifecycle_rule) == 0 && !google_storage_bucket.onboarding_records.force_destroy
    error_message = "Onboarding history requires versions, holds, no expiry and no destructive teardown."
  }
  assert {
    condition     = google_storage_bucket.onboarding_records.uniform_bucket_level_access && google_storage_bucket.onboarding_records.public_access_prevention == "enforced"
    error_message = "Customer configuration must never be public."
  }
  assert {
    condition     = length(jsondecode(google_storage_bucket_iam_policy.onboarding_records.policy_data).bindings) == 1 && jsondecode(google_storage_bucket_iam_policy.onboarding_records.policy_data).bindings[0].members == ["serviceAccount:zitadel-operator-gip-migrator@synthetic-project.iam.gserviceaccount.com"]
    error_message = "Archive bucket policy must contain only the namespace-bound workload grant, without default project-wide viewer/editor grants."
  }
  assert {
    condition     = toset(google_project_iam_custom_role.onboarding_record_writer.permissions) == toset(["storage.objects.create", "storage.objects.get"])
    error_message = "The operator must not delete, overwrite or release holds."
  }
}
