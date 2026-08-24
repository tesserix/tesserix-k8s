# GitHub ARC Stack - Provider Configuration

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "kubernetes" {
  host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
  cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "/usr/bin/env"
    args        = ["bash", "${path.module}/../../scripts/gke-auth.sh", "--exec-credential"]
  }
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.terraform_remote_state.gke.outputs.cluster_endpoint}"
    cluster_ca_certificate = base64decode(data.terraform_remote_state.gke.outputs.cluster_ca_certificate)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "/usr/bin/env"
      args        = ["bash", "${path.module}/../../scripts/gke-auth.sh", "--exec-credential"]
    }
  }
}
