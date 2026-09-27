removed {
  from = random_password.roamie_database
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret.roamie_database
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_version.roamie_database
  lifecycle {
    destroy = false
  }
}

removed {
  from = random_password.roamie_database_runtime
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret.roamie_database_runtime
  lifecycle {
    destroy = false
  }
}

removed {
  from = google_secret_manager_secret_version.roamie_database_runtime
  lifecycle {
    destroy = false
  }
}
