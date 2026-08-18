# Kubernetes Bootstrap Stack - Outputs

# =============================================================================
# Kong Outputs
# =============================================================================

output "kong_installed" {
  description = "Kong installation status"
  value       = var.install_kong
}

output "kong_namespace" {
  description = "Kong namespace"
  value       = var.kong_namespace
}

output "kong_proxy_service" {
  description = "Kong proxy service name"
  value       = var.install_kong ? "${var.kong_namespace}/kong-kong-proxy" : null
}

# =============================================================================
# Cert-Manager Outputs
# =============================================================================

output "cert_manager_installed" {
  description = "Cert-Manager installation status"
  value       = var.install_cert_manager
}

output "cert_manager_namespace" {
  description = "Cert-Manager namespace"
  value       = var.cert_manager_namespace
}

output "letsencrypt_staging_issuer" {
  description = "Let's Encrypt staging issuer name"
  value       = var.install_cert_manager && var.cloudflare_api_token != "" ? "letsencrypt-staging" : null
  sensitive   = true
}

output "letsencrypt_prod_issuer" {
  description = "Let's Encrypt production issuer name"
  value       = var.install_cert_manager && var.cloudflare_api_token != "" ? "letsencrypt-prod" : null
  sensitive   = true
}

# =============================================================================
# ArgoCD Outputs
# =============================================================================

output "argocd_installed" {
  description = "ArgoCD installation status"
  value       = var.install_argocd
}

output "argocd_namespace" {
  description = "ArgoCD namespace"
  value       = var.argocd_namespace
}

output "argocd_server_service" {
  description = "ArgoCD server service name"
  value       = var.install_argocd ? "${var.argocd_namespace}/argocd-server" : null
}

output "argocd_url" {
  description = "ArgoCD URL"
  value       = var.argocd_ingress_enabled ? "https://${var.argocd_hostname}" : null
}

# =============================================================================
# External Secrets Operator Outputs
# =============================================================================

output "external_secrets_installed" {
  description = "External Secrets Operator installation status"
  value       = var.install_external_secrets
}

output "external_secrets_namespace" {
  description = "External Secrets Operator namespace"
  value       = var.external_secrets_namespace
}

output "external_secrets_service_account" {
  description = "External Secrets Operator service account"
  value       = var.install_external_secrets ? var.external_secrets_service_account : null
}

output "external_secrets_cluster_store_name" {
  description = "ClusterSecretStore name for GCP Secret Manager"
  value       = var.install_external_secrets ? "gcp-secret-store" : null
}

# =============================================================================
# Bootstrap Ready
# =============================================================================

output "k8s_bootstrap_ready" {
  description = "Kubernetes bootstrap completion status"
  value       = true

  depends_on = [
    helm_release.kong,
    helm_release.cert_manager,
    helm_release.argocd,
    helm_release.external_secrets
  ]
}
