mock_provider "google" {}

override_data {
  target = data.google_kms_key_ring.existing
  values = { id = "projects/synthetic-project/locations/asia-south1/keyRings/synthetic-keyring" }
}
override_data {
  target = data.google_project.project
  values = { number = "849928263410" }
}

run "private_files_are_separate_encrypted_and_have_no_destructive_identity" {
  command = plan
  variables {
    project_id       = "synthetic-project"
    region           = "asia-south1"
    kms_location     = "asia-south1"
    kms_keyring_name = "synthetic-keyring"
  }
  assert {
    condition = length(google_storage_bucket.helivanta_files) == 4 && alltrue([
      for bucket in google_storage_bucket.helivanta_files :
      bucket.uniform_bucket_level_access && bucket.public_access_prevention == "enforced" && !bucket.force_destroy &&
      bucket.location == "ASIA-SOUTH1" && bucket.encryption[0].default_kms_key_name == local.helivanta_file_key_id &&
      bucket.name != "synthetic-project-helivanta-backup" && length(bucket.lifecycle_rule) == 0 && length(bucket.cors) == 0
    ])
    error_message = "Application/verification files need distinct private regional CMEK buckets, no direct browser CORS and no automatic deletion."
  }
  assert {
    condition = toset(google_project_iam_custom_role.helivanta_file_read.permissions) == toset(["storage.objects.get"]) && alltrue([
      for grant in google_storage_bucket_iam_member.helivanta_files :
      contains(["roles/storage.objectCreator", local.helivanta_file_read], grant.role) &&
      startswith(grant.member, "principal://iam.googleapis.com/projects/849928263410/locations/global/workloadIdentityPools/synthetic-project.svc.id.goog/subject/ns/helivanta/sa/")
    ])
    error_message = "File workloads must have exact Kubernetes identities and create/get-only permissions, without listing, overwriting or deleting objects."
  }
  assert {
    condition = alltrue([
      for key, grant in google_storage_bucket_iam_member.helivanta_files :
      !(endswith(grant.member, "/helivanta-api") && grant.bucket == google_storage_bucket.helivanta_files["prod_released"].name && grant.role == "roles/storage.objectCreator") &&
      !(endswith(grant.member, "/helivanta-file-verifier") && startswith(key, "prod_"))
    ])
    error_message = "API cannot create releases; the verifier must not receive production access."
  }
}
