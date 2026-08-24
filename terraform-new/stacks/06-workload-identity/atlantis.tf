module "atlantis_name" {
  source = "../../modules/naming"

  prefix      = "tesseract"
  environment = var.environment
  resource    = "atlantis"
  max_length  = 30
}

resource "google_service_account" "atlantis" {
  account_id   = module.atlantis_name.name
  display_name = "Atlantis Terraform Automation"
  description  = "Runs reviewed Terraform plans from the Atlantis KSA"
  project      = var.project_id
}

locals {
  atlantis_project_roles = [
    "roles/artifactregistry.admin",
    "roles/cloudkms.admin",
    "roles/compute.admin",
    "roles/container.admin",
    "roles/dns.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/iam.roleAdmin",
    "roles/identityplatform.admin",
    "roles/pubsub.admin",
    "roles/resourcemanager.projectIamAdmin",
    "roles/run.admin",
    "roles/secretmanager.admin",
    "roles/servicenetworking.networksAdmin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/storage.admin",
    "roles/vpcaccess.admin",
  ]
}

resource "google_project_iam_member" "atlantis_project_roles" {
  for_each = toset(local.atlantis_project_roles)

  project = var.project_id
  role    = each.value
  member  = google_service_account.atlantis.member
}

resource "google_service_account_iam_member" "atlantis_workload_identity" {
  service_account_id = google_service_account.atlantis.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[atlantis/atlantis]"
}
