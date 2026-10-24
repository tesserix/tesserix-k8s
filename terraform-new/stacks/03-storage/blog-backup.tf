resource "google_storage_bucket_iam_member" "blog_backup_writer" {
  bucket = "tesseract-prod-backups-in"
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:postgres-backup-sa@${var.project_id}.iam.gserviceaccount.com"

  condition {
    title       = "mongodb-blog-backup-create-only"
    description = "Allow new blog backup archives without reading or deleting existing backups"
    expression  = "resource.name.startsWith('projects/_/buckets/tesseract-prod-backups-in/objects/prod/mongodb-blog/')"
  }
}
