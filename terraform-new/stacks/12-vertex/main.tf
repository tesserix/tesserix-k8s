# Vertex Stack - Private Service Connect endpoint, DNS pinning, and IAM
# for Vertex AI access from the GKE cluster (DevAI + agentgateway).
# State: stacks/{environment}/vertex/default.tfstate
# Dependencies: 02-network (VPC), 04-gke (Workload Identity pool)
#
# Design:
#   - One global PSC endpoint (all-apis bundle) at a fixed internal IP.
#   - DNS is scoped to aiplatform.googleapis.com ONLY, so Vertex traffic pins
#     to the PSC endpoint while GCS/GCR/etc. keep their default resolution
#     (low blast radius; widen to a googleapis.com zone deliberately, later).
#   - LLM egress goes through the solo.io agentgateway (agentgateway-system),
#     which authenticates to Vertex via Workload Identity — no API keys.
#   - The DevAI workload SA keeps a direct grant for the transition period.

# The VPC is created by 02-network; referenced by name to keep this stack
# importable without remote-state coupling.
data "google_compute_network" "vpc" {
  name    = var.vpc_name
  project = var.project_id
}

# ============================================================================
# Private Service Connect endpoint for Google APIs
# ============================================================================

resource "google_compute_global_address" "vertex_psc_ip" {
  name         = var.vertex_psc_address_name
  project      = var.project_id
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = var.vertex_psc_ip
  network      = data.google_compute_network.vpc.id
}

resource "google_compute_global_forwarding_rule" "vertex_psc" {
  name                  = var.vertex_psc_rule_name
  project               = var.project_id
  target                = "all-apis"
  network               = data.google_compute_network.vpc.id
  ip_address            = google_compute_global_address.vertex_psc_ip.id
  load_balancing_scheme = ""
}

# ============================================================================
# Private DNS — pin aiplatform.googleapis.com to the PSC endpoint
# ============================================================================

resource "google_dns_managed_zone" "vertex_aiplatform" {
  name        = var.vertex_dns_zone_name
  project     = var.project_id
  dns_name    = "aiplatform.googleapis.com."
  description = "Pin Vertex AI traffic to the ${var.vertex_psc_rule_name} PSC endpoint (${var.vertex_psc_ip})"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = data.google_compute_network.vpc.id
    }
  }
}

resource "google_dns_record_set" "vertex_apex" {
  name         = "aiplatform.googleapis.com."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.vertex_aiplatform.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.vertex_psc_ip]
}

resource "google_dns_record_set" "vertex_wildcard" {
  name         = "*.aiplatform.googleapis.com."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.vertex_aiplatform.name
  type         = "A"
  ttl          = 300
  rrdatas      = [var.vertex_psc_ip]
}

# ============================================================================
# IAM — Vertex callers
# ============================================================================

# Dedicated GSA for the agentgateway's model egress (the strategic LLM path).
resource "google_service_account" "agentgateway_llm" {
  account_id   = "agentgateway-llm"
  project      = var.project_id
  display_name = "Agentgateway LLM egress (Vertex AI)"
}

resource "google_project_iam_member" "agentgateway_llm_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.agentgateway_llm.email}"
}

# Workload Identity: agentgateway pods (KSA) impersonate the GSA.
# The matching KSA annotation lives in charts/thirdparty/agentgateway/values.yaml.
resource "google_service_account_iam_member" "agentgateway_wi" {
  service_account_id = google_service_account.agentgateway_llm.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.agentgateway_ksa}]"
}

resource "google_service_account_iam_member" "kora_agentgateway_wi" {
  service_account_id = google_service_account.agentgateway_llm.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.kora_agentgateway_ksa}]"
}

# Native DevAI LLM data plane. This is distinct from the controller/MCP KSA:
# the Gateway API controller creates a ServiceAccount named after the Gateway.
resource "google_service_account_iam_member" "devai_agentgateway_wi" {
  service_account_id = google_service_account.agentgateway_llm.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.devai_agentgateway_ksa}]"
}

# Transition-period direct grant for the DevAI workload SA (created outside
# Terraform by 07-app-secrets-era manual work; referenced by email only).
resource "google_project_iam_member" "devai_workload_aiplatform" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${var.devai_workload_sa_email}"
}

# ADK runner Jobs (DevAI agents dispatched as K8s Jobs, KSA devai/devai-runner)
# impersonate the DevAI workload GSA so in-Job agents mint ADC for Vertex.
# The api/sre/dashboard KSA bindings on this GSA pre-date Terraform and stay
# unmanaged; this stack owns only the runner binding it introduced.
resource "google_service_account_iam_member" "devai_runner_wi" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.devai_workload_sa_email}"
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.devai_runner_ksa}]"
}
