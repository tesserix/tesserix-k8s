resource "google_container_node_pool" "general" {
  name               = "general-e2"
  project            = var.project_id
  location           = var.region
  cluster            = google_container_cluster.primary.name
  node_locations     = ["${var.region}-a"]
  initial_node_count = 1
  max_pods_per_node  = 110

  autoscaling {
    total_min_node_count = 1
    total_max_node_count = 1
    location_policy      = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
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
    labels            = merge(var.node_labels, { workload = "general" })
    tags              = ["prod", "tesseract", "general"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  lifecycle {
    precondition {
      condition = var.project_id != "tesseracthub-480811" || (
        alltrue([for pool in var.node_pools : pool.machine_type == "e2-standard-8" && !pool.spot && pool.total_max_count != null]) &&
        var.use_spot_instances != true &&
        8 * (1 + sum([for pool in var.node_pools : coalesce(lookup(var.node_pool_total_max_count_overrides, pool.name, pool.total_max_count), 0)])) <= sum([for c in local.e2_commitments : lookup(c.resources, "VCPU", 0)]) &&
        32768 * (1 + sum([for pool in var.node_pools : coalesce(lookup(var.node_pool_total_max_count_overrides, pool.name, pool.total_max_count), 0)])) <= sum([for c in local.e2_commitments : lookup(c.resources, "MEMORY", 0)])
      )
      error_message = "Production E2 pool ceilings must fit the existing regional CPU and RAM commitments."
    }
    prevent_destroy = true
    ignore_changes  = [initial_node_count, version]
  }
}

# Pool names and pod CIDR capacity are immutable; retire the empty model pool.
removed {
  from = google_container_node_pool.models
  lifecycle {
    destroy = true
  }
}
