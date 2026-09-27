mock_provider "google" {}
mock_provider "google-beta" {}

override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}

run "retired_application_credentials_are_not_recreated" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    create_kms_keyring = false
    enable_cmek        = false
    secrets = [
      { secret_id = "prod-homechef-postgresql-password", secret_data = "synthetic-only", iam_bindings = [{ role = "roles/secretmanager.secretAccessor", member = "serviceAccount:synthetic@synthetic-project.iam.gserviceaccount.com" }] },
      { secret_id = "dev-kora-document-intelligence-signing-key", secret_data = "synthetic-only", iam_bindings = [{ role = "roles/secretmanager.secretAccessor", member = "serviceAccount:synthetic@synthetic-project.iam.gserviceaccount.com" }] },
      { secret_id = "prod-ghcr-token", secret_data = "synthetic-only", iam_bindings = [{ role = "roles/secretmanager.secretAccessor", member = "serviceAccount:synthetic@synthetic-project.iam.gserviceaccount.com" }] }
    ]
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret.secrets)) == toset(["prod-ghcr-token"])
    error_message = "Retired application secret resources must not be recreated."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_version.versions)) == toset(["prod-ghcr-token"])
    error_message = "Retired application versions must not be recreated."
  }
  assert {
    condition     = length(google_secret_manager_secret_iam_member.members) == 1
    error_message = "Retired application IAM must not be recreated."
  }
}
