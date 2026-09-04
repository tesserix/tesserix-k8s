data "google_service_account" "kora_dev_document_scanner" {
  account_id = "kora-dev-doc-scanner"
  project    = var.project_id
}

resource "google_storage_bucket_iam_member" "sandbox_source_promotion_verifier" {
  bucket = "kora-dev-doc-accepted-in"
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${data.google_service_account.kora_dev_document_scanner.email}"
}
