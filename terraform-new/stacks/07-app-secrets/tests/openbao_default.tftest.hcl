mock_provider "google" {}
mock_provider "random" {}
override_data {
  target = data.terraform_remote_state.gke
  values = { outputs = {} }
}
override_data {
  target = data.terraform_remote_state.workload_identity
  values = { outputs = {} }
}
run "new_application_secrets_require_openbao" {
  command = plan
  variables {
    project_id  = "synthetic-project"
    namespaces  = []
    app_secrets = [{ name = "prod-new-product-session-secret", category = "auth" }]
  }
  expect_failures = [var.app_secrets]
}

run "legacy_sources_remain_managed_until_migrated" {
  command = plan
  variables {
    project_id  = "synthetic-project"
    namespaces  = []
    app_secrets = [{ name = "prod-jwt-secret", category = "auth" }]
  }
  assert {
    condition     = contains(keys(google_secret_manager_secret.app_secrets), "prod-jwt-secret")
    error_message = "The default guard must not delete an unmigrated legacy source."
  }
}
run "documented_platform_exception_is_retained" {
  command = plan
  variables {
    project_id  = "synthetic-project"
    namespaces  = []
    app_secrets = [{ name = "prod-synthetic-bootstrap", category = "platform", platform_exception_reason = "Shared control-plane recovery bootstrap" }]
  }
  assert {
    condition     = google_secret_manager_secret.app_secrets["prod-synthetic-bootstrap"].annotations["tesserix.io/platform-secret-reason"] == "Shared control-plane recovery bootstrap"
    error_message = "An explicit platform exception must remain reviewable in resource metadata."
  }
}
