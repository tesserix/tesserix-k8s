locals {
  practitioner_evidence_grants = {
    quarantine_read = { bucket = "prod_quarantine", role = local.helivanta_file_read }
    release_create  = { bucket = "prod_released", role = "roles/storage.objectCreator" }
    release_verify  = { bucket = "prod_released", role = local.helivanta_file_read }
  }
}

resource "google_storage_bucket_iam_member" "practitioner_evidence" {
  for_each = local.practitioner_evidence_grants
  bucket   = google_storage_bucket.helivanta_files[each.value.bucket].name
  role     = each.value.role
  member   = "principal://iam.googleapis.com/projects/${data.google_project.project.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/helivanta/sa/helivanta-practitioner-evidence-worker"
  condition {
    title       = "practitioner-professional-evidence-only"
    description = "Private professional registry evidence only; excludes patient, pharmacy, organisation and HR files."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${google_storage_bucket.helivanta_files[each.value.bucket].name}/objects/t/') && resource.name.extract('/o/{kind}/') == 'practitioner'"
  }
  depends_on = [google_project_iam_custom_role.helivanta_file_read]
}
