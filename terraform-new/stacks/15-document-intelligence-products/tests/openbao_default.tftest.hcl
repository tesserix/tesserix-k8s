mock_provider "google" {}
mock_provider "random" {}

run "product_credentials_default_to_openbao" {
  command = plan
  variables {
    project_id = "synthetic-project"
    region     = "asia-south1"
  }
  assert {
    condition     = length(google_secret_manager_secret.database_gcp) == 0
    error_message = "OpenBao product releases must not provision GCP credential records."
  }
  assert {
    condition     = length(google_secret_manager_secret_version.database_gcp) == 0 && length(random_password.database_gcp) == 0
    error_message = "OpenBao product releases must not provision GCP credential values."
  }
}

run "public_sandbox_has_ephemeral_isolated_storage" {
  command = plan
  variables {
    project_id = "synthetic-project"
    region     = "asia-south1"
  }
  assert {
    condition = alltrue([for key, bucket in google_storage_bucket.document :
      bucket.soft_delete_policy[0].retention_duration_seconds == 0 && bucket.versioning[0].enabled == false
      if startswith(key, "ocr-sandbox-")
    ])
    error_message = "Sandbox images must not survive deletion as recoverable versions."
  }
  assert {
    condition     = length(google_storage_bucket_iam_member.public_sandbox_cleanup) == 4
    error_message = "Cleanup must be scoped to exactly the four sandbox buckets."
  }
}
