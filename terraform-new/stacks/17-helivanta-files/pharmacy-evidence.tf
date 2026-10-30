locals {
  pharmacy_evidence_grants = {
    quarantine_read = { bucket = "prod_quarantine", role = local.helivanta_file_read }
    release_create  = { bucket = "prod_released", role = "roles/storage.objectCreator" }
    release_verify  = { bucket = "prod_released", role = local.helivanta_file_read }
  }
}

resource "google_storage_bucket_iam_member" "pharmacy_evidence" {
  for_each = local.pharmacy_evidence_grants
  bucket   = google_storage_bucket.helivanta_files[each.value.bucket].name
  role     = each.value.role
  member   = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/helivanta/sa/helivanta-pharmacy-evidence-worker"
  condition {
    title       = "pharmacy-prescription-evidence-only"
    description = "Private pharmacy-outlet paths only; excludes organisation, clinical and staff object owners."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${google_storage_bucket.helivanta_files[each.value.bucket].name}/objects/t/') && resource.name.extract('/o/{kind}/') == 'pharmacy_outlet'"
  }
  depends_on = [google_project_iam_custom_role.helivanta_file_read]
}
