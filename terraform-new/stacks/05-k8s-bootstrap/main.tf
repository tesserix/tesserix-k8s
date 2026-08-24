# Kubernetes Bootstrap Stack - Kong, Cert-Manager, ArgoCD, External Secrets
# State: stacks/prod/k8s-bootstrap/default.tfstate
# Dependencies: 04-gke

# Reference GKE stack outputs
data "terraform_remote_state" "gke" {
  backend = "gcs"

  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/gke"
  }
}

# =============================================================================
# Locals - Define computed values to avoid sensitive value issues in conditionals
# =============================================================================

locals {
  # Use boolean flags instead of deriving from sensitive values
  # This avoids Terraform 1.6.x crash with sensitive values in conditionals
  has_cloudflare_token = var.enable_cloudflare_dns
}

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "kong" {
  count = var.install_kong ? 1 : 0

  metadata {
    name = var.kong_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

resource "kubernetes_namespace" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  metadata {
    name = var.cert_manager_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

resource "kubernetes_namespace" "argocd" {
  count = var.install_argocd ? 1 : 0

  metadata {
    name = var.argocd_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

resource "kubernetes_namespace" "external_secrets" {
  count = var.install_external_secrets ? 1 : 0

  metadata {
    name = var.external_secrets_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

# =============================================================================
# Kong Ingress Controller
# =============================================================================

resource "helm_release" "kong" {
  count = var.install_kong ? 1 : 0

  name             = "kong"
  repository       = "https://charts.konghq.com"
  chart            = "kong"
  version          = var.kong_chart_version
  namespace        = var.kong_namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      ingressController = {
        enabled      = true
        installCRDs  = false
        ingressClass = var.kong_ingress_class
        env = {
          publish_service = "${var.kong_namespace}/kong-kong-proxy"
        }
      }
      proxy = {
        enabled     = true
        type        = var.kong_proxy_service_type
        annotations = var.kong_proxy_annotations
        http = {
          enabled       = true
          servicePort   = 80
          containerPort = 8000
        }
        https = {
          enabled       = true
          servicePort   = 443
          containerPort = 8443
        }
        tls = {
          enabled = true
        }
      }
      admin = {
        enabled = var.kong_admin_enabled
        type    = "ClusterIP"
      }
      resources    = var.kong_resources
      replicaCount = var.kong_replicas
    })
  ]

  depends_on = [kubernetes_namespace.kong]
}

# =============================================================================
# Cert-Manager
# =============================================================================

resource "helm_release" "cert_manager" {
  count = var.install_cert_manager ? 1 : 0

  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version
  namespace        = var.cert_manager_namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      installCRDs  = true
      replicaCount = var.cert_manager_replicas
      resources    = var.cert_manager_resources
      webhook = {
        replicaCount = 1
      }
      cainjector = {
        replicaCount = 1
      }
    })
  ]

  depends_on = [kubernetes_namespace.cert_manager]
}

# Cloudflare API Token Secret for DNS01 Challenge
resource "kubernetes_secret" "cloudflare_api_token" {
  count = var.install_cert_manager && local.has_cloudflare_token ? 1 : 0

  metadata {
    name      = "cloudflare-api-token"
    namespace = var.cert_manager_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "api-token" = var.cloudflare_api_token
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.cert_manager]
}

# Let's Encrypt ClusterIssuer - Staging
resource "kubernetes_manifest" "letsencrypt_staging" {
  count = var.install_cert_manager && local.has_cloudflare_token ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-staging"
        }
        solvers = [
          {
            dns01 = {
              cloudflare = {
                apiTokenSecretRef = {
                  name = "cloudflare-api-token"
                  key  = "api-token"
                }
              }
            }
            selector = {
              dnsZones = [var.cloudflare_domain]
            }
          }
        ]
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.cloudflare_api_token
  ]
}

# Let's Encrypt ClusterIssuer - Production
resource "kubernetes_manifest" "letsencrypt_prod" {
  count = var.install_cert_manager && local.has_cloudflare_token ? 1 : 0

  manifest = {
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        email  = var.letsencrypt_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-prod"
        }
        solvers = [
          {
            dns01 = {
              cloudflare = {
                apiTokenSecretRef = {
                  name = "cloudflare-api-token"
                  key  = "api-token"
                }
              }
            }
            selector = {
              dnsZones = [var.cloudflare_domain]
            }
          }
        ]
      }
    }
  }

  field_manager {
    force_conflicts = true
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_secret.cloudflare_api_token
  ]
}

# =============================================================================
# External Secrets Operator
# =============================================================================

resource "helm_release" "external_secrets" {
  count = var.install_external_secrets ? 1 : 0

  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = var.external_secrets_namespace
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      installCRDs  = true
      replicaCount = 1
      resources    = var.external_secrets_resources
      serviceAccount = {
        create = true
        name   = var.external_secrets_service_account
        annotations = var.external_secrets_gcp_service_account != "" ? {
          "iam.gke.io/gcp-service-account" = var.external_secrets_gcp_service_account
        } : {}
      }
      webhook = {
        replicaCount = 1
      }
      certController = {
        replicaCount = 1
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.external_secrets
  ]
}

# ClusterSecretStore for GCP Secret Manager
# Using null_resource with kubectl to avoid CRD validation during plan
# (kubernetes_manifest requires CRD to exist during plan phase)
resource "null_resource" "gcp_secret_store" {
  count = var.install_external_secrets ? 1 : 0

  triggers = {
    project_id = var.project_id
  }

  provisioner "local-exec" {
    environment = {
      KUBE_SERVER         = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
      KUBE_CA_CERTIFICATE = data.terraform_remote_state.gke.outputs.cluster_ca_certificate
    }

    command = <<-EOT
      # Wait for External Secrets CRDs to be available
      echo "Waiting for External Secrets CRDs..."
      for i in $(seq 1 30); do
        if bash "${path.module}/../../scripts/kubectl-gke.sh" \
          get crd clustersecretstores.external-secrets.io >/dev/null 2>&1; then
          echo "CRD is available"
          break
        fi
        echo "Waiting for CRD... attempt $i/30"
        sleep 10
      done

      # Apply ClusterSecretStore
      cat <<EOF | bash "${path.module}/../../scripts/kubectl-gke.sh" apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: gcp-secret-store
spec:
  provider:
    gcpsm:
      projectID: ${var.project_id}
EOF
    EOT
  }

  depends_on = [
    helm_release.external_secrets
  ]
}

# =============================================================================
# ArgoCD
# =============================================================================

resource "kubernetes_secret" "argocd_oidc_secret" {
  count = var.install_argocd && var.argocd_enable_sso ? 1 : 0

  metadata {
    name      = "argocd-oidc-secret"
    namespace = var.argocd_namespace
    labels = {
      "app.kubernetes.io/part-of"    = "argocd"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    "oidc.google.clientSecret" = var.google_oauth_client_secret
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.argocd]
}

# DEPRECATED (2026-07-21): ArgoCD migrated off the argo-helm chart to the
# argoproj-labs argocd-operator v0.18.0 (Argo CD v3.3.10). This resource is
# disabled whenever var.argocd_use_operator is true (the default) so a future
# apply never reinstalls the Helm control plane. The operator is bootstrapped
# manually (kustomize) and its ArgoCD CR is GitOps-managed via
# argocd/prod/infrastructure/argocd.yaml -> charts/argocd-operator/. Retained
# for history / rollback only. See
# docs/superpowers/plans/2026-07-21-argocd-operator-migration.md
resource "helm_release" "argocd" {
  count = var.install_argocd && !var.argocd_use_operator ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = var.argocd_namespace
  create_namespace = false
  wait             = true
  timeout          = 600

  values = [
    yamlencode({
      global = {
        image = {
          tag = var.argocd_image_tag
        }
      }
      configs = {
        params = {
          "server.insecure" = var.argocd_server_insecure
        }
        cm = merge({
          "timeout.reconciliation"       = "180s"
          "application.instanceLabelKey" = "argocd.argoproj.io/instance"
          "admin.enabled"                = var.argocd_admin_enabled ? "true" : "false"
          },
          var.argocd_enable_sso ? {
            "url" = var.argocd_url
            "oidc.config" = yamlencode({
              name            = "Google"
              issuer          = "https://accounts.google.com"
              clientID        = var.google_oauth_client_id
              clientSecret    = "$argocd-oidc-secret:oidc.google.clientSecret"
              requestedScopes = ["openid", "profile", "email"]
            })
          } : {}
        )
        rbac = {
          "policy.default" = var.argocd_enable_sso ? "" : "role:readonly"
          "policy.csv" = var.argocd_enable_sso ? join("\n", concat(
            [for email in var.argocd_admin_users : "g, ${email}, role:admin"],
            [
              "p, role:admin, applications, *, */*, allow",
              "p, role:admin, clusters, *, *, allow",
              "p, role:admin, repositories, *, *, allow",
              "p, role:admin, projects, *, *, allow",
            ]
          )) : ""
          "scopes" = "[email]"
        }
      }
      server = {
        replicas = var.argocd_server_replicas
        service = {
          type = var.argocd_service_type
        }
        resources = var.argocd_server_resources
        ingress = {
          enabled          = var.argocd_ingress_enabled
          ingressClassName = var.argocd_ingress_class
          annotations = merge(
            {
              "konghq.com/strip-path" = "false"
              "konghq.com/protocols"  = "https"
              "konghq.com/protocol"   = "https"
            },
            var.argocd_ingress_tls && var.install_cert_manager ? {
              "cert-manager.io/cluster-issuer" = var.letsencrypt_issuer
            } : {},
            var.argocd_ingress_annotations
          )
          hosts    = [var.argocd_hostname]
          paths    = ["/"]
          pathType = "Prefix"
          tls = var.argocd_ingress_tls ? [
            {
              hosts      = [var.argocd_hostname]
              secretName = "argocd-server-tls"
            }
          ] : []
        }
      }
      controller = {
        replicas  = var.argocd_controller_replicas
        resources = var.argocd_controller_resources
      }
      repoServer = {
        replicas  = var.argocd_repo_server_replicas
        resources = var.argocd_repo_server_resources
      }
      applicationSet = {
        replicas = 1
      }
      notifications = {
        enabled = var.argocd_notifications_enabled
      }
    })
  ]

  depends_on = [
    kubernetes_namespace.argocd,
    kubernetes_secret.argocd_oidc_secret,
    helm_release.kong,
    helm_release.cert_manager,
    kubernetes_manifest.letsencrypt_prod
  ]
}

# ArgoCD Repository Secret (HTTPS)
resource "kubernetes_secret" "argocd_repo_https" {
  count = var.install_argocd && var.argocd_repo_url != "" && var.argocd_repo_auth_method == "https" ? 1 : 0

  metadata {
    name      = "repo-tesserix-k8s"
    namespace = var.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
      "app.kubernetes.io/managed-by"   = "terraform"
    }
  }

  data = {
    type     = "git"
    url      = var.argocd_repo_url
    username = var.argocd_repo_username
    password = var.argocd_repo_password
  }

  depends_on = [
    kubernetes_namespace.argocd,
    helm_release.argocd
  ]
}

# =============================================================================
# ArgoCD Bootstrap Application (App-of-Apps)
# =============================================================================

resource "null_resource" "argocd_bootstrap_app" {
  count = var.install_argocd && var.argocd_bootstrap_enabled ? 1 : 0

  triggers = {
    cluster_ca_certificate = data.terraform_remote_state.gke.outputs.cluster_ca_certificate
    cluster_server         = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
    environment            = var.environment
    namespace              = var.argocd_namespace
    repo_url               = var.argocd_repo_url
    repo_revision          = var.argocd_repo_revision
  }

  provisioner "local-exec" {
    environment = {
      KUBE_SERVER         = self.triggers.cluster_server
      KUBE_CA_CERTIFICATE = self.triggers.cluster_ca_certificate
    }

    command = <<-EOT
      # Wait for ArgoCD CRDs to be available
      echo "Waiting for ArgoCD Application CRD to be ready..."
      for i in $(seq 1 30); do
        if bash "${path.module}/../../scripts/kubectl-gke.sh" \
          get crd applications.argoproj.io >/dev/null 2>&1; then
          echo "ArgoCD CRD is ready"
          break
        fi
        echo "Waiting for CRD... attempt $i/30"
        sleep 10
      done

      # Apply the ArgoCD Bootstrap Application
      bash "${path.module}/../../scripts/kubectl-gke.sh" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${var.environment}-bootstrap
  namespace: ${var.argocd_namespace}
  labels:
    app.kubernetes.io/part-of: tesseract-hub
    app.kubernetes.io/managed-by: terraform
    environment: ${var.environment}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${var.argocd_repo_url}
    targetRevision: ${var.argocd_repo_revision}
    path: argocd/${var.environment}
  destination:
    server: https://kubernetes.default.svc
    namespace: ${var.argocd_namespace}
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
EOF
    EOT
  }

  provisioner "local-exec" {
    when = destroy
    environment = {
      KUBE_SERVER         = self.triggers.cluster_server
      KUBE_CA_CERTIFICATE = self.triggers.cluster_ca_certificate
    }
    command = "bash ../../scripts/kubectl-gke.sh delete application ${self.triggers.environment}-bootstrap -n ${self.triggers.namespace} --ignore-not-found=true || true"
  }

  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_repo_https
  ]
}
