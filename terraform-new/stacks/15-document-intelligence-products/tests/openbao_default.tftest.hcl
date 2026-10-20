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

run "retired_public_sandbox_keeps_no_storage" {
  command = plan
  variables {
    project_id = "synthetic-project"
    region     = "asia-south1"
  }
  assert {
    condition     = length([for key in keys(google_storage_bucket.document) : key if startswith(key, "ocr-sandbox-")]) == 0 && !contains(keys(google_kms_crypto_key.document_data), "ocr-sandbox")
    error_message = "The retired public sandbox must not provision buckets or keys."
  }
}
