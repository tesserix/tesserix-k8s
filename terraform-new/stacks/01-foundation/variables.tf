# Foundation Stack Variables

variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The default GCP region"
  type        = string
  default     = "us-central1"
}

variable "environment" {
  description = "Environment name (prod, staging, dev)"
  type        = string
  default     = "prod"
}

variable "apis" {
  description = "List of GCP APIs to enable"
  type        = list(string)
  default = [
    # Core Infrastructure
    "compute.googleapis.com",
    "container.googleapis.com",
    "servicenetworking.googleapis.com",
    "networkconnectivity.googleapis.com",

    # Storage & Secrets
    "storage.googleapis.com",
    "storage-api.googleapis.com",
    "secretmanager.googleapis.com",
    "cloudkms.googleapis.com",

    # IAM & Security
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "binaryauthorization.googleapis.com",
    "sts.googleapis.com", # Security Token Service (Workload Identity)

    # Observability
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "cloudtrace.googleapis.com",

    # Networking
    "dns.googleapis.com",
    "certificatemanager.googleapis.com",

    # Container Services
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "containerregistry.googleapis.com",
    "containeranalysis.googleapis.com",
    "containerfilesystem.googleapis.com",

    # GKE Backup & Management
    "gkebackup.googleapis.com",

    # Service Management
    "servicemanagement.googleapis.com",
    "serviceusage.googleapis.com",

    # Messaging
    "pubsub.googleapis.com",

    # OS & Access
    "oslogin.googleapis.com",

    # Firebase & FCM (Push Notifications)
    "firebase.googleapis.com",
    "fcm.googleapis.com",
    "firebasehosting.googleapis.com",
    "firebaseinstallations.googleapis.com",
    "identitytoolkit.googleapis.com",

    # Google Maps Platform APIs
    "addressvalidation.googleapis.com",
    "directions-backend.googleapis.com",
    "geocoding-backend.googleapis.com",
    "maps-backend.googleapis.com",
    "places-backend.googleapis.com",
    "places.googleapis.com",
    "roads.googleapis.com",
    "routeoptimization.googleapis.com",
    "timezone-backend.googleapis.com",

    # Translation & Communication
    "translate.googleapis.com",
    "gmail.googleapis.com",

    # Document Intelligence
    "documentai.googleapis.com",
  ]
}

variable "document_ai_location" {
  description = "Regional Document AI location for the generic OCR processor"
  type        = string
  default     = "asia-south1"
}

variable "document_ai_processor_display_name" {
  description = "Display name for the shared provider-neutral OCR processor"
  type        = string
  default     = "document-intelligence-generic-ocr"
}

variable "disable_on_destroy" {
  description = "Whether to disable the API when the resource is destroyed"
  type        = bool
  default     = false
}

variable "common_labels" {
  description = "Common labels to apply to all resources"
  type        = map(string)
  default = {
    managed_by  = "terraform"
    project     = "tesseracthub"
    environment = "prod"
  }
}
