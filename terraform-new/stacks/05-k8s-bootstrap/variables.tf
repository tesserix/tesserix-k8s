# Kubernetes Bootstrap Stack Variables

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

# =============================================================================
# Kong Configuration
# =============================================================================

variable "install_kong" {
  description = "Install Kong Ingress Controller"
  type        = bool
  default     = true
}

variable "kong_namespace" {
  description = "Namespace for Kong"
  type        = string
  default     = "kong"
}

variable "kong_chart_version" {
  description = "Kong Helm chart version"
  type        = string
  default     = "2.33.0"
}

variable "kong_ingress_class" {
  description = "Kong ingress class"
  type        = string
  default     = "kong"
}

variable "kong_proxy_service_type" {
  description = "Kong proxy service type"
  type        = string
  default     = "LoadBalancer"
}

variable "kong_proxy_annotations" {
  description = "Kong proxy service annotations"
  type        = map(string)
  default     = {}
}

variable "kong_admin_enabled" {
  description = "Enable Kong admin API"
  type        = bool
  default     = true
}

variable "kong_replicas" {
  description = "Number of Kong replicas"
  type        = number
  default     = 2
}

variable "kong_resources" {
  description = "Kong resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "512Mi"
    }
    requests = {
      memory = "128Mi"
    }
  }
}

# =============================================================================
# Cert-Manager Configuration
# =============================================================================

variable "install_cert_manager" {
  description = "Install Cert-Manager"
  type        = bool
  default     = true
}

variable "cert_manager_namespace" {
  description = "Namespace for Cert-Manager"
  type        = string
  default     = "cert-manager"
}

variable "cert_manager_chart_version" {
  description = "Cert-Manager Helm chart version"
  type        = string
  default     = "v1.13.3"
}

variable "cert_manager_replicas" {
  description = "Number of Cert-Manager replicas"
  type        = number
  default     = 1
}

variable "cert_manager_resources" {
  description = "Cert-Manager resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "256Mi"
    }
    requests = {
      memory = "64Mi"
    }
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS01 challenge"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_cloudflare_dns" {
  description = "Enable Cloudflare DNS01 challenge (set to true when cloudflare_api_token is provided)"
  type        = bool
  default     = false
}

variable "cloudflare_domain" {
  description = "Cloudflare domain for DNS01 challenge"
  type        = string
  default     = ""
}

variable "letsencrypt_email" {
  description = "Email for Let's Encrypt notifications"
  type        = string
  default     = ""
}

variable "letsencrypt_issuer" {
  description = "Let's Encrypt issuer to use"
  type        = string
  default     = "letsencrypt-prod"
}

# =============================================================================
# Sealed Secrets Configuration
# =============================================================================

variable "install_sealed_secrets" {
  description = "Install Sealed Secrets"
  type        = bool
  default     = true
}

variable "sealed_secrets_namespace" {
  description = "Namespace for Sealed Secrets"
  type        = string
  default     = "kube-system"
}

variable "sealed_secrets_chart_version" {
  description = "Sealed Secrets Helm chart version"
  type        = string
  default     = "2.13.3"
}

variable "sealed_secrets_resources" {
  description = "Sealed Secrets resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "128Mi"
    }
    requests = {
      memory = "64Mi"
    }
  }
}

variable "generate_sealed_secrets_cert" {
  description = "Generate Sealed Secrets certificate"
  type        = bool
  default     = true
}

variable "sealed_secrets_tls_cert" {
  description = "Existing Sealed Secrets TLS certificate"
  type        = string
  default     = null
  sensitive   = true
}

variable "sealed_secrets_tls_key" {
  description = "Existing Sealed Secrets TLS key"
  type        = string
  default     = null
  sensitive   = true
}

variable "use_existing_sealed_secrets_cert" {
  description = "Use existing sealed secrets certificate (set to true when sealed_secrets_tls_cert and sealed_secrets_tls_key are provided)"
  type        = bool
  default     = false
}

variable "sealed_secrets_cert_organization" {
  description = "Sealed Secrets certificate organization"
  type        = string
  default     = "tesseracthub"
}

variable "sealed_secrets_cert_validity_hours" {
  description = "Sealed Secrets certificate validity in hours"
  type        = number
  default     = 87600 # 10 years
}

# =============================================================================
# ArgoCD Configuration
# =============================================================================

variable "install_argocd" {
  description = "Install ArgoCD"
  type        = bool
  default     = true
}

variable "argocd_use_operator" {
  description = <<-EOT
    ArgoCD is managed by the argoproj-labs argocd-operator (v0.18.0, Argo CD
    v3.3.10) as of 2026-07-21, not the argo-helm chart. When true, the
    helm_release.argocd resource is disabled so a future apply never reinstalls
    the Helm-based control plane. The operator + ArgoCD CR are installed
    manually (kustomize) and GitOps-managed via
    argocd/prod/infrastructure/argocd.yaml -> charts/argocd-operator/.
  EOT
  type        = bool
  default     = true
}

variable "argocd_namespace" {
  description = "Namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "ArgoCD Helm chart version"
  type        = string
  default     = "7.7.23"
}

variable "argocd_image_tag" {
  description = "ArgoCD image tag"
  type        = string
  default     = "v2.13.4"
}

variable "argocd_server_insecure" {
  description = "Run ArgoCD server in insecure mode. Set to false to enable TLS on the server."
  type        = bool
  default     = false
}

variable "argocd_server_replicas" {
  description = "Number of ArgoCD server replicas"
  type        = number
  default     = 1
}

variable "argocd_controller_replicas" {
  description = "Number of ArgoCD controller replicas"
  type        = number
  default     = 1
}

variable "argocd_repo_server_replicas" {
  description = "Number of ArgoCD repo server replicas"
  type        = number
  default     = 1
}

variable "argocd_service_type" {
  description = "ArgoCD server service type"
  type        = string
  default     = "ClusterIP"
}

variable "argocd_server_resources" {
  description = "ArgoCD server resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "256Mi"
    }
    requests = {
      memory = "64Mi"
    }
  }
}

variable "argocd_controller_resources" {
  description = "ArgoCD controller resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "512Mi"
    }
    requests = {
      memory = "128Mi"
    }
  }
}

variable "argocd_repo_server_resources" {
  description = "ArgoCD repo server resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "256Mi"
    }
    requests = {
      memory = "64Mi"
    }
  }
}

variable "argocd_notifications_enabled" {
  description = "Enable ArgoCD notifications"
  type        = bool
  default     = false
}

# ArgoCD SSO
variable "argocd_enable_sso" {
  description = "Enable ArgoCD SSO with Google"
  type        = bool
  default     = false
}

variable "argocd_admin_enabled" {
  description = "Keep admin login enabled (even when SSO is enabled). Set to true for fallback login option."
  type        = bool
  default     = true
}

variable "argocd_url" {
  description = "ArgoCD URL"
  type        = string
  default     = ""
}

variable "google_oauth_client_id" {
  description = "Google OAuth client ID"
  type        = string
  default     = ""
}

variable "google_oauth_client_secret" {
  description = "Google OAuth client secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "argocd_admin_users" {
  description = "List of ArgoCD admin users"
  type        = list(string)
  default     = []
}

# ArgoCD Ingress
variable "argocd_ingress_enabled" {
  description = "Enable ArgoCD ingress"
  type        = bool
  default     = true
}

variable "argocd_ingress_class" {
  description = "ArgoCD ingress class"
  type        = string
  default     = "kong"
}

variable "argocd_hostname" {
  description = "ArgoCD hostname"
  type        = string
  default     = ""
}

variable "argocd_ingress_tls" {
  description = "Enable TLS for ArgoCD ingress"
  type        = bool
  default     = true
}

variable "argocd_ingress_annotations" {
  description = "Additional ArgoCD ingress annotations"
  type        = map(string)
  default     = {}
}

# ArgoCD Repository
variable "argocd_repo_url" {
  description = "ArgoCD repository URL"
  type        = string
  default     = ""
}

variable "argocd_repo_auth_method" {
  description = "ArgoCD repository auth method (https, ssh, github-app)"
  type        = string
  default     = "https"
}

variable "argocd_repo_username" {
  description = "ArgoCD repository username"
  type        = string
  default     = ""
}

variable "argocd_repo_password" {
  description = "ArgoCD repository password"
  type        = string
  default     = ""
  sensitive   = true
}

# =============================================================================
# External Secrets Operator Configuration
# =============================================================================

variable "install_external_secrets" {
  description = "Install External Secrets Operator"
  type        = bool
  default     = true
}

variable "external_secrets_namespace" {
  description = "Namespace for External Secrets Operator"
  type        = string
  default     = "external-secrets"
}

variable "external_secrets_chart_version" {
  description = "External Secrets Operator Helm chart version"
  type        = string
  default     = "0.9.11"
}

variable "external_secrets_resources" {
  description = "External Secrets Operator resource limits and requests"
  type        = map(map(string))
  default = {
    limits = {
      memory = "256Mi"
    }
    requests = {
      memory = "128Mi"
    }
  }
}

variable "external_secrets_service_account" {
  description = "External Secrets Operator Kubernetes service account name"
  type        = string
  default     = "external-secrets"
}

variable "argocd_bootstrap_enabled" {
  description = "Enable ArgoCD bootstrap Application (App-of-Apps pattern)"
  type        = bool
  default     = true
}

variable "argocd_repo_revision" {
  description = "ArgoCD repository target revision"
  type        = string
  default     = "HEAD"
}

variable "external_secrets_gcp_service_account" {
  description = "GCP service account email for External Secrets Operator (for Workload Identity)"
  type        = string
  default     = ""
}
