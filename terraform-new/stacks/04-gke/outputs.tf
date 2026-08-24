# GKE Stack - Outputs

# =============================================================================
# Cluster Outputs
# =============================================================================

output "cluster_id" {
  description = "Cluster ID"
  value       = google_container_cluster.primary.id
}

output "cluster_name" {
  description = "Cluster name"
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "Cluster endpoint"
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Cluster CA certificate (base64 encoded)"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_location" {
  description = "Cluster location (region or zone)"
  value       = google_container_cluster.primary.location
}

output "cluster_master_version" {
  description = "Cluster master version"
  value       = google_container_cluster.primary.master_version
}

output "cluster_self_link" {
  description = "Cluster self link"
  value       = google_container_cluster.primary.self_link
}

# =============================================================================
# Network Outputs
# =============================================================================

output "cluster_network" {
  description = "Cluster network"
  value       = google_container_cluster.primary.network
}

output "cluster_subnetwork" {
  description = "Cluster subnetwork"
  value       = google_container_cluster.primary.subnetwork
}

# =============================================================================
# Workload Identity
# =============================================================================

output "workload_identity_pool" {
  description = "Workload Identity pool"
  value       = "${var.project_id}.svc.id.goog"
}

# =============================================================================
# Node Pool Outputs
# =============================================================================

output "node_pool_names" {
  description = "List of node pool names"
  value       = [for pool in google_container_node_pool.pools : pool.name]
}

output "node_pools" {
  description = "Map of node pool details"
  value = {
    for k, pool in google_container_node_pool.pools : k => {
      name           = pool.name
      node_count     = pool.node_count
      version        = pool.version
      instance_group = pool.instance_group_urls
    }
  }
}

# =============================================================================
# kubectl Configuration
# =============================================================================

output "kubectl_config_command" {
  description = "Command to configure kubectl"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --region ${google_container_cluster.primary.location} --project ${var.project_id}"
}

# =============================================================================
# Connection Info for Other Stacks
# =============================================================================

output "cluster_connection" {
  description = "Cluster connection info for Kubernetes provider"
  value = {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
  sensitive = true
}

# =============================================================================
# Security Configuration Outputs
# =============================================================================

output "security_config" {
  description = "Security configuration status"
  value = {
    database_encryption_enabled  = var.database_encryption_key_name != null
    boot_disk_encryption_enabled = var.boot_disk_kms_key != null
    private_cluster_enabled      = var.enable_private_cluster
    network_policy_enabled       = var.enable_network_policy
    binary_authorization_enabled = var.enable_binary_authorization
    workload_identity_enabled    = true # Always enabled
    shielded_nodes_enabled       = true # Enabled in node pool config
  }
}

# =============================================================================
# Cost Optimization Outputs
# =============================================================================

output "spot_instances_config" {
  description = "Spot VM configuration for cost optimization"
  value = {
    global_spot_enabled = var.use_spot_instances
    mode                = var.use_spot_instances == true ? "SPOT (cost-optimized)" : var.use_spot_instances == false ? "ON-DEMAND (reliability)" : "PER-POOL (mixed)"
    estimated_savings   = var.use_spot_instances == true ? "~70% vs on-demand pricing" : "N/A"
    node_pools_using_spot = [
      for k, pool in google_container_node_pool.pools : pool.name
      if var.use_spot_instances == true || (var.use_spot_instances == null && try(var.node_pools[index(var.node_pools.*.name, k)].spot, false))
    ]
  }
}
