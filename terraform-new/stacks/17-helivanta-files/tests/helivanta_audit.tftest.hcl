mock_provider "google" {}

override_data {
  target = data.google_project.project
  values = { number = "849928263410" }
}

run "audit_key_identity_follows_the_current_project" {
  command = plan
  override_data {
    target = data.google_project.project
    values = { number = "123456789012" }
  }
  variables {
    project_id       = "another-synthetic-project"
    region           = "asia-south1"
    kms_location     = "asia-south1"
    kms_keyring_name = "synthetic-keyring"
  }
  assert {
    condition     = google_kms_crypto_key_iam_member.helivanta_audit.member == "serviceAccount:service-123456789012@gcp-sa-logging.iam.gserviceaccount.com"
    error_message = "Only the current project's verified Logging service identity may use the audit encryption key."
  }
}
override_data {
  target = data.google_kms_key_ring.existing
  values = { id = "projects/synthetic-project/locations/asia-south1/keyRings/synthetic-keyring" }
}

run "private_file_access_has_auditable_regional_retention" {
  command = plan
  variables {
    project_id       = "synthetic-project"
    region           = "asia-south1"
    kms_location     = "asia-south1"
    kms_keyring_name = "synthetic-keyring"
  }
  assert {
    condition = (google_project_iam_audit_config.helivanta_storage.service == "storage.googleapis.com" &&
      toset([for entry in google_project_iam_audit_config.helivanta_storage.audit_log_config : entry.log_type]) == toset(["DATA_READ", "DATA_WRITE"]) &&
      alltrue([for entry in google_project_iam_audit_config.helivanta_storage.audit_log_config : length(entry.exempted_members) == 0])
    )
    error_message = "Storage access auditing must include reads/writes without exempting workloads."
  }
  assert {
    condition = (google_logging_project_bucket_config.helivanta_files.location == "asia-south1" &&
      google_logging_project_bucket_config.helivanta_files.retention_days == 400 &&
      google_logging_project_bucket_config.helivanta_files.cmek_settings[0].kms_key_name == local.helivanta_audit_key_id &&
      google_kms_crypto_key_iam_member.helivanta_audit.member == "serviceAccount:service-849928263410@gcp-sa-logging.iam.gserviceaccount.com"
    )
    error_message = "Private file audit evidence needs regional CMEK retention and only the Logging service identity on its separate key."
  }
  assert {
    condition = (!google_logging_project_sink.helivanta_files.disabled &&
      google_logging_project_sink.helivanta_files.destination == "logging.googleapis.com/projects/synthetic-project/locations/asia-south1/buckets/helivanta-private-files" &&
      alltrue([for bucket in google_storage_bucket.helivanta_files : strcontains(google_logging_project_sink.helivanta_files.filter, bucket.name)]) &&
      !strcontains(google_logging_project_sink.helivanta_files.filter, "backups") &&
      strcontains(google_logging_project_sink.helivanta_files.filter, "resource.type=\"gcs_bucket\"")
    )
    error_message = "The audit sink must retain only the four dedicated file buckets in its own log bucket."
  }
}
