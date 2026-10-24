mock_provider "google" {}
mock_provider "google-beta" {}
override_data {
  target = data.terraform_remote_state.foundation
  values = { outputs = {} }
}
run "blog_uploader_can_only_create_its_own_archives" {
  command = plan
  variables {
    project_id         = "synthetic-project"
    create_kms_keyring = false
    enable_cmek        = false
    secrets            = []
  }
  assert {
    condition     = google_storage_bucket_iam_member.blog_backup_writer.role == "roles/storage.objectCreator" && google_storage_bucket_iam_member.blog_backup_writer.member == "serviceAccount:postgres-backup-sa@synthetic-project.iam.gserviceaccount.com"
    error_message = "The existing backup identity must only receive object creation rights."
  }
  assert {
    condition     = google_storage_bucket_iam_member.blog_backup_writer.bucket == "tesseract-prod-backups-in" && google_storage_bucket_iam_member.blog_backup_writer.condition[0].expression == "resource.name.startsWith('projects/_/buckets/tesseract-prod-backups-in/objects/prod/mongodb-blog/')"
    error_message = "Backup writes must be restricted to the blog prefix."
  }
}
