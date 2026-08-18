# Vertex Stack Variables

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
# Network reference
# ============================================================================

variable "vpc_name" {
  description = "Name of the VPC the PSC endpoint and DNS zone attach to"
  type        = string
  default     = "tesseract-prod-vpc"
}

# ============================================================================
# Vertex AI Private Service Connect
# ============================================================================

variable "vertex_psc_address_name" {
  description = "Name of the global internal address for the Google APIs PSC endpoint"
  type        = string
  default     = "vertex-psc-ip"
}

variable "vertex_psc_ip" {
  description = "Internal IP for the PSC endpoint (must not overlap subnet/pod/service/peering ranges)"
  type        = string
  default     = "10.255.0.2"
}

variable "vertex_psc_rule_name" {
  description = "Name of the PSC forwarding rule (Google APIs bundle). Lowercase letters and digits only, max 20 chars."
  type        = string
  default     = "vertexapis"
}

variable "vertex_dns_zone_name" {
  description = "Name of the private DNS zone that pins aiplatform.googleapis.com to the PSC endpoint"
  type        = string
  default     = "vertex-aiplatform"
}

# ============================================================================
# IAM — who may call Vertex AI
# ============================================================================

variable "devai_workload_sa_email" {
  description = "Existing DevAI workload GSA (Workload Identity) granted roles/aiplatform.user for direct ADC calls"
  type        = string
  default     = "app-secrets-devai-prod@tesseracthub-480811.iam.gserviceaccount.com"
}

variable "agentgateway_ksa" {
  description = "Kubernetes SA (namespace/name) of the agentgateway pods, bound to the gateway GSA via Workload Identity"
  type        = string
  default     = "agentgateway-system/agentgateway"
}

variable "kora_agentgateway_ksa" {
  description = "Kubernetes SA (namespace/name) of the Kora agentgateway data plane, bound to the gateway GSA via Workload Identity"
  type        = string
  default     = "agentgateway-system/kora-ai"
}

variable "devai_agentgateway_ksa" {
  description = "Kubernetes SA (namespace/name) of the native DevAI LLM gateway data plane"
  type        = string
  default     = "agentgateway-system/ai-gateway"
}

variable "devai_runner_ksa" {
  description = "Kubernetes SA (namespace/name) of the DevAI ADK runner Jobs, bound to the DevAI workload GSA so dispatched agents reach Vertex via ADC"
  type        = string
  default     = "devai/devai-runner"
}
