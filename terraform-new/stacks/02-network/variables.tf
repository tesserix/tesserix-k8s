# Network Stack Variables

# ============================================================================
# General
# ============================================================================

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
  default     = "us-central1"
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

# ============================================================================
# VPC
# ============================================================================

variable "vpc_name" {
  description = "Name of the VPC"
  type        = string
  default     = "tesseract-prod-vpc"
}

variable "routing_mode" {
  description = "VPC routing mode (REGIONAL or GLOBAL)"
  type        = string
  default     = "REGIONAL"
}

variable "delete_default_routes" {
  description = "Delete default routes on VPC creation"
  type        = bool
  default     = false
}

variable "enable_private_services" {
  description = "Enable private services access (for Cloud SQL, etc.)"
  type        = bool
  default     = true
}

# ============================================================================
# NAT Gateway
# ============================================================================

variable "create_nat_gateway" {
  description = "Create Cloud NAT gateway"
  type        = bool
  default     = true
}

variable "nat_network_tier" {
  description = "Network tier for NAT (STANDARD or PREMIUM)"
  type        = string
  default     = "STANDARD"
}

variable "enable_nat_logging" {
  description = "Enable NAT logging"
  type        = bool
  default     = false
}

# ============================================================================
# Subnet
# ============================================================================

variable "subnet_name" {
  description = "Name of the subnet"
  type        = string
  default     = "tesseract-prod-subnet"
}

variable "subnet_cidr" {
  description = "Primary CIDR range for the subnet"
  type        = string
  default     = "10.0.0.0/20"
}

variable "private_ip_google_access" {
  description = "Enable private Google access"
  type        = bool
  default     = true
}

variable "secondary_ip_ranges" {
  description = "Secondary IP ranges for GKE pods and services"
  type = list(object({
    range_name    = string
    ip_cidr_range = string
  }))
  default = [
    {
      range_name    = "pods"
      ip_cidr_range = "10.100.0.0/16"
    },
    {
      range_name    = "services"
      ip_cidr_range = "10.200.0.0/20"
    }
  ]
}

# ============================================================================
# VPC Flow Logs
# ============================================================================

variable "enable_flow_logs" {
  description = "Enable VPC flow logs"
  type        = bool
  default     = false
}

variable "flow_logs_interval" {
  description = "Flow logs aggregation interval"
  type        = string
  default     = "INTERVAL_10_MIN"
}

variable "flow_logs_sampling" {
  description = "Flow logs sampling rate (0.0 to 1.0)"
  type        = number
  default     = 0.5
}

variable "flow_logs_metadata" {
  description = "Flow logs metadata to include"
  type        = string
  default     = "INCLUDE_ALL_METADATA"
}

# ============================================================================
# Firewall
# ============================================================================

variable "firewall_rules" {
  description = "Custom firewall rules"
  type = list(object({
    name        = string
    description = string
    direction   = string
    priority    = number
    ranges      = list(string)
    source_tags = list(string)
    target_tags = list(string)
    allow = list(object({
      protocol = string
      ports    = list(string)
    }))
    deny = list(object({
      protocol = string
      ports    = list(string)
    }))
    log_config = object({
      metadata = string
    })
  }))
  default = []
}

variable "create_default_firewall_rules" {
  description = "Create default firewall rules"
  type        = bool
  default     = true
}

variable "allow_iap_ssh" {
  description = "Allow SSH from IAP"
  type        = bool
  default     = true
}

variable "internal_ranges" {
  description = "Internal IP ranges for allow-internal rule"
  type        = list(string)
  default     = ["10.0.0.0/8"]
}
