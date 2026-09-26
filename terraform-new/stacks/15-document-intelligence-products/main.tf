# Each charts/apps/document-intelligence/products/<product>-<env>.yaml gets its own key, buckets,
# identities and database secret; names match the chart's document-intelligence.config helper.
locals {
  registry_dir = "${path.module}/../../../charts/apps/document-intelligence/products"
  releases = {
    for f in fileset(local.registry_dir, "*.yaml") : trimsuffix(f, ".yaml") => yamldecode(file("${local.registry_dir}/${f}"))
  }
  products = toset([for r in local.releases : r.product])

  # purpose => retentionDays key
  bucket_purposes = { quarantine = "quarantine", accepted = "source", derived = "pages", results = "results" }
  buckets = merge([
    for name, r in local.releases : {
      for purpose, retention in local.bucket_purposes : "${name}-${purpose}" => {
        release = name
        product = r.product
        env     = r.environment
        name    = "${name}-doc-${purpose}-in"
        purpose = purpose
        age     = r.retentionDays[retention]
      }
    }
  ]...)

  roles = ["signer", "reader", "scanner", "worker"]
  identities = merge([
    for name, r in local.releases : {
      for role in local.roles : "${name}-${role}" => { release = name, product = r.product, role = role, account_id = "${name}-ocr-${role}" }
    }
  ]...)

  # Least privilege per workload: signer=upload-api, reader=job-api, scanner=dispatch, worker=execution.
  grants = {
    signer  = [["quarantine", "roles/storage.objectCreator"], ["quarantine", "roles/storage.objectViewer"]]
    reader  = [["results", "roles/storage.objectViewer"]]
    scanner = [["quarantine", "roles/storage.objectAdmin"], ["accepted", "roles/storage.objectCreator"], ["accepted", "roles/storage.objectViewer"]]
    worker  = [["accepted", "roles/storage.objectViewer"], ["derived", "roles/storage.objectAdmin"], ["results", "roles/storage.objectCreator"], ["results", "roles/storage.objectViewer"]]
  }
  bucket_grants = merge([
    for key, id in local.identities : {
      for g in local.grants[id.role] : "${key}-${g[0]}-${g[1]}" => { identity = key, bucket = "${id.release}-${g[0]}", role = g[1] }
    }
  ]...)
}

check "registry_names" {
  assert {
    condition = alltrue([
      for name, r in local.releases : name == "${r.product}-${r.environment}" && can(regex("^[a-z][a-z0-9]*$", r.product)) && length("${name}-ocr-scanner") <= 30
    ])
    error_message = "Registry files must be named <product>-<environment>.yaml, product lowercase alphanumeric, and <product>-<environment>-ocr-scanner at most 30 characters."
  }
}

data "google_kms_key_ring" "prod" {
  name     = "tesseract-prod-in-keyring"
  location = var.region
}

data "google_storage_project_service_account" "gcs" {}

resource "google_kms_crypto_key" "document_data" {
  for_each = local.products

  name            = "${each.key}-document-data-key"
  key_ring        = data.google_kms_key_ring.prod.id
  rotation_period = "7776000s"
  purpose         = "ENCRYPT_DECRYPT"
  labels          = { tier = "product", product = each.key, purpose = "document-encryption" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_kms_crypto_key_iam_member" "gcs_agent" {
  for_each = local.products

  crypto_key_id = google_kms_crypto_key.document_data[each.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_bucket" "document" {
  for_each = local.buckets

  name                        = each.value.name
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = { product = each.value.product, environment = each.value.env, purpose = "document-${each.value.purpose}", region = "in", data_class = "restricted" }

  versioning {
    enabled = false
  }

  encryption {
    default_kms_key_name = google_kms_crypto_key.document_data[each.value.product].id
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = each.value.age
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_agent]
}

resource "google_service_account" "ocr" {
  for_each = local.identities

  account_id   = each.value.account_id
  display_name = "${each.value.product} document intelligence ${each.value.role}"
  description  = "Document intelligence ${each.value.role} for ${each.value.release}"
}

resource "google_service_account_iam_member" "workload_identity" {
  for_each = local.identities

  service_account_id = google_service_account.ocr[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[document-intelligence/${each.value.account_id}]"
}

# The upload API signs V4 URLs with its own identity.
resource "google_service_account_iam_member" "signer_self_token_creator" {
  for_each = { for k, v in local.identities : k => v if v.role == "signer" }

  service_account_id = google_service_account.ocr[each.key].name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_service_account.ocr[each.key].member
}

resource "google_storage_bucket_iam_member" "ocr" {
  for_each = local.bucket_grants

  bucket = google_storage_bucket.document[each.value.bucket].name
  role   = each.value.role
  member = google_service_account.ocr[each.value.identity].member
}

resource "google_project_iam_member" "worker_document_ai" {
  for_each = { for k, v in local.identities : k => v if v.role == "worker" }

  project = var.project_id
  role    = "roles/documentai.apiUser"
  member  = google_service_account.ocr[each.key].member
}

resource "random_password" "database" {
  for_each = local.releases

  length  = 40
  special = false
}

resource "google_secret_manager_secret" "database" {
  for_each = local.releases

  secret_id = "${each.value.environment}-document-intelligence-${each.value.product}-db-password"
  labels    = { app = "document-intelligence", product = each.value.product, purpose = "database" }
  replication {
    auto {}
  }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "database" {
  for_each = local.releases

  secret      = google_secret_manager_secret.database[each.key].id
  secret_data = random_password.database[each.key].result
}
