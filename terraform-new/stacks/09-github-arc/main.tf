# GitHub ARC Stack - GitHub Actions Runner Controller
# State: stacks/prod/github-arc/default.tfstate
# Dependencies: 05-k8s-bootstrap

data "terraform_remote_state" "gke" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/gke"
  }
}

data "terraform_remote_state" "k8s_bootstrap" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/prod/k8s-bootstrap"
  }
}

# =============================================================================
# Namespaces
# =============================================================================

resource "kubernetes_namespace" "arc_systems" {
  count = var.enable_github_arc ? 1 : 0

  metadata {
    name = var.arc_systems_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

resource "kubernetes_namespace" "arc_runners" {
  count = var.enable_github_arc ? 1 : 0

  metadata {
    name = var.arc_runners_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "environment"                  = var.environment
    }
  }
}

# =============================================================================
# GitHub App Secret
# =============================================================================

resource "kubernetes_secret" "github_app" {
  count = var.enable_github_arc && var.github_app_id != "" ? 1 : 0

  metadata {
    name      = "github-app-secret"
    namespace = var.arc_runners_namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  data = {
    github_app_id              = var.github_app_id
    github_app_installation_id = var.github_app_installation_id
    github_app_private_key     = var.github_app_private_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.arc_runners]
}

# =============================================================================
# ARC Controller
# =============================================================================

resource "helm_release" "arc_controller" {
  count = var.enable_github_arc ? 1 : 0

  name             = "arc"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = var.arc_controller_version
  namespace        = var.arc_systems_namespace
  create_namespace = false
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      replicaCount = var.arc_controller_replicas
      resources    = var.arc_controller_resources
    })
  ]

  depends_on = [
    kubernetes_namespace.arc_systems,
    kubernetes_secret.github_app
  ]
}

# =============================================================================
# Runner Scale Sets
# =============================================================================

resource "helm_release" "runner_scale_sets" {
  for_each = var.enable_github_arc ? { for rs in var.runner_scale_sets : rs.name => rs } : {}

  name             = each.value.name
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.arc_runner_version
  namespace        = var.arc_runners_namespace
  create_namespace = false
  wait             = true
  timeout          = 300

  # Use raw YAML to preserve restartPolicy on init containers (sidecar pattern).
  # Terraform's yamlencode strips restartPolicy from init containers.
  values = [
    templatefile("${path.module}/runner-values.yaml.tftpl", {
      github_config_url    = each.value.github_config_url
      github_config_secret = "github-app-secret"
      min_runners          = each.value.min_runners
      max_runners          = each.value.max_runners
      runner_group         = each.value.runner_group
      runner_image         = each.value.runner_image
      memory_limit         = each.value.resources.limits.memory
      memory_request       = each.value.resources.requests.memory
      node_selector        = each.value.node_selector
      tolerations          = each.value.tolerations
    })
  ]

  depends_on = [
    kubernetes_namespace.arc_runners,
    helm_release.arc_controller
  ]
}
