resource "google_storage_bucket" "roamie_database_backups" {
  name                        = "${var.project_id}-roamie-db-backups-${var.environment}"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false
  labels                      = { app = "roamie", purpose = "database-backup" }
  lifecycle {
    prevent_destroy = true
  }
}
