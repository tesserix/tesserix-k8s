# Foundation Stack - Enable Required GCP APIs
# State: stacks/{environment}/foundation/default.tfstate
# Dependencies: None (this is the first stack)

# Enable required GCP APIs
resource "google_project_service" "apis" {
  for_each = toset(var.apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = var.disable_on_destroy

  timeouts {
    create = "30m"
    update = "40m"
  }
}

resource "google_project_iam_member" "github_actions_compute_network_viewer" {
  project = var.project_id
  role    = "roles/compute.networkViewer"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "github_actions_dns_reader" {
  project = var.project_id
  role    = "roles/dns.reader"
  member  = "serviceAccount:github-actions@${var.project_id}.iam.gserviceaccount.com"
}

# Create the state bucket if it doesn't exist
# Note: This is bootstrapped manually or via a separate bootstrap script
resource "google_storage_bucket" "terraform_state" {
  count = var.create_state_bucket ? 1 : 0

  name          = var.state_bucket_name
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  versioning {
    enabled = true
  }

  uniform_bucket_level_access = true

  labels = var.common_labels

  lifecycle {
    prevent_destroy = true
  }
}
