resource "random_password" "roamie_database" {
  length  = 40
  special = false
}

resource "google_secret_manager_secret" "roamie_database" {
  project   = var.project_id
  secret_id = "${var.environment}-roamie-postgresql-password"
  replication {
    auto {}
  }
  labels = { app = "roamie", purpose = "database" }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "roamie_database" {
  secret      = google_secret_manager_secret.roamie_database.id
  secret_data = random_password.roamie_database.result
}

resource "random_password" "roamie_database_runtime" {
  length  = 40
  special = false
}

resource "google_secret_manager_secret" "roamie_database_runtime" {
  project   = var.project_id
  secret_id = "${var.environment}-roamie-postgresql-runtime-password"
  replication {
    auto {}
  }
  labels = { app = "roamie", purpose = "database" }
  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_version" "roamie_database_runtime" {
  secret      = google_secret_manager_secret.roamie_database_runtime.id
  secret_data = random_password.roamie_database_runtime.result
}
