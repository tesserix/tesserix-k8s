resource "google_container_node_pool" "models" {
  name               = "models-e2"
  project            = var.project_id
  location           = var.region
  cluster            = google_container_cluster.primary.name
  node_locations     = ["${var.region}-a"]
  initial_node_count = 1
  max_pods_per_node  = 32

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 2
    location_policy      = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }

  node_config {
    machine_type      = "e2-standard-8"
    disk_size_gb      = 80
    disk_type         = "pd-standard"
    image_type        = "COS_CONTAINERD"
    spot              = false
    service_account   = var.node_service_account
    oauth_scopes      = var.node_oauth_scopes
    boot_disk_kms_key = var.boot_disk_kms_key
    labels            = merge(var.node_labels, { workload = "models" })
    tags              = ["prod", "tesseract", "models"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
    taint {
      key    = "dedicated"
      value  = "models"
      effect = "NO_SCHEDULE"
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initial_node_count, version]
  }
}
