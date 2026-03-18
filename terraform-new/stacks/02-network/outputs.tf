# Network Stack - Outputs

# ============================================================================
# VPC Outputs
# ============================================================================

output "vpc_id" {
  description = "VPC ID"
  value       = google_compute_network.vpc.id
}

output "vpc_name" {
  description = "VPC name"
  value       = google_compute_network.vpc.name
}

output "vpc_self_link" {
  description = "VPC self link"
  value       = google_compute_network.vpc.self_link
}

# ============================================================================
# Subnet Outputs
# ============================================================================

output "subnet_id" {
  description = "Subnet ID"
  value       = google_compute_subnetwork.subnet.id
}

output "subnet_name" {
  description = "Subnet name"
  value       = google_compute_subnetwork.subnet.name
}

output "subnet_self_link" {
  description = "Subnet self link"
  value       = google_compute_subnetwork.subnet.self_link
}

output "subnet_cidr" {
  description = "Subnet CIDR range"
  value       = google_compute_subnetwork.subnet.ip_cidr_range
}

output "subnet_region" {
  description = "Subnet region"
  value       = google_compute_subnetwork.subnet.region
}

# ============================================================================
# Secondary Ranges (for GKE)
# ============================================================================

output "pods_ip_range_name" {
  description = "Name of the secondary IP range for pods"
  value       = length(var.secondary_ip_ranges) > 0 ? var.secondary_ip_ranges[0].range_name : null
}

output "services_ip_range_name" {
  description = "Name of the secondary IP range for services"
  value       = length(var.secondary_ip_ranges) > 1 ? var.secondary_ip_ranges[1].range_name : null
}

output "secondary_ip_ranges" {
  description = "All secondary IP ranges"
  value       = google_compute_subnetwork.subnet.secondary_ip_range
}

# ============================================================================
# NAT Gateway Outputs
# ============================================================================

output "nat_router_name" {
  description = "Cloud Router name"
  value       = var.create_nat_gateway ? google_compute_router.router[0].name : null
}

output "nat_gateway_name" {
  description = "NAT Gateway name"
  value       = var.create_nat_gateway ? google_compute_router_nat.nat[0].name : null
}

# ============================================================================
# Private Services
# ============================================================================

output "private_ip_address" {
  description = "Private IP address for VPC peering"
  value       = var.enable_private_services ? google_compute_global_address.private_ip_address[0].address : null
}

output "private_vpc_connection_id" {
  description = "Private VPC connection ID"
  value       = var.enable_private_services ? google_service_networking_connection.private_vpc_connection[0].id : null
}

# ============================================================================
# Firewall Outputs
# ============================================================================

output "firewall_rule_ids" {
  description = "IDs of custom firewall rules"
  value       = { for k, v in google_compute_firewall.rules : k => v.id }
}

output "internal_firewall_id" {
  description = "ID of the allow-internal firewall rule"
  value       = var.create_default_firewall_rules ? google_compute_firewall.allow_internal[0].id : null
}
