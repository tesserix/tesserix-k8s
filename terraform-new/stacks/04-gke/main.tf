# GKE Stack - Kubernetes Cluster and Node Pools
# State: stacks/prod/gke/default.tfstate
# Dependencies: 02-network

# Reference network stack outputs
data "terraform_remote_state" "network" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/network"
  }
}

# Get the latest GKE version for the release channel
data "google_container_engine_versions" "gke_version" {
  project        = var.project_id
  location       = var.regional ? var.region : var.zones[0]
  version_prefix = var.kubernetes_version_prefix
}

# =============================================================================
# GKE Cluster
# =============================================================================

resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.regional ? var.region : var.zones[0]

  # Use the latest available version from the release channel
  min_master_version = var.use_latest_version ? data.google_container_engine_versions.gke_version.latest_master_version : null

  # Remove default node pool - we manage node pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  # Network configuration - from network stack
  network    = data.terraform_remote_state.network.outputs.vpc_name
  subnetwork = data.terraform_remote_state.network.outputs.subnet_name

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # Private cluster configuration
  dynamic "private_cluster_config" {
    for_each = var.enable_private_cluster ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = var.enable_private_endpoint
      master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    }
  }

  # Master authorized networks
  dynamic "master_authorized_networks_config" {
    for_each = var.master_authorized_networks != null ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  # IP allocation policy for VPC-native cluster
  ip_allocation_policy {
    cluster_secondary_range_name  = data.terraform_remote_state.network.outputs.pods_ip_range_name
    services_secondary_range_name = data.terraform_remote_state.network.outputs.services_ip_range_name
  }

  # Network policy (Calico)
  network_policy {
    enabled  = var.enable_network_policy
    provider = var.enable_network_policy ? "CALICO" : "PROVIDER_UNSPECIFIED"
  }

  # Addons configuration
  addons_config {
    http_load_balancing {
      disabled = !var.http_load_balancing
    }
    horizontal_pod_autoscaling {
      disabled = !var.horizontal_pod_autoscaling
    }
    network_policy_config {
      disabled = !var.enable_network_policy
    }
    gce_persistent_disk_csi_driver_config {
      enabled = var.gce_pd_csi_driver
    }
    gcs_fuse_csi_driver_config {
      enabled = var.gcs_fuse_csi_driver
    }
  }

  # Vertical Pod Autoscaling
  vertical_pod_autoscaling {
    enabled = var.vertical_pod_autoscaling
  }

  # Maintenance window
  maintenance_policy {
    daily_maintenance_window {
      start_time = var.maintenance_start_time
    }
  }

  # Release channel
  release_channel {
    channel = var.release_channel
  }

  # Logging and monitoring (legacy fields)
  logging_service    = var.enable_logging ? var.logging_service : "none"
  monitoring_service = var.enable_monitoring ? var.monitoring_service : "none"

  # Modern monitoring config (controls Managed Prometheus)
  monitoring_config {
    enable_components = var.enable_monitoring ? ["SYSTEM_COMPONENTS", "DAEMONSET", "DEPLOYMENT", "STATEFULSET", "STORAGE", "HPA", "POD", "CADVISOR", "KUBELET"] : []
    managed_prometheus {
      enabled = var.enable_managed_prometheus
    }
  }

  # Modern logging config
  logging_config {
    enable_components = var.enable_logging ? ["SYSTEM_COMPONENTS", "WORKLOADS"] : []
  }

  # Database encryption (etcd encryption at rest with KMS)
  # SECURITY: Encrypts Kubernetes secrets at the application layer (etcd)
  dynamic "database_encryption" {
    for_each = var.database_encryption_key_name != null ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = var.database_encryption_key_name
    }
  }

  # Binary authorization
  dynamic "binary_authorization" {
    for_each = var.enable_binary_authorization ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  # Resource labels
  resource_labels = merge(var.common_labels, var.cluster_labels)

  # Deletion protection (enabled for production)
  deletion_protection = var.deletion_protection

  lifecycle {
    ignore_changes = [
      node_pool,
      initial_node_count,
    ]
  }

  timeouts {
    create = "60m"
    update = "90m"
    delete = "90m"
  }
}

# =============================================================================
# Node Pools
# =============================================================================

resource "google_container_node_pool" "pools" {
  for_each = { for pool in var.node_pools : pool.name => pool }

  name     = each.value.name
  project  = var.project_id
  location = var.regional ? var.region : var.zones[0]
  cluster  = google_container_cluster.primary.name

  # Use the latest node version from the release channel
  version = var.use_latest_version ? data.google_container_engine_versions.gke_version.latest_node_version : null

  initial_node_count = each.value.initial_node_count
  max_pods_per_node  = each.value.max_pods_per_node

  autoscaling {
    min_node_count       = each.value.min_count
    max_node_count       = each.value.max_count
    total_min_node_count = each.value.total_min_count
    total_max_node_count = each.value.total_max_count
    location_policy      = each.value.location_policy
  }

  management {
    auto_repair  = each.value.auto_repair
    auto_upgrade = each.value.auto_upgrade
  }

  upgrade_settings {
    max_surge       = each.value.max_surge
    max_unavailable = each.value.max_unavailable
  }

  node_config {
    machine_type = each.value.machine_type
    disk_size_gb = each.value.disk_size_gb
    disk_type    = each.value.disk_type
    # Use global spot toggle if set, otherwise fall back to per-pool setting
    spot       = var.use_spot_instances != null ? var.use_spot_instances : each.value.spot
    image_type = each.value.image_type

    # Boot disk encryption with KMS (CMEK)
    # SECURITY: Encrypts node boot disks with customer-managed keys
    boot_disk_kms_key = var.boot_disk_kms_key

    service_account = var.node_service_account
    oauth_scopes    = var.node_oauth_scopes

    labels = merge(var.node_labels, each.value.labels)
    tags   = each.value.tags

    # Workload Identity
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Shielded instance config
    shielded_instance_config {
      enable_secure_boot          = each.value.enable_secure_boot
      enable_integrity_monitoring = each.value.enable_integrity_monitoring
    }

    dynamic "taint" {
      for_each = each.value.taints
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }

  timeouts {
    create = "60m"
    update = "90m"
    delete = "90m"
  }
}
