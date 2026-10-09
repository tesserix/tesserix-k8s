data "google_project" "current" {
  project_id = var.project_id
}

resource "google_storage_bucket" "ax" {
  for_each = toset(["snapshots", "backups"])
  name     = "${var.project_id}-ax-${each.key}"
  project  = var.project_id
  location = var.region

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  versioning { enabled = true }
  soft_delete_policy { retention_duration_seconds = 604800 }
  labels = { product = "ax", environment = "production", managed_by = "terraform" }

  dynamic "lifecycle_rule" {
    for_each = each.key == "backups" ? [1] : []
    content {
      condition { age = 30 }
      action { type = "Delete" }
    }
  }
  lifecycle { prevent_destroy = true }
}

resource "google_storage_bucket_iam_member" "runtime" {
  for_each = {
    atelet         = "snapshots"
    ate-api-server = "snapshots"
    ax-backup      = "backups"
    ax-postgres    = "backups"
    ax-restore     = "backups"
  }
  bucket = google_storage_bucket.ax[each.value].name
  role   = each.key == "ax-restore" ? "roles/storage.objectViewer" : "roles/storage.objectUser"
  member = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ax-system/sa/${each.key}"
}

resource "google_artifact_registry_repository_iam_member" "atelet_images" {
  project    = var.project_id
  location   = var.region
  repository = "global"
  role       = "roles/artifactregistry.reader"
  member     = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ax-system/sa/atelet"
}

resource "google_storage_bucket_iam_member" "archive_metadata" {
  for_each = toset(["ax-postgres", "ax-restore"])
  bucket   = google_storage_bucket.ax["backups"].name
  role     = "roles/storage.legacyBucketReader"
  member   = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/ax-system/sa/${each.key}"
}
