# GKE Stack Variables

# =============================================================================
# General
# =============================================================================

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-central1"
}

variable "zones" {
  description = "The GCP zones for the cluster"
  type        = list(string)
  default     = []
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "state_bucket" {
  description = "GCS bucket for Terraform state"
  type        = string
  default     = "tesseract-terraform-states"
}

variable "common_labels" {
  description = "Common labels for resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Cluster Configuration
# =============================================================================

variable "cluster_name" {
  description = "Name of the GKE cluster"
  type        = string
  default     = "tesseract-prod-cluster"
}

variable "regional" {
  description = "Whether to create a regional cluster (true) or zonal (false)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection for the cluster"
  type        = bool
  default     = true
}

variable "cluster_labels" {
  description = "Additional labels for the cluster"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Kubernetes Version
# =============================================================================

variable "release_channel" {
  description = "Release channel (UNSPECIFIED, RAPID, REGULAR, STABLE)"
  type        = string
  default     = "REGULAR"
}

variable "use_latest_version" {
  description = "Use the latest available GKE version"
  type        = bool
  default     = true
}

variable "kubernetes_version_prefix" {
  description = "Kubernetes version prefix (e.g., '1.28')"
  type        = string
  default     = null
}

# =============================================================================
# Private Cluster
# =============================================================================

variable "enable_private_cluster" {
  description = "Enable private cluster"
  type        = bool
  default     = true
}

variable "enable_private_endpoint" {
  description = "Enable private endpoint (master not accessible from internet)"
  type        = bool
  default     = false
}

variable "master_ipv4_cidr_block" {
  description = "CIDR block for the master's private IP"
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  description = "List of master authorized networks"
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = null
}

# =============================================================================
# Network Policy & Addons
# =============================================================================

variable "enable_network_policy" {
  description = "Enable network policy (Calico)"
  type        = bool
  default     = true
}

variable "http_load_balancing" {
  description = "Enable HTTP load balancing addon"
  type        = bool
  default     = true
}

variable "horizontal_pod_autoscaling" {
  description = "Enable horizontal pod autoscaling addon"
  type        = bool
  default     = true
}

variable "vertical_pod_autoscaling" {
  description = "Enable vertical pod autoscaling"
  type        = bool
  default     = true
}

variable "gce_pd_csi_driver" {
  description = "Enable GCE Persistent Disk CSI Driver"
  type        = bool
  default     = true
}

variable "gcs_fuse_csi_driver" {
  description = "Enable GCS FUSE CSI Driver"
  type        = bool
  default     = false
}

variable "enable_binary_authorization" {
  description = "Enable binary authorization"
  type        = bool
  default     = false
}

# =============================================================================
# Logging & Monitoring
# =============================================================================

variable "enable_logging" {
  description = "Enable Google Cloud Logging"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable Google Cloud Monitoring"
  type        = bool
  default     = true
}

variable "logging_service" {
  description = "The logging service to use"
  type        = string
  default     = "logging.googleapis.com/kubernetes"
}

variable "monitoring_service" {
  description = "The monitoring service to use"
  type        = string
  default     = "monitoring.googleapis.com/kubernetes"
}

variable "enable_managed_prometheus" {
  description = "Enable GKE Managed Prometheus (costs ~$150/mo for metric ingestion)"
  type        = bool
  default     = false
}

# =============================================================================
# Maintenance
# =============================================================================

variable "maintenance_start_time" {
  description = "Start time for maintenance window (UTC)"
  type        = string
  default     = "03:00"
}

# =============================================================================
# Node Pools
# =============================================================================

variable "use_spot_instances" {
  description = <<-EOT
    Global toggle to enable/disable Spot VMs for all node pools.
    Spot VMs offer up to 60-91% cost savings but can be preempted with 30s notice.

    Values:
      - true:  Use Spot VMs (recommended for cost optimization, dev/test, or fault-tolerant workloads)
      - false: Use On-Demand VMs (recommended for production critical workloads)
      - null:  Use per-pool 'spot' setting (allows mixed pools)

    Note: When set to true/false, this overrides the per-pool 'spot' setting.
          When set to null, each pool uses its own 'spot' configuration.

    Cost Savings (asia-south1, e2-standard-8):
      - On-Demand: ~$194/month per node
      - Spot:      ~$58/month per node (70% savings)
  EOT
  type        = bool
  default     = null
}

variable "node_pools" {
  description = "List of node pools to create"
  type = list(object({
    name                        = string
    machine_type                = optional(string, "e2-standard-4")
    disk_size_gb                = optional(number, 100)
    disk_type                   = optional(string, "pd-ssd")
    image_type                  = optional(string, "COS_CONTAINERD")
    spot                        = optional(bool, false)
    initial_node_count          = optional(number, 1)
    min_count                   = optional(number, 1)
    max_count                   = optional(number, 3)
    total_min_count             = optional(number, null)
    total_max_count             = optional(number, null)
    location_policy             = optional(string, "BALANCED")
    auto_repair                 = optional(bool, true)
    auto_upgrade                = optional(bool, true)
    max_surge                   = optional(number, 1)
    max_unavailable             = optional(number, 0)
    max_pods_per_node           = optional(number, 110)
    enable_secure_boot          = optional(bool, true)
    enable_integrity_monitoring = optional(bool, true)
    labels                      = optional(map(string), {})
    tags                        = optional(list(string), [])
    oauth_scopes                = optional(list(string), null)
    taints = optional(list(object({
      key    = string
      value  = string
      effect = string
    })), [])
  }))
  default = [
    {
      name         = "default-pool"
      machine_type = "e2-standard-4"
      min_count    = 1
      max_count    = 3
    }
  ]
}

variable "node_service_account" {
  description = "Service account for nodes"
  type        = string
  default     = null
}

variable "node_oauth_scopes" {
  description = "OAuth scopes for nodes"
  type        = list(string)
  default = [
    "https://www.googleapis.com/auth/cloud-platform",
  ]
}

variable "node_labels" {
  description = "Labels to apply to all nodes"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Security & Encryption (CMEK)
# =============================================================================

variable "database_encryption_key_name" {
  description = "KMS key name for etcd encryption at rest (GKE database encryption). Format: projects/{project}/locations/{location}/keyRings/{keyring}/cryptoKeys/{key}"
  type        = string
  default     = null
}

variable "boot_disk_kms_key" {
  description = "KMS key for node boot disk encryption (CMEK). Format: projects/{project}/locations/{location}/keyRings/{keyring}/cryptoKeys/{key}"
  type        = string
  default     = null
}
