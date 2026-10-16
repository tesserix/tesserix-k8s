mock_provider "google" {}
override_data {
  target = data.google_kms_key_ring.existing
  values = { id = "projects/synthetic-project/locations/asia-south1/keyRings/synthetic-keyring" }
}
override_data {
  target = data.google_project.project
  values = { number = "849928263410" }
}
run "supply_worker_has_only_private_organisation_path_access" {
  command = plan
  variables {
    project_id       = "synthetic-project"
    region           = "asia-south1"
    kms_location     = "asia-south1"
    kms_keyring_name = "synthetic-keyring"
  }
  assert {
    condition = length(google_storage_bucket_iam_member.supply_evidence) == 3 && alltrue([
      for key, grant in google_storage_bucket_iam_member.supply_evidence :
      grant.member == "principal://iam.googleapis.com/projects/849928263410/locations/global/workloadIdentityPools/synthetic-project.svc.id.goog/subject/ns/helivanta/sa/helivanta-supply-evidence-worker" &&
      contains(["roles/storage.objectCreator", local.helivanta_file_read], grant.role) &&
      length(grant.condition) == 1 &&
      strcontains(grant.condition[0].expression, "resource.name.extract('/o/{kind}/') == 'organisation'") &&
      strcontains(grant.condition[0].expression, "/objects/t/") &&
      strcontains(grant.condition[0].expression, "resource.type == 'storage.googleapis.com/Object'")
    ])
    error_message = "Supply evidence must use only its own KSA, get/create permissions and object-bound organisation conditions."
  }
  assert {
    condition = (google_storage_bucket_iam_member.supply_evidence["quarantine_read"].role == local.helivanta_file_read &&
      google_storage_bucket_iam_member.supply_evidence["release_create"].bucket == google_storage_bucket.helivanta_files["prod_released"].name &&
      google_storage_bucket_iam_member.supply_evidence["release_verify"].role == local.helivanta_file_read &&
    toset(google_project_iam_custom_role.helivanta_file_read.permissions) == toset(["storage.objects.get"]))
    error_message = "Supply must not create quarantine files or list, overwrite or delete any objects."
  }
}
