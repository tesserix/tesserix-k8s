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
    # 01-foundation manages google_document_ai_processor.generic_ocr, and
    # Atlantis could not even REFRESH it: every plan since 2026-09-21 died with
    #
    #   Error 403: Permission 'documentai.processors.get' denied on
    #   .../locations/asia-south1/processors/395d58b2596d5031
    #
    # 01-foundation is execution_order_group 2 and atlantis.yaml sets
    # abort_on_execution_order_fail: true, so groups 3-7 never ran. Everything
    # behind it silently stopped deploying -- including 14-uptime-monitoring,
    # whose state is still an empty skeleton (serial 1, zero resources) and
    # whose uptime checks and alert policies therefore do not exist in GCP at
    # all. That is why the 2026-09-24 Cloudflare APAC incident was found by a
    # human opening a blank page instead of by the monitoring built for it.
    #
    # editor, not admin: terraform creates and updates the processor but has no
    # need of the dataset and evaluation permissions admin also carries.
    "roles/documentai.editor",
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
