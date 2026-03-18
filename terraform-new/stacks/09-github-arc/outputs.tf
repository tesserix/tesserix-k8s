# GitHub ARC Stack - Outputs

output "arc_controller_installed" {
  description = "ARC controller installation status"
  value       = var.enable_github_arc
}

output "arc_systems_namespace" {
  description = "ARC systems namespace"
  value       = var.arc_systems_namespace
}

output "arc_runners_namespace" {
  description = "ARC runners namespace"
  value       = var.arc_runners_namespace
}

output "runner_scale_sets" {
  description = "List of runner scale set names"
  value       = var.enable_github_arc ? [for rs in var.runner_scale_sets : rs.name] : []
}
