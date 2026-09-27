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
