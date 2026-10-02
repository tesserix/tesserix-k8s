# Retain the existing auxiliary pools at zero nodes under the cluster ceiling.

resource "google_container_node_pool" "sandbox_gvisor" {
  cluster            = google_container_cluster.primary.name
  initial_node_count = 0
  location           = var.region
  max_pods_per_node  = 110
  name               = "sandbox-gvisor"
  node_count         = 0
  node_locations     = ["asia-south1-a"]
  project            = var.project_id
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  network_config {
    create_pod_range     = false
    enable_private_nodes = true
    pod_ipv4_cidr_block  = "10.20.0.0/16"
    pod_range            = "pods"
  }
  node_config {
    boot_disk_kms_key           = null
    disk_size_gb                = 100
    disk_type                   = "pd-balanced"
    enable_confidential_storage = false
    guest_accelerator           = []
    image_type                  = "COS_CONTAINERD"
    labels = {
      "sandbox.gke.io/runtime" = "gvisor"
      workload                 = "substrate"
    }
    local_ssd_count = 0
    logging_variant = "DEFAULT"
    machine_type    = "e2-standard-4"
    metadata = {
      disable-legacy-endpoints = "true"
    }
    node_group   = null
    oauth_scopes = ["https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/servicecontrol", "https://www.googleapis.com/auth/trace.append"]
    preemptible  = false
    resource_labels = {
      goog-gke-node-pool-provisioning-model = "on-demand"
    }
    resource_manager_tags = {}
    service_account       = "default"
    spot                  = false
    tags                  = []
    kubelet_config {
      cpu_cfs_quota                          = false
      cpu_cfs_quota_period                   = null
      cpu_manager_policy                     = ""
      insecure_kubelet_readonly_port_enabled = "FALSE"
      pod_pids_limit                         = 0
    }
    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = true
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initial_node_count, version]
  }

  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
    strategy        = "SURGE"
  }
}

resource "google_container_node_pool" "gpu_l4_spot" {
  cluster            = google_container_cluster.primary.name
  initial_node_count = 0
  location           = var.region
  max_pods_per_node  = 110
  name               = "gpu-l4-spot"
  node_count         = 0
  node_locations     = ["asia-south1-b"]
  project            = var.project_id
  management {
    auto_repair  = true
    auto_upgrade = true
  }
  network_config {
    create_pod_range     = false
    enable_private_nodes = true
    pod_ipv4_cidr_block  = "10.20.0.0/16"
    pod_range            = "pods"
  }
  node_config {
    boot_disk_kms_key           = null
    disk_size_gb                = 100
    disk_type                   = "pd-ssd"
    enable_confidential_storage = false
    guest_accelerator = [{
      count = 1
      gpu_driver_installation_config = [{
        gpu_driver_version = "DEFAULT"
      }]
      gpu_partition_size = ""
      gpu_sharing_config = []
      type               = "nvidia-l4"
    }]
    image_type = "COS_CONTAINERD"
    labels = {
      gpu      = "l4"
      workload = "ai-inference"
    }
    local_ssd_count = 0
    logging_variant = "DEFAULT"
    machine_type    = "g2-standard-4"
    metadata = {
      disable-legacy-endpoints = "true"
    }
    node_group   = null
    oauth_scopes = ["https://www.googleapis.com/auth/devstorage.read_only", "https://www.googleapis.com/auth/logging.write", "https://www.googleapis.com/auth/monitoring", "https://www.googleapis.com/auth/service.management.readonly", "https://www.googleapis.com/auth/servicecontrol", "https://www.googleapis.com/auth/trace.append"]
    preemptible  = false
    resource_labels = {
      goog-gke-accelerator-type             = "nvidia-l4"
      goog-gke-node-pool-provisioning-model = "spot"
    }
    resource_manager_tags = {}
    service_account       = "default"
    spot                  = true
    tags                  = []
    kubelet_config {
      cpu_cfs_quota                          = false
      cpu_cfs_quota_period                   = null
      cpu_manager_policy                     = ""
      insecure_kubelet_readonly_port_enabled = "FALSE"
      pod_pids_limit                         = 0
    }
    shielded_instance_config {
      enable_integrity_monitoring = true
      enable_secure_boot          = false
    }
    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [initial_node_count, version]
  }

  upgrade_settings {
    max_surge       = 0
    max_unavailable = 1
    strategy        = "SURGE"
  }
}
