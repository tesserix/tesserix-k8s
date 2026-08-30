# =============================================================================
# Production Environment Configuration
# =============================================================================
# Project: TesseractHub (Project ID: tesseracthub-480811, Number: 480811)
# Admin: unidevidp@gmail.com
#
# IMPORTANT: All environments (devtest, pilot, prod) now use the same GCP project
#   - Project: tesseracthub-480811
#   - Naming prefix: tesseract
#   - Environment tag: prod
#
# Multi-Region Support:
#   - Primary Region: India (asia-south1) - for GKE and compute
#   - State Bucket: Australia (australia-southeast1) - for compliance
# =============================================================================

# =============================================================================
# General Configuration
# =============================================================================

project_id  = "tesseracthub-480811"
environment = "prod"

# Primary deployment region: INDIA
region = "asia-south1"
zones  = ["asia-south1-a", "asia-south1-b", "asia-south1-c"]

# Region code for multi-region naming
region_code = "in"

# State bucket ALWAYS in Australia for data sovereignty
state_bucket          = "tesseract-terraform-states"
state_bucket_location = "australia-southeast1"

common_labels = {
  environment = "prod"
  managed-by  = "terraform"
  project     = "tesseracthub"
  region      = "in"
}

# =============================================================================
# VPC Configuration
# =============================================================================
# Naming: tesseract-prod-{region}-vpc
# =============================================================================

vpc_name                = "tesseract-prod-in-vpc"
routing_mode            = "GLOBAL"
enable_private_services = true
create_nat_gateway      = true
nat_network_tier        = "STANDARD" # Cost optimization
enable_nat_logging      = false      # Enable for production debugging

# =============================================================================
# Subnet Configuration
# =============================================================================
# Naming: tesseract-prod-{region}-subnet
# =============================================================================

subnet_name              = "tesseract-prod-in-subnet"
subnet_cidr              = "10.10.0.0/20"
private_ip_google_access = true
enable_flow_logs         = false # Enable for compliance if needed

secondary_ip_ranges = [
  {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  },
  {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
]

# =============================================================================
# Firewall Configuration
# =============================================================================

create_default_firewall_rules = true
internal_ranges               = ["10.0.0.0/8"]
allow_iap_ssh                 = true

firewall_rules = []

# =============================================================================
# GKE Configuration
# =============================================================================
# Naming: tesseract-prod-{region}-gke
# =============================================================================

cluster_name        = "tesseract-prod-in-gke"
regional            = true # Regional cluster for high availability (3 zones)
deletion_protection = true # Enabled - protects cluster from accidental deletion

# Logging and Monitoring (DISABLED for cost optimization - enable when needed)
enable_logging            = false
enable_monitoring         = false
enable_managed_prometheus = false

# IP Range Names
pods_range_name     = "pods"
services_range_name = "services"

# Private Cluster Configuration
enable_private_cluster  = true
enable_private_endpoint = false # Allow external kubectl access
master_ipv4_cidr_block  = "172.16.0.0/28"

# Network Policy
enable_network_policy       = true
http_load_balancing         = true
horizontal_pod_autoscaling  = true
vertical_pod_autoscaling    = true
gce_pd_csi_driver           = true
gcs_fuse_csi_driver         = false
enable_binary_authorization = false

# =============================================================================
# Security & Encryption (CMEK)
# =============================================================================
# Uses KMS keys from the storage stack for encryption at rest
# Format: projects/{project}/locations/{location}/keyRings/{keyring}/cryptoKeys/{key}

# GKE etcd encryption at rest (encrypts Kubernetes secrets in etcd)
database_encryption_key_name = "projects/tesseracthub-480811/locations/asia-south1/keyRings/tesseract-prod-in-keyring/cryptoKeys/infra-database-encryption-key"

# Node boot disk encryption with CMEK
# NOTE: Disabled - requires node pool recreation which is disruptive
# Enable only for new clusters or during maintenance windows
# boot_disk_kms_key = "projects/tesseracthub-480811/locations/asia-south1/keyRings/tesseract-prod-in-keyring/cryptoKeys/infra-database-encryption-key"

# Maintenance Window (3 AM IST = 9:30 PM UTC previous day)
maintenance_start_time = "21:30"

# Release Channel
release_channel           = "RAPID" # Use RAPID channel for latest edge GKE versions
use_latest_version        = true
kubernetes_version_prefix = "1.36." # Latest 1.36.x patch — pin keeps upgrades deterministic

# Master Authorized Networks
# TODO: Restrict to specific IPs after ARC runners are deployed
master_authorized_networks = [
  {
    cidr_block   = "0.0.0.0/0"
    display_name = "Allow All (Temporary for CI)"
  }
]

cluster_labels = {
  environment = "prod"
  region      = "in"
}

# =============================================================================
# Node Pool Configuration - On-Demand under 3-year E2 CUD
# =============================================================================
# Commitment e2-cud-asia-south1 covers 30 vCPU / 120 GB (GENERAL_PURPOSE_E2,
# 36-month, ends 2029-08-30). CUDs only apply to STANDARD provisioning, so the
# single worker pool runs on-demand: 3-5 x e2-standard-8 = 24-40 vCPU /
# 96-160 GB, with 30/120 at the committed rate and any remainder on-demand.
# Memory requests run close to allocatable — the autoscaler is expected to
# sit at 4+ nodes; do not lower total_max_count without right-sizing first.
#
# spot flag is immutable on a node pool: flipping it REPLACES the pool.
# =============================================================================

# Phase 1 moved optimized-v2 to on-demand while small-support kept serving;
# phase 2 (this change) removes small-support, leaving a single on-demand pool
# sized to the CUD. min 3 nodes = 24 vCPU / 96 GB; the autoscaler grows to 5
# for former small-support load, and the slice above 30/120 bills on-demand.
use_spot_instances = null

node_pools = [
  {
    name                        = "optimized-v2"
    machine_type                = "e2-standard-8" # 8 vCPU, 32GB RAM
    disk_size_gb                = 80
    disk_type                   = "pd-standard"
    spot                        = false
    initial_node_count          = 1
    min_count                   = 0 # Per-zone min (using total counts instead)
    max_count                   = 0 # Per-zone max (using total counts instead)
    total_min_count             = 3 # 24 vCPU / 96 GB floor; autoscaler adds nodes up to max
    total_max_count             = 6 # 2 per zone — zonal PVs need headroom in their own zone
    location_policy             = "BALANCED"
    max_pods_per_node           = 110
    auto_repair                 = true
    auto_upgrade                = true
    max_surge                   = 1
    max_unavailable             = 0
    enable_secure_boot          = true
    enable_integrity_monitoring = true
    labels = {
      workload     = "infrastructure"
      optimized    = "true"
      environment  = "prod"
      provisioning = "on-demand"
    }
    tags   = ["prod", "tesseract", "optimized", "on-demand"]
    taints = []
  }
]

node_labels = {
  environment = "prod"
  region      = "in"
}

# =============================================================================
# Storage Configuration
# =============================================================================
# KMS Keyring in same region as primary workloads (India)
# Buckets can be multi-region based on compliance requirements
# =============================================================================

# KMS Configuration
create_kms_keyring = true
kms_keyring_name   = "tesseract-prod-in-keyring"
kms_location       = "asia-south1" # Same region as GKE
enable_cmek        = true

kms_keys = [
  # Infrastructure Keys
  {
    name             = "infra-secrets-encryption-key"
    rotation_period  = "7776000s" # 90 days
    purpose          = "ENCRYPT_DECRYPT"
    protection_level = "SOFTWARE" # Use HSM for higher security
    labels = {
      tier    = "infrastructure"
      purpose = "secrets-encryption"
    }
    iam_bindings = []
  },
  {
    name             = "infra-database-encryption-key"
    rotation_period  = "7776000s"
    purpose          = "ENCRYPT_DECRYPT"
    protection_level = "SOFTWARE"
    labels = {
      tier    = "infrastructure"
      purpose = "database-encryption"
    }
    iam_bindings = []
  },
  # Customer Data Keys
  {
    name             = "customer-data-encryption-key"
    rotation_period  = "7776000s"
    purpose          = "ENCRYPT_DECRYPT"
    protection_level = "SOFTWARE"
    labels = {
      tier    = "customer"
      purpose = "pii-encryption"
    }
    iam_bindings = []
  },
  # OpenBao auto-unseal. Rotation is safe: gcpckms encrypts with the primary
  # version and decrypts with whichever version sealed the key ring.
  {
    name             = "openbao-unseal-key"
    rotation_period  = "7776000s"
    purpose          = "ENCRYPT_DECRYPT"
    protection_level = "SOFTWARE"
    # 30 days, not the module's 24h default. Destroying this key destroys every
    # sealed OpenBao node with it, and the field is immutable — a shorter window
    # could only be widened by replacing the key, which KMS forbids.
    destroy_scheduled_duration = "2592000s"
    labels = {
      tier    = "infrastructure"
      purpose = "openbao-unseal"
    }
    iam_bindings = [
      {
        role   = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
        member = "serviceAccount:openbao@tesseracthub-480811.iam.gserviceaccount.com"
      },
      # The seal calls cryptoKeys.get before it encrypts, and that is not in
      # the EncrypterDecrypter role — without this it fails closed at startup.
      {
        role   = "roles/cloudkms.viewer"
        member = "serviceAccount:openbao@tesseracthub-480811.iam.gserviceaccount.com"
      }
    ]
  },
  # Third-Party Integration Keys
  {
    name             = "thirdparty-secrets-encryption-key"
    rotation_period  = "7776000s"
    purpose          = "ENCRYPT_DECRYPT"
    protection_level = "SOFTWARE"
    labels = {
      tier    = "thirdparty"
      purpose = "api-secrets"
    }
    iam_bindings = []
  }
]

# =============================================================================
# Buckets - Regional for Compliance
# =============================================================================
# Naming pattern: {product}-{env}-{purpose}-{region}
# Example: tesseract-prod-assets-in, hms-prod-patientrecords-in
#
# Products: global, hms, fanzone, homechef, bookkeeping
# Regions: au (australia-southeast1), in (asia-south1)
# =============================================================================

default_bucket_location = "asia-south1"

buckets = [
  # ===========================================================================
  # GLOBAL - Core Platform Buckets
  # ===========================================================================
  # General Assets Bucket (India)
  {
    name                        = "tesseract-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "assets"
      product    = "global"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      }
    ]
    cors = [
      {
        origin          = ["https://*.tesseracthub.app", "https://*.tesseracthub.com"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # General Assets Bucket (Australia)
  {
    name                        = "tesseract-prod-assets-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "assets"
      product    = "global"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      }
    ]
    cors = [
      {
        origin          = ["https://*.tesseracthub.app", "https://*.tesseracthub.com"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # Backups Bucket (India - Nearline for cost optimization)
  {
    name                        = "tesseract-prod-backups-in"
    location                    = "asia-south1"
    storage_class               = "NEARLINE"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "backups"
      product    = "global"
      region     = "in"
      compliance = "dpdpa"
    }
    # Tiered cost-down: STANDARD (0-7d) -> NEARLINE (7-15d) -> COLDLINE (15-30d) -> ARCHIVE (30-90d) -> Delete (>90d)
    # Plus noncurrent-version cleanup (versioning is enabled).
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 7
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 15
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 30
          matches_storage_class = ["COLDLINE"]
        }
      },
      {
        action    = { type = "Delete" }
        condition = { age = 90 }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state         = "ARCHIVED"
          num_newer_versions = 3
        }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state                 = "ARCHIVED"
          days_since_noncurrent_time = 30
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },
  # Backups Bucket (Australia)
  {
    name                        = "tesseract-prod-backups-au"
    location                    = "australia-southeast1"
    storage_class               = "NEARLINE"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "backups"
      product    = "global"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 7
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 15
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 30
          matches_storage_class = ["COLDLINE"]
        }
      },
      {
        action    = { type = "Delete" }
        condition = { age = 90 }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state         = "ARCHIVED"
          num_newer_versions = 3
        }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state                 = "ARCHIVED"
          days_since_noncurrent_time = 30
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },
  # Database Backups Bucket (Australia) — PostgreSQL CronJob dumps
  # Backups run every 12h for 6 DBs. Keep 3 days (6 backups per DB), then delete.
  {
    name                        = "tesseract-database-backups"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose = "database-backups"
      product = "global"
      region  = "au"
    }
    lifecycle_rules = [
      {
        action = {
          type = "Delete"
        }
        condition = {
          age = 3
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },

  # ===========================================================================
  # HMS - Hospital Management System Buckets
  # ===========================================================================
  # HMS Assets (India)
  {
    name                        = "hms-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "hms-assets"
      product    = "hms"
      system     = "hospital-management"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["https://hms.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # HMS Assets (Australia)
  {
    name                        = "hms-prod-assets-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "hms-assets"
      product    = "hms"
      system     = "hospital-management"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["https://hms.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # HMS Backups (India)
  {
    name                        = "hms-prod-backups-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "hms-backups"
      product    = "hms"
      system     = "hospital-management"
      region     = "in"
      compliance = "dpdpa"
    }
    # Tiered cost-down: STANDARD -> NEARLINE (7d) -> COLDLINE (15d) -> ARCHIVE (30d) -> Delete (90d)
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 7
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 15
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 30
          matches_storage_class = ["COLDLINE"]
        }
      },
      {
        action    = { type = "Delete" }
        condition = { age = 90 }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state         = "ARCHIVED"
          num_newer_versions = 3
        }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state                 = "ARCHIVED"
          days_since_noncurrent_time = 30
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },
  # HMS Backups (Australia)
  {
    name                        = "hms-prod-backups-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "hms-backups"
      product    = "hms"
      system     = "hospital-management"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 7
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 15
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 30
          matches_storage_class = ["COLDLINE"]
        }
      },
      {
        action    = { type = "Delete" }
        condition = { age = 90 }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state         = "ARCHIVED"
          num_newer_versions = 3
        }
      },
      {
        action = { type = "Delete" }
        condition = {
          with_state                 = "ARCHIVED"
          days_since_noncurrent_time = 30
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },
  # HMS Patient Records (India - Sensitive data, no deletion)
  {
    name                        = "hms-prod-patientrecords-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "hms-patientrecords"
      product    = "hms"
      system     = "hospital-management"
      region     = "in"
      sensitive  = "true"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },
  # HMS Patient Records (Australia - Sensitive data, no deletion)
  {
    name                        = "hms-prod-patientrecords-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "hms-patientrecords"
      product    = "hms"
      system     = "hospital-management"
      region     = "au"
      sensitive  = "true"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },

  # ===========================================================================
  # FANZONE - Sports/Entertainment Platform Buckets
  # ===========================================================================
  # Fanzone Assets (India)
  {
    name                        = "fanzone-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "fanzone-assets"
      product    = "fanzone"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      }
    ]
    cors = [
      {
        origin          = ["https://fanzone.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # Fanzone Assets (Australia)
  {
    name                        = "fanzone-prod-assets-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "fanzone-assets"
      product    = "fanzone"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      }
    ]
    cors = [
      {
        origin          = ["https://fanzone.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # SportsBook Media Bucket (India) — user-uploaded images + videos with 65-day auto-delete
  # Signed URLs (V4) for secure access — only authenticated users can view media
  # Path structure: posts/{user_id}/{post_id}/img_0_medium.webp
  # NOTE: Group covers go in fanzone-prod-assets-in (permanent, no TTL)
  #       This bucket is ONLY for ephemeral post/comment media (auto-deleted)
  #       Temp upload cleanup handled by application code (cleanup service)
  {
    name                        = "fanzone-prod-sportsbook-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "sportsbook-media"
      product    = "fanzone"
      region     = "in"
      compliance = "dpdpa"
      ttl-days   = "65"
    }
    lifecycle_rules = [
      # Auto-delete ALL objects after 65 days (5-day buffer over 60-day MongoDB post TTL)
      # Covers post images, video transcodes, thumbnails, posters — everything ephemeral
      {
        action = {
          type = "Delete"
        }
        condition = {
          age = 65
        }
      }
    ]
    cors = [
      # GET/HEAD only — uploads go through the SportsBook service, not direct browser uploads
      # Signed URLs served by API need CORS for browser <img>/<video> tag fetches
      {
        origin          = ["https://fanzonebattleground.com", "https://www.fanzonebattleground.com", "http://localhost:3000"]
        method          = ["GET", "HEAD"]
        response_header = ["Content-Type", "Content-Length", "Cache-Control", "Content-Disposition"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },

  # ===========================================================================
  # HOMECHEF - Food Delivery Platform Buckets (fe3dr.com)
  # ===========================================================================
  # Public assets bucket (India) — Menu images, food photos, chef profile pics
  # Reuses existing homechef-prod-assets-in bucket.
  # Path structure: chefs/{chef_id}/avatar.webp, menus/{chef_id}/{item_id}/img.webp
  {
    name                        = "homechef-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "inherited" # Allow public object reads via IAM
    versioning                  = false
    labels = {
      purpose    = "homechef-public-media"
      product    = "homechef"
      region     = "in"
      compliance = "dpdpa"
      visibility = "public"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 180 # Menu images stay STANDARD longer (frequently accessed)
        }
      }
    ]
    cors = [
      {
        origin          = ["https://fe3dr.com", "https://www.fe3dr.com", "https://vendors.fe3dr.com", "https://api.fe3dr.com"]
        method          = ["GET", "HEAD", "PUT", "POST"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control", "ETag"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = [
      {
        role   = "roles/storage.objectViewer"
        member = "allUsers"
      }
    ]
  },

  # Private docs bucket (India) — Compliance docs: PAN, FSSAI certs, Aadhaar, bank proof
  # Never publicly accessible. Versioned for audit trail. Archived after 1 year.
  # Path structure: vendors/{chef_id}/pan.pdf, vendors/{chef_id}/fssai_cert.pdf
  {
    name                        = "homechef-prod-docs-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced" # No public access ever
    versioning                  = true       # Audit trail for compliance docs
    labels = {
      purpose    = "homechef-vendor-docs"
      product    = "homechef"
      region     = "in"
      compliance = "dpdpa"
      sensitive  = "true"
      visibility = "private"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors         = [] # No direct browser access — API generates signed URLs for admin
    iam_bindings = [] # Access only via homechef-prod-backend-sa (configured in WI stack)
  },

  # ===========================================================================
  # BOOKKEEPING - Accounting Platform Buckets
  # ===========================================================================
  # Bookkeeping Assets (India)
  {
    name                        = "bookkeeping-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "bookkeeping-assets"
      product    = "bookkeeping"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["https://bookkeeping.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # Bookkeeping Assets (Australia)
  {
    name                        = "bookkeeping-prod-assets-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "bookkeeping-assets"
      product    = "bookkeeping"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["https://bookkeeping.tesseracthub.app", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },

  # ===========================================================================
  # MARKETPLACE - Multi-Tenant E-Commerce Platform Buckets
  # ===========================================================================
  # Private assets bucket (India) — product images, store branding, invoices, receipts
  # Structure: marketplace/{tenant_id}/products/, marketplace/{tenant_id}/store/, etc.
  # Isolation: IAM Conditions restrict marketplace SAs to marketplace/ prefix
  {
    name                        = "marketplace-prod-assets-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "marketplace-assets"
      product    = "marketplace"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 365
        }
      },
      {
        action = {
          type = "Delete"
        }
        condition = {
          num_newer_versions = 3
        }
      }
    ]
    cors = [
      {
        origin          = ["https://*.mark8ly.com", "https://mark8ly.com", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # Marketplace Public assets bucket (India) — product images served via CDN/signed URLs
  {
    name                        = "marketplace-prod-public-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "inherited" # Allow public object reads via IAM
    versioning                  = false
    labels = {
      purpose    = "marketplace-public"
      product    = "marketplace"
      region     = "in"
      compliance = "dpdpa"
      visibility = "public"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["*"]
        method          = ["GET", "HEAD"]
        response_header = ["Content-Type", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = [
      {
        role   = "roles/storage.objectViewer"
        member = "allUsers"
      }
    ]
  },
  # Marketplace Public assets bucket (Australia) — product images served via CDN
  {
    name                        = "marketplace-prod-public-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "inherited" # Allow public object reads via IAM
    versioning                  = false
    labels = {
      purpose    = "marketplace-public"
      product    = "marketplace"
      region     = "au"
      compliance = "privacy-act"
      public     = "true"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["*"]
        method          = ["GET", "HEAD"]
        response_header = ["Content-Type", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = [
      {
        role   = "roles/storage.objectViewer"
        member = "allUsers"
      }
    ]
  },
  # Marketplace Assets (Australia)
  {
    name                        = "marketplace-prod-assets-au"
    location                    = "australia-southeast1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "marketplace-assets"
      product    = "marketplace"
      region     = "au"
      compliance = "privacy-act"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 365
        }
      },
      {
        action = {
          type = "Delete"
        }
        condition = {
          num_newer_versions = 3
        }
      }
    ]
    cors = [
      {
        origin          = ["https://*.mark8ly.com", "https://mark8ly.com", "https://*.tesseracthub.app"]
        method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
        response_header = ["Content-Type", "Content-Length", "Content-Disposition", "Cache-Control"]
        max_age_seconds = 3600
      }
    ]
    iam_bindings = []
  },
  # Mark8ly Postgres dump backups (CNPG / pg_dump CronJob target)
  # Tiered cost-down: STANDARD -> NEARLINE (30d) -> COLDLINE (90d) -> ARCHIVE (365d) -> Delete (730d)
  {
    name                        = "tesseracthub-480811-mark8ly-pg-backups"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "pg-backups"
      product    = "marketplace"
      region     = "in"
      compliance = "dpdpa"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 7
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 15
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 30
          matches_storage_class = ["COLDLINE"]
        }
      },
      {
        action    = { type = "Delete" }
        condition = { age = 90 }
      }
    ]
    cors         = []
    iam_bindings = []
  },

  # ===========================================================================
  # DEVAI - Immutable Evaluation Datasets
  # ===========================================================================
  # User-owned dataset blobs are retained until a reference-aware cleanup job
  # can enforce the three-year policy without deleting shared content hashes.
  {
    name                        = "devai-prod-evaluations-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose   = "evaluation-datasets"
      product   = "devai"
      region    = "in"
      retention = "three-year-minimum"
      sensitive = "true"
      managed   = "terraform"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age                   = 90
          matches_storage_class = ["STANDARD"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age                   = 365
          matches_storage_class = ["NEARLINE"]
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "ARCHIVE"
        }
        condition = {
          age                   = 730
          matches_storage_class = ["COLDLINE"]
        }
      }
    ]
    cors = []
    iam_bindings = [
      {
        role   = "roles/storage.objectUser"
        member = "serviceAccount:app-secrets-devai-prod@tesseracthub-480811.iam.gserviceaccount.com"
      }
    ]
  },

  # ===========================================================================
  # BLOG - Engineering Blog Assets (public read, upload-only for blog SA)
  # Long-term retention 10yr+, lifecycle: Standard → Nearline → Coldline
  # ===========================================================================
  {
    name                        = "tesserix-blog-assets"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "inherited"
    versioning                  = false
    labels = {
      purpose   = "blog-images"
      product   = "blog"
      region    = "in"
      retention = "long-term"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 90
        }
      },
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "COLDLINE"
        }
        condition = {
          age = 365
        }
      }
    ]
    cors = [
      {
        origin          = ["https://blog.tesserix.app", "http://localhost:3003"]
        method          = ["GET", "HEAD"]
        response_header = ["Content-Type", "Content-Length"]
        max_age_seconds = 86400
      }
    ]
    iam_bindings = [
      {
        role   = "roles/storage.objectViewer"
        member = "allUsers"
      },
      {
        role   = "roles/storage.objectCreator"
        member = "serviceAccount:blog-assets-writer@tesseracthub-480811.iam.gserviceaccount.com"
      }
    ]
  },

  # ===========================================================================
  # SUPPORT-PLATFORM (Otto) — Conversation Exports for LoRA Training
  # ===========================================================================
  # Nightly CronJob in support-platform namespace dumps closed Otto
  # conversations grouped by tenant_id. Each per-tenant JSONL is the
  # training corpus for that tenant's LoRA adapter (see
  # slm-support-platform/phase2-optimizations/2a-model-serving/).
  #
  # No public access ever. Object lifecycle: keep raw exports
  # indefinitely (audit trail + retraining), nearline after 30 days
  # (we re-read on-demand for training runs, not constantly).
  {
    name                        = "tesseract-prod-otto-exports-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = false
    labels = {
      purpose    = "otto-conversation-exports"
      product    = "support-platform"
      region     = "in"
      compliance = "dpdpa"
      sensitive  = "true"
      visibility = "private"
    }
    lifecycle_rules = [
      {
        action = {
          type          = "SetStorageClass"
          storage_class = "NEARLINE"
        }
        condition = {
          age = 30
        }
      }
    ]
    cors         = []
    iam_bindings = []
  },

  # Per-tenant LoRA adapters land here after `train_lora.py` runs.
  # slm-inference loads adapters from this bucket via Workload
  # Identity. Each tenant owns their own subdirectory; never
  # cross-load adapters across tenants.
  {
    name                        = "tesseract-prod-otto-models-in"
    location                    = "asia-south1"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "enforced"
    versioning                  = true
    labels = {
      purpose    = "otto-lora-adapters"
      product    = "support-platform"
      region     = "in"
      compliance = "dpdpa"
      visibility = "private"
    }
    lifecycle_rules = []
    cors            = []
    iam_bindings    = []
  },

  # ===========================================================================
  # CLOUD BUILD - CI source tarballs
  # ===========================================================================
  # Auto-created by Cloud Build on first run. Imported into Terraform so the
  # lifecycle policy is reproducible. The bucket holds gzipped source archives
  # uploaded by GitHub Actions / Cloud Build triggers; nothing reads them after
  # a build completes. 7-day deletion on the `source/` prefix prevents stale
  # tarballs from accumulating (~64 MB at last check, would grow unbounded).
  {
    name                        = "tesseracthub-480811_cloudbuild"
    location                    = "us"
    storage_class               = "STANDARD"
    force_destroy               = false
    uniform_bucket_level_access = true
    public_access_prevention    = "inherited"
    versioning                  = false
    labels = {
      purpose = "cloudbuild-sources"
      product = "global"
      managed = "terraform"
    }
    lifecycle_rules = [
      {
        action = {
          type = "Delete"
        }
        condition = {
          age            = 7
          matches_prefix = ["source/"]
        }
      }
    ]
    cors         = []
    iam_bindings = []
  }
]

# =============================================================================
# Artifact Registry — Docker Repositories
# =============================================================================
# Container images pushed by CI/CD, pulled by GKE.
# URL format: {location}-docker.pkg.dev/{project}/{repo}/{image}
# =============================================================================

docker_repositories = [
  {
    name        = "fanzone"
    description = "FanZone Battle Ground container images"
    location    = "asia-south1"
    labels = {
      product = "fanzone"
    }
    cleanup_policies = [
      {
        id     = "delete-untagged-older-than-3d"
        action = "DELETE"
        condition = {
          tag_state  = "UNTAGGED"
          older_than = "259200s" # 3 days
        }
      },
      {
        id     = "keep-recent-tagged-versions"
        action = "KEEP"
        most_recent_versions = {
          keep_count = 10
        }
      }
    ]
  },
  {
    name        = "global"
    description = "Global services container images"
    location    = "asia-south1"
    labels = {
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-untagged-older-than-3d"
        action = "DELETE"
        condition = {
          tag_state  = "UNTAGGED"
          older_than = "259200s"
        }
      },
      {
        id     = "keep-recent-tagged-versions"
        action = "KEEP"
        most_recent_versions = {
          keep_count = 10
        }
      }
    ]
  },
  {
    name        = "marketplace"
    description = "Marketplace platform container images"
    location    = "asia-south1"
    labels = {
      product = "marketplace"
    }
    cleanup_policies = [
      {
        id     = "delete-untagged-older-than-3d"
        action = "DELETE"
        condition = {
          tag_state  = "UNTAGGED"
          older_than = "259200s"
        }
      },
      {
        id     = "keep-recent-tagged-versions"
        action = "KEEP"
        most_recent_versions = {
          keep_count = 10
        }
      }
    ]
  }
]

# =============================================================================
# Artifact Registry — Docker REMOTE (pull-through cache) Repositories
# Cleanup: prune any cached image older than 3 days (re-fetched from upstream on demand).
# =============================================================================

remote_docker_repositories = [
  {
    name               = "docker-remote"
    description        = "Public Docker Hub mirror — reduces Cloud NAT egress"
    location           = "asia-south1"
    remote_description = "docker.io mirror"
    public_repository  = "DOCKER_HUB"
    labels = {
      purpose = "pull-through-cache"
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-cached-older-than-3d"
        action = "DELETE"
        condition = {
          older_than = "259200s" # 3 days
        }
      }
    ]
  },
  {
    name                  = "ghcr-remote"
    description           = "ghcr.io mirror (authenticated via prod-tesserix-ghcr-token) — reduces Cloud NAT egress"
    location              = "asia-south1"
    remote_description    = "ghcr.io mirror (Sam123ben)"
    common_repository_uri = "https://ghcr.io"
    upstream_credentials = {
      username                = "Sam123ben"
      password_secret_version = "projects/849928263410/secrets/prod-tesserix-ghcr-token/versions/latest"
    }
    labels = {
      purpose = "pull-through-cache"
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-cached-older-than-3d"
        action = "DELETE"
        condition = {
          older_than = "259200s"
        }
      }
    ]
  },
  {
    name                  = "ghcr-nexus-remote"
    description           = "ghcr.io mirror for tesseract-nexus org (authenticated via prod-ghcr-token)"
    location              = "asia-south1"
    remote_description    = "ghcr.io mirror (tesseract-nexus)"
    common_repository_uri = "https://ghcr.io"
    upstream_credentials = {
      username                = "tesseract-nexus"
      password_secret_version = "projects/849928263410/secrets/prod-ghcr-token/versions/latest"
    }
    labels = {
      purpose = "pull-through-cache"
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-cached-older-than-3d"
        action = "DELETE"
        condition = {
          older_than = "259200s"
        }
      }
    ]
  },
  {
    name                  = "k8s-remote"
    description           = "registry.k8s.io mirror — reduces Cloud NAT egress for kube-system images"
    location              = "asia-south1"
    remote_description    = "registry.k8s.io mirror"
    common_repository_uri = "https://registry.k8s.io"
    labels = {
      purpose = "pull-through-cache"
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-cached-older-than-3d"
        action = "DELETE"
        condition = {
          older_than = "259200s"
        }
      }
    ]
  },
  {
    name                  = "quay-remote"
    description           = "quay.io mirror — reduces Cloud NAT egress"
    location              = "asia-south1"
    remote_description    = "quay.io mirror"
    common_repository_uri = "https://quay.io"
    labels = {
      purpose = "pull-through-cache"
      product = "global"
    }
    cleanup_policies = [
      {
        id     = "delete-cached-older-than-3d"
        action = "DELETE"
        condition = {
          older_than = "259200s"
        }
      }
    ]
  }
]

# =============================================================================
# Secrets Manager Configuration
# =============================================================================
# Secrets are created with regional replication (India for production)
# =============================================================================

secrets = [
  # ===========================================================================
  # Infrastructure Secrets
  # ===========================================================================
  {
    secret_id = "prod-infra-db-credentials"
    labels = {
      tier        = "infrastructure"
      type        = "database"
      environment = "prod"
    }
    annotations = {
      "managed-by"  = "terraform"
      "description" = "Database connection strings"
    }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id = "prod-infra-jwt-secrets"
    labels = {
      tier        = "infrastructure"
      type        = "jwt"
      environment = "prod"
    }
    annotations = {
      "managed-by"  = "terraform"
      "description" = "JWT signing keys"
    }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id = "prod-infra-encryption-keys"
    labels = {
      tier        = "infrastructure"
      type        = "encryption"
      environment = "prod"
    }
    annotations = {
      "managed-by"  = "terraform"
      "description" = "AES-256 encryption keys"
    }
    replication_locations = [{ location = "asia-south1" }]
  },
  # OpenBao recovery keys. Created empty here; the bootstrap Job adds the only
  # version, which is why openbao-bootstrap holds secretVersionAdder below.
  {
    secret_id = "prod-openbao-recovery-keys"
    labels = {
      tier        = "infrastructure"
      type        = "encryption"
      environment = "prod"
    }
    annotations = {
      "managed-by"  = "terraform"
      "description" = "OpenBao recovery keys and initial root token"
    }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Auth Secrets
  # ===========================================================================
  {
    secret_id             = "prod-admin-init-secret"
    labels                = { tier = "auth", type = "admin", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Admin initialization secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-jwt-secret"
    labels                = { tier = "auth", type = "jwt", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "JWT signing secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-jwt-refresh-secret"
    labels                = { tier = "auth", type = "jwt", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "JWT refresh token secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-encryption-key"
    labels                = { tier = "auth", type = "encryption", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "General encryption key" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Database Secrets - PostgreSQL Passwords
  # ===========================================================================
  {
    secret_id             = "prod-global-postgresql-password"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "global" }
    annotations           = { "managed-by" = "terraform", "description" = "Global PostgreSQL password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-bookkeeping-postgresql-password"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "bookkeeping" }
    annotations           = { "managed-by" = "terraform", "description" = "Bookkeeping PostgreSQL password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-fanzone-postgresql-password"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone PostgreSQL password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-homechef-postgresql-password"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "homechef" }
    annotations           = { "managed-by" = "terraform", "description" = "Homechef PostgreSQL password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  # ===========================================================================
  # Database Secrets - PostgreSQL Certificates
  # ===========================================================================
  {
    secret_id             = "prod-postgresql-ca-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "PostgreSQL CA certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-server-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "PostgreSQL server certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-server-key"
    labels                = { tier = "database", type = "certificate", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "PostgreSQL server key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-global-ca-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "global" }
    annotations           = { "managed-by" = "terraform", "description" = "Global PostgreSQL CA certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-global-server-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "global" }
    annotations           = { "managed-by" = "terraform", "description" = "Global PostgreSQL server certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-global-server-key"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "global" }
    annotations           = { "managed-by" = "terraform", "description" = "Global PostgreSQL server key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-bookkeeping-ca-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "bookkeeping" }
    annotations           = { "managed-by" = "terraform", "description" = "Bookkeeping PostgreSQL CA certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-bookkeeping-server-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "bookkeeping" }
    annotations           = { "managed-by" = "terraform", "description" = "Bookkeeping PostgreSQL server certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-bookkeeping-server-key"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "bookkeeping" }
    annotations           = { "managed-by" = "terraform", "description" = "Bookkeeping PostgreSQL server key" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Customer Tier Secrets
  # ===========================================================================
  {
    secret_id             = "prod-customer-api-keys"
    labels                = { tier = "customer", type = "api-keys", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Customer API keys for integrations" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-customer-credentials"
    labels                = { tier = "customer", type = "credentials", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Customer OAuth/SSO credentials" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-customer-tenant-configs"
    labels                = { tier = "customer", type = "config", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Tenant-specific configurations" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Third-Party Secrets - Email/Communication
  # ===========================================================================
  {
    secret_id             = "prod-thirdparty-email"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "SendGrid API keys" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-thirdparty-messaging"
    labels                = { tier = "thirdparty", type = "messaging", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "FCM, Twilio, SMS gateway credentials" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-thirdparty-payment"
    labels                = { tier = "thirdparty", type = "payment", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Payment gateway credentials" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-sendgrid-api-key"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "SendGrid API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ses-smtp-username"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "AWS SES SMTP username" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ses-smtp-password"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "AWS SES SMTP password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ses-smtp-relay-username"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "SES SMTP relay username" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ses-smtp-relay-password"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "SES SMTP relay password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postal-api-key"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Postal API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postal-admin-credentials"
    labels                = { tier = "thirdparty", type = "email", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Postal admin credentials" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mautic-api-password"
    labels                = { tier = "thirdparty", type = "marketing", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Mautic API password" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Third-Party Secrets - APIs
  # ===========================================================================
  {
    secret_id             = "prod-cloudflare-api-token"
    labels                = { tier = "thirdparty", type = "api", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Cloudflare API token" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-firebase-sa-key"
    labels                = { tier = "thirdparty", type = "firebase", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Firebase service account key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-google-client-id"
    labels                = { tier = "thirdparty", type = "oauth", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Google OAuth client ID" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-google-client-secret"
    labels                = { tier = "thirdparty", type = "oauth", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Google OAuth client secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ghcr-token"
    labels                = { tier = "thirdparty", type = "registry", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "GitHub Container Registry token" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-ghcr-username"
    labels                = { tier = "thirdparty", type = "registry", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "GitHub Container Registry username" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-rapidapi-key"
    labels                = { tier = "thirdparty", type = "api", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "RapidAPI key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-typesense-api-key"
    labels                = { tier = "thirdparty", type = "search", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Typesense API key" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Location Services Secrets
  # ===========================================================================
  {
    secret_id             = "prod-location-service-google-api-key"
    labels                = { tier = "thirdparty", type = "location", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Google Maps API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-location-service-locationiq-api-key"
    labels                = { tier = "thirdparty", type = "location", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "LocationIQ API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-location-service-mapbox-token"
    labels                = { tier = "thirdparty", type = "location", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Mapbox access token" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Fanzone Secrets
  # ===========================================================================
  {
    secret_id             = "prod-fanzone-jwt-secret"
    labels                = { tier = "application", type = "jwt", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone JWT secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-fanzone-mongodb-url"
    labels                = { tier = "database", type = "mongodb", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone MongoDB connection URL for external access" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-fanzone-postgresql-url"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone PostgreSQL URL (fanzone DB) for external access" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-auth-database-url"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone Auth PostgreSQL URL (fanzone_auth DB) for external access" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-klipy-api-key"
    labels                = { tier = "thirdparty", type = "api-key", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Klipy GIF API key for media service" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-jwt-refresh-secret"
    labels                = { tier = "auth", type = "jwt", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone JWT refresh token secret" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-encryption-key"
    labels                = { tier = "auth", type = "encryption", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone AES-256 encryption key" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-internal-api-key"
    labels                = { tier = "auth", type = "api-key", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone internal service-to-service API key" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-google-client-id"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Google OAuth client ID" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-google-client-secret"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Google OAuth client secret" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-meta-client-id"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Meta/Facebook OAuth client ID" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-meta-client-secret"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Meta/Facebook OAuth client secret" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-twitter-client-id"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Twitter/X OAuth client ID" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-oauth-twitter-client-secret"
    labels                = { tier = "auth", type = "oauth", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Twitter/X OAuth client secret" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-twilio-account-sid"
    labels                = { tier = "thirdparty", type = "twilio", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Twilio account SID for OTP" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-twilio-auth-token"
    labels                = { tier = "thirdparty", type = "twilio", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Twilio auth token for OTP" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-twilio-service-sid"
    labels                = { tier = "thirdparty", type = "twilio", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Twilio Verify service SID" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-admin-init-secret"
    labels                = { tier = "auth", type = "admin", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Fanzone admin initialization secret" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-session-secret"
    labels                = { tier = "auth", type = "session", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "Session signing secret for BFF" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-cricketdata-api-key"
    labels                = { tier = "thirdparty", type = "api-key", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "CricketData.org API key" }
    replication_locations = null
  },
  {
    secret_id             = "prod-fanzone-mysportsfeeds-api-key"
    labels                = { tier = "thirdparty", type = "api-key", environment = "prod", namespace = "fanzone" }
    annotations           = { "managed-by" = "terraform", "description" = "MySportsFeeds API key for NFL/NBA/NHL/MLB" }
    replication_locations = null
  },

  # ===========================================================================
  # Verification Secrets
  # ===========================================================================
  {
    secret_id             = "prod-verification-api-key"
    labels                = { tier = "thirdparty", type = "verification", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Verification service API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-verification-email-api-key"
    labels                = { tier = "thirdparty", type = "verification", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Email verification API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-verification-encryption-key"
    labels                = { tier = "thirdparty", type = "verification", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Verification encryption key" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Legacy Secrets (pre-existing in GCP)
  # ===========================================================================
  {
    secret_id             = "prod-db-password"
    labels                = { tier = "infrastructure", type = "database", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Database password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-fcm-credentials"
    labels                = { tier = "thirdparty", type = "messaging", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Firebase Cloud Messaging credentials" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-maps-api-key"
    labels                = { tier = "thirdparty", type = "api", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Google Maps API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-razorpay-key"
    labels                = { tier = "thirdparty", type = "payment", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Razorpay payment gateway key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-stripe-key"
    labels                = { tier = "thirdparty", type = "payment", environment = "prod" }
    annotations           = { "managed-by" = "terraform", "description" = "Stripe payment gateway key" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Marketplace Secrets — Platform (auth-bff, openfga, shared)
  # ===========================================================================
  {
    secret_id             = "prod-mp-auth-bff-cookie-encryption-key"
    labels                = { tier = "application", type = "encryption", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Auth BFF cookie encryption key (auto-generated)" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-auth-bff-csrf-secret"
    labels                = { tier = "application", type = "csrf", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Auth BFF CSRF secret (auto-generated)" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-openfga-preshared-key"
    labels                = { tier = "application", type = "auth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "OpenFGA preshared key (auto-generated)" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-shared-internal-service-key"
    labels                = { tier = "application", type = "auth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Shared internal service-to-service key (auto-generated)" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-openfga-db-uri"
    labels                = { tier = "database", type = "postgresql", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "OpenFGA full database URI" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Marketplace Secrets — Third-Party Integrations
  # ===========================================================================
  {
    secret_id             = "prod-mp-stripe-secret-key"
    labels                = { tier = "thirdparty", type = "payment", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace Stripe secret key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-stripe-webhook-secret"
    labels                = { tier = "thirdparty", type = "payment", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace Stripe webhook secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-growthbook-api-key"
    labels                = { tier = "thirdparty", type = "feature-flags", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "GrowthBook feature flags API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-identity-platform-smtp-password"
    labels                = { tier = "thirdparty", type = "email", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Identity Platform SMTP password" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Marketplace Secrets — Client Secrets & Auth
  # ===========================================================================
  {
    secret_id             = "prod-mp-platform-client-secret"
    labels                = { tier = "application", type = "oauth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Platform OAuth client secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-admin-client-secret"
    labels                = { tier = "application", type = "oauth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace admin OAuth client secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-storefront-client-secret"
    labels                = { tier = "application", type = "oauth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace storefront OAuth client secret" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-openfga-marketplace-store-id"
    labels                = { tier = "application", type = "auth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "OpenFGA marketplace store ID" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-openfga-platform-store-id"
    labels                = { tier = "application", type = "auth", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "OpenFGA platform store ID" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-verification-encryption-key"
    labels                = { tier = "application", type = "encryption", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Verification encryption key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-mp-admin-csrf-secret"
    labels                = { tier = "application", type = "csrf", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace admin CSRF secret" }
    replication_locations = [{ location = "asia-south1" }]
  },

  # ===========================================================================
  # Marketplace Secrets — Pre-existing (already in GCP/state)
  # ===========================================================================
  {
    secret_id             = "prod-marketplace-api-key"
    labels                = { tier = "application", type = "api-key", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace API key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-marketplace-encryption-key"
    labels                = { tier = "application", type = "encryption", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace encryption key" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-marketplace-google-translate-api-key"
    labels                = { tier = "thirdparty", type = "api-key", environment = "prod", product = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Google Translate API key for marketplace" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-marketplace-jwt-secret"
    labels                = { tier = "auth", type = "jwt", environment = "prod", namespace = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace JWT signing secret" }
    replication_locations = null # Uses auto replication (existing)
  },
  {
    secret_id             = "prod-marketplace-postgresql-password"
    labels                = { tier = "database", type = "postgresql", environment = "prod", namespace = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace PostgreSQL password" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-marketplace-ca-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace PostgreSQL CA certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-marketplace-server-cert"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace PostgreSQL server certificate" }
    replication_locations = [{ location = "asia-south1" }]
  },
  {
    secret_id             = "prod-postgresql-marketplace-server-key"
    labels                = { tier = "database", type = "certificate", environment = "prod", namespace = "marketplace" }
    annotations           = { "managed-by" = "terraform", "description" = "Marketplace PostgreSQL server key" }
    replication_locations = [{ location = "asia-south1" }]
  }
]

# =============================================================================
# Kubernetes Bootstrap Configuration
# =============================================================================

enable_k8s_bootstrap = true

# Cert-Manager (Let's Encrypt)
install_cert_manager       = true
cert_manager_namespace     = "cert-manager"
cert_manager_chart_version = "v1.13.3"
cert_manager_replicas      = 2 # HA for production

# Cloudflare DNS01 Challenge
# Values provided via TF_VAR_* environment variables
enable_cloudflare_dns = true # Set to true when cloudflare_api_token is provided
cloudflare_domain     = "tesseracthub.app"
letsencrypt_email     = "samyak.rout@gmail.com"
letsencrypt_issuer    = "letsencrypt-prod"

# Kong Ingress Controller
install_kong            = true
kong_namespace          = "kong"
kong_chart_version      = "2.33.0"
kong_ingress_class      = "kong"
kong_proxy_service_type = "LoadBalancer"
kong_admin_enabled      = false
kong_replicas           = 2 # HA for production

# ArgoCD — migrated 2026-07-21 to argocd-operator v0.18.0 (Argo CD v3.3.10).
# The operator + ArgoCD CR are installed manually (kustomize) and GitOps-managed
# via argocd/prod/infrastructure/argocd.yaml -> charts/argocd-operator/. With
# argocd_use_operator=true the helm_release.argocd below is disabled so a future
# apply never reinstalls the Helm control plane. The argocd_* chart/version vars
# are retained only for the (disabled) helm_release / rollback path.
install_argocd      = true
argocd_use_operator = true
argocd_namespace    = "argocd"
# Operator-managed runtime (source of truth = charts/argocd-operator/argocd-instance.yaml):
#   operator: argoproj-labs/argocd-operator v0.18.0 ; Argo CD image: quay.io/argoproj/argocd:v3.3.10
#   HA redis (3+3 haproxy) ; controller sharding replicas=3 (consistent-hashing) ; repo replicas=3 ; server replicas=2
# Legacy helm_release values (DISABLED via argocd_use_operator; NOT live — live was chart 9.5.21 / v3.4.3 before migration):
argocd_chart_version        = "9.5.21"
argocd_image_tag            = "v3.4.3"
argocd_server_insecure      = true
argocd_server_replicas      = 2
argocd_controller_replicas  = 3
argocd_repo_server_replicas = 3

# ArgoCD Resources - Increased for production with many applications
argocd_controller_resources = {
  limits = {
    cpu    = "2000m"
    memory = "2Gi"
  }
  requests = {
    cpu    = "500m"
    memory = "512Mi"
  }
}

argocd_server_resources = {
  limits = {
    cpu    = "500m"
    memory = "512Mi"
  }
  requests = {
    cpu    = "100m"
    memory = "128Mi"
  }
}

argocd_repo_server_resources = {
  limits = {
    cpu    = "1"
    memory = "1Gi"
  }
  requests = {
    cpu    = "200m"
    memory = "256Mi"
  }
}

# ArgoCD Ingress
argocd_ingress_enabled = true
argocd_ingress_class   = "kong"
argocd_hostname        = "argocd.tesseracthub.app"
argocd_ingress_tls     = true

# ArgoCD SSO (Enable for production)
# NOTE: google_oauth_client_id and google_oauth_client_secret should be set via environment variables:
#   export TF_VAR_google_oauth_client_id="your-client-id.apps.googleusercontent.com"
#   export TF_VAR_google_oauth_client_secret="your-client-secret"
argocd_enable_sso    = true
argocd_admin_enabled = true # Keep admin login enabled as fallback while Google SSO is being configured
argocd_url           = "https://argocd.tesseracthub.app"
argocd_admin_users = [
  "samyak.rout@gmail.com"
]

# Google OAuth credentials - set via environment variables TF_VAR_google_oauth_client_id and TF_VAR_google_oauth_client_secret
# google_oauth_client_id     = ""  # Set via TF_VAR_google_oauth_client_id
# google_oauth_client_secret = ""  # Set via TF_VAR_google_oauth_client_secret

# ArgoCD Repository
argocd_repo_url          = "https://github.com/tesserix/tesserix-k8s.git"
argocd_repo_revision     = "main" # Use main branch for production
argocd_bootstrap_enabled = true
argocd_repo_auth_method  = "github-app"


# =============================================================================
# Workload Identity Configuration
# =============================================================================
# Service accounts are organized by product with proper bucket bindings
# for both AU and IN regions to support multi-region deployments.
# =============================================================================

enable_workload_identity = true

service_accounts = [
  # ===========================================================================
  # GLOBAL - Core Platform Service Accounts
  # ===========================================================================
  # Backend Service Account - Core platform APIs
  {
    name               = "tesseract-prod-backend-sa"
    self_token_creator = true
    display_name       = "Tesseract Production Backend"
    description        = "Service account for core backend services"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "backend-api"
      },
      {
        namespace                  = "global"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = [
      # Global assets - India
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # Global assets - Australia
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # Document Service Account - Handles all document uploads
  # Note: Using document-service-sa (without -prod) to match Helm chart annotation
  {
    name               = "document-service-sa"
    self_token_creator = true
    display_name       = "Document Service Account"
    description        = "Service account for document management across all products"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "document-service"
      },
      {
        namespace                  = "marketplace"
        kubernetes_service_account = "document-service"
      }
    ]
    bucket_bindings = [
      # Global assets - all regions
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      },
      # Marketplace assets
      {
        bucket = "marketplace-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "marketplace-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      {
        bucket = "marketplace-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "marketplace-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      },
      {
        bucket = "marketplace-prod-public-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "marketplace-prod-public-in"
        role   = "roles/storage.objectAdmin"
      }
    ]
    secret_bindings = []
  },

  # Tenant Onboarding Service Account
  # Note: Using tenant-onboarding-sa (without -prod) to match Helm chart annotation
  {
    name               = "tenant-onboarding-sa"
    self_token_creator = true
    display_name       = "Tenant Onboarding Service Account"
    description        = "Service account for tenant onboarding document uploads"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "tenant-onboarding"
      }
    ]
    bucket_bindings = [
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # HMS - Hospital Management System Service Accounts
  # ===========================================================================
  {
    name               = "hms-prod-backend-sa"
    self_token_creator = true
    display_name       = "HMS Production Backend"
    description        = "Service account for HMS backend with access to all HMS regional buckets"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "hms"
        kubernetes_service_account = "hms-backend"
      },
      {
        namespace                  = "hms"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = [
      # HMS Assets - India
      {
        bucket = "hms-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # HMS Assets - Australia
      {
        bucket = "hms-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      },
      # HMS Backups - India
      {
        bucket = "hms-prod-backups-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-backups-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # HMS Backups - Australia
      {
        bucket = "hms-prod-backups-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-backups-au"
        role   = "roles/storage.legacyBucketReader"
      },
      # HMS Patient Records - India (Sensitive)
      {
        bucket = "hms-prod-patientrecords-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-patientrecords-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # HMS Patient Records - Australia (Sensitive)
      {
        bucket = "hms-prod-patientrecords-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "hms-prod-patientrecords-au"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # FANZONE - Sports/Entertainment Platform Service Accounts
  # ===========================================================================
  {
    name               = "fanzone-prod-backend-sa"
    self_token_creator = true
    display_name       = "Fanzone Production Backend"
    description        = "Service account for fanzone backend services"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "fanzone"
        kubernetes_service_account = "fanzone-backend"
      },
      {
        namespace                  = "fanzone"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = [
      # Fanzone assets - India
      {
        bucket = "fanzone-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "fanzone-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # Fanzone assets - Australia
      {
        bucket = "fanzone-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "fanzone-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # HOMECHEF - Food Delivery Platform Service Accounts
  # ===========================================================================
  {
    name               = "homechef-prod-backend-sa"
    self_token_creator = true
    display_name       = "Homechef Production Backend"
    description        = "Service account for homechef backend services (fe3dr.com)"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "homechef"
        kubernetes_service_account = "homechef-backend"
      },
      {
        namespace                  = "homechef"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = [
      # Public assets bucket (menu images, food photos, profile pics)
      {
        bucket = "homechef-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "homechef-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # Private docs bucket (compliance: PAN, FSSAI, Aadhaar) — signed URL generation
      {
        bucket = "homechef-prod-docs-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "homechef-prod-docs-in"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # BOOKKEEPING - Accounting Platform Service Accounts
  # ===========================================================================
  {
    name               = "bookkeeping-prod-backend-sa"
    self_token_creator = true
    display_name       = "Bookkeeping Production Backend"
    description        = "Service account for bookkeeping backend services"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "bookkeeping"
        kubernetes_service_account = "bookkeeping-backend"
      },
      {
        namespace                  = "bookkeeping"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = [
      # Bookkeeping assets - India
      {
        bucket = "bookkeeping-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "bookkeeping-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      },
      # Bookkeeping assets - Australia
      {
        bucket = "bookkeeping-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "bookkeeping-prod-assets-au"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # APP SECRETS - Per-Namespace Service Accounts for External Secrets Operator
  # ===========================================================================
  # App Secrets Global
  {
    name               = "app-secrets-global-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - global"
    description        = "Service account for global namespace to access secrets"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # App Secrets HMS
  {
    name               = "app-secrets-hms-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - hms"
    description        = "Service account for hms namespace to access secrets"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "hms"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # App Secrets Fanzone
  # All fanzone services use this GCP SA via Workload Identity
  {
    name               = "app-secrets-fanzone-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - fanzone"
    description        = "Service account for fanzone namespace to access secrets and storage"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      { namespace = "fanzone", kubernetes_service_account = "default" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-api" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-auth" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-auth-bff" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-book-cricket" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-chat" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-cleanup" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-commentary" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-fan-connect" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-game" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-media" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-micro-prediction" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-moderation" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-notification" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-prediction" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-prediction-bot" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-quest" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-sportsbook" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-user" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-web" },
      { namespace = "fanzone", kubernetes_service_account = "fanzone-ws" },
      { namespace = "fanzone", kubernetes_service_account = "sports-data" },
    ]
    bucket_bindings = [
      {
        bucket = "fanzone-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "fanzone-prod-assets-au"
        role   = "roles/storage.objectAdmin"
      },
    ]
    secret_bindings = []
  },
  # App Secrets Homechef
  {
    name               = "app-secrets-homechef-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - homechef"
    description        = "Service account for homechef namespace to access secrets"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "homechef"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # App Secrets Support-Platform — Otto + slm-router + export Job
  # Bound to:
  #   - tesseract-prod-otto-exports-in (write, via export CronJob)
  #   - tesseract-prod-otto-models-in  (read,  via slm-inference for LoRA adapters)
  {
    name               = "app-secrets-support-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - support-platform"
    description        = "Service account for support-platform namespace: Otto, slm-router, export CronJob"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "support-platform"
        kubernetes_service_account = "default"
      },
      {
        namespace                  = "support-platform"
        kubernetes_service_account = "support-platform-export"
      },
      {
        namespace                  = "support-platform"
        kubernetes_service_account = "support-platform-slm-inference"
      }
    ]
    bucket_bindings = [
      {
        bucket = "tesseract-prod-otto-exports-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-otto-models-in"
        role   = "roles/storage.objectViewer"
      }
    ]
    secret_bindings = []
  },
  # App Secrets Bookkeeping
  {
    name               = "app-secrets-bookkeeping-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - bookkeeping"
    description        = "Service account for bookkeeping namespace to access secrets"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "bookkeeping"
        kubernetes_service_account = "default"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # App Secrets External Secrets Operator
  {
    name               = "app-secrets-ext-secrets-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - external-secrets"
    description        = "Service account for external-secrets operator namespace"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "external-secrets"
        kubernetes_service_account = "external-secrets"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },

  # ===========================================================================
  # INFRASTRUCTURE & SHARED SERVICE ACCOUNTS
  # ===========================================================================
  # Communication Services (Firebase, Push Notifications)
  {
    name               = "prod-comm-services-sa"
    self_token_creator = true
    display_name       = "Communication Services Account"
    description        = "Service account for communication services (Firebase, push notifications)"
    project_roles = [
      "roles/firebase.admin"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "notification-service"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # Infrastructure Backend Secrets
  {
    name               = "infra-backend-secrets-prod-sa"
    self_token_creator = true
    display_name       = "Infrastructure Backend Secrets Accessor"
    description        = "Service account for infrastructure backend secrets access"
    project_roles = [
      "roles/secretmanager.secretAccessor",
      "roles/iam.serviceAccountUser"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "infra-backend"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # Customer Tenant Secrets
  {
    name               = "customer-tenant-secrets-prod"
    self_token_creator = true
    display_name       = "Customer Tenant Secrets Accessor"
    description        = "Service account for customer tenant secrets access"
    project_roles = [
      "roles/secretmanager.secretAccessor",
      "roles/iam.serviceAccountUser"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "tenant-service"
      },
      {
        namespace                  = "marketplace"
        kubernetes_service_account = "tenant-service"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # Third-Party Integration Secrets
  {
    name               = "thirdparty-integ-secrets-prod"
    self_token_creator = true
    display_name       = "Third-Party Integration Secrets Accessor"
    description        = "Service account for third-party integration secrets (payment, email, etc.)"
    project_roles = [
      "roles/secretmanager.secretAccessor",
      "roles/iam.serviceAccountUser"
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "payment-service"
      },
      {
        namespace                  = "marketplace"
        kubernetes_service_account = "payment-service"
      }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # QR Service
  {
    name               = "qr-service-prod-sa"
    self_token_creator = true
    display_name       = "QR Service Account"
    description        = "Service account for QR code generation service"
    project_roles = [
    ]
    workload_identity_bindings = [
      {
        namespace                  = "global"
        kubernetes_service_account = "qr-service"
      },
      {
        namespace                  = "marketplace"
        kubernetes_service_account = "qr-service"
      }
    ]
    bucket_bindings = [
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.objectAdmin"
      },
      {
        bucket = "tesseract-prod-assets-in"
        role   = "roles/storage.legacyBucketReader"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # MARKETPLACE — Multi-Tenant E-Commerce Platform Service Accounts
  # ===========================================================================
  # Service accounts for marketplace microservices running on GKE.
  # Each service gets WI binding to the marketplace namespace.
  # Secrets use prod-mp-* prefix. Storage uses marketplace-prod-* buckets.
  # ===========================================================================

  # Marketplace Backend — unified SA for all marketplace GKE services
  {
    name               = "marketplace-prod-backend-sa"
    self_token_creator = true
    display_name       = "Marketplace Production Backend"
    description        = "Service account for marketplace backend services"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      { namespace = "marketplace", kubernetes_service_account = "marketplace-backend" },
      { namespace = "marketplace", kubernetes_service_account = "default" }
    ]
    bucket_bindings = [
      { bucket = "marketplace-prod-assets-in", role = "roles/storage.objectAdmin" },
      { bucket = "marketplace-prod-assets-in", role = "roles/storage.legacyBucketReader" },
      { bucket = "marketplace-prod-public-in", role = "roles/storage.objectAdmin" },
      { bucket = "marketplace-prod-public-in", role = "roles/storage.legacyBucketReader" },
      { bucket = "marketplace-prod-assets-au", role = "roles/storage.objectAdmin" },
      { bucket = "marketplace-prod-assets-au", role = "roles/storage.legacyBucketReader" }
    ]
    secret_bindings = []
  },

  # App Secrets Marketplace — ESO accessor for marketplace namespace
  {
    name               = "app-secrets-marketplace-prod"
    self_token_creator = true
    display_name       = "App Secrets Accessor - marketplace"
    description        = "Service account for marketplace namespace to access secrets and storage"
    project_roles = [
      "roles/secretmanager.secretAccessor"
    ]
    workload_identity_bindings = [
      { namespace = "marketplace", kubernetes_service_account = "default" },
      # Platform services
      { namespace = "marketplace", kubernetes_service_account = "auth-bff" },
      { namespace = "marketplace", kubernetes_service_account = "openfga" },
      { namespace = "marketplace", kubernetes_service_account = "audit-service" },
      { namespace = "marketplace", kubernetes_service_account = "notification-service" },
      { namespace = "marketplace", kubernetes_service_account = "tenant-service" },
      { namespace = "marketplace", kubernetes_service_account = "settings-service" },
      { namespace = "marketplace", kubernetes_service_account = "subscription-service" },
      { namespace = "marketplace", kubernetes_service_account = "feature-flags-service" },
      { namespace = "marketplace", kubernetes_service_account = "tickets-service" },
      { namespace = "marketplace", kubernetes_service_account = "document-service" },
      { namespace = "marketplace", kubernetes_service_account = "status-service" },
      { namespace = "marketplace", kubernetes_service_account = "qr-service" },
      { namespace = "marketplace", kubernetes_service_account = "analytics-service" },
      { namespace = "marketplace", kubernetes_service_account = "verification-service" },
      { namespace = "marketplace", kubernetes_service_account = "location-service" },
      { namespace = "marketplace", kubernetes_service_account = "tenant-router-service" },
      # Marketplace product services
      { namespace = "marketplace", kubernetes_service_account = "marketplace-onboarding" },
      { namespace = "marketplace", kubernetes_service_account = "marketplace-admin" },
      { namespace = "marketplace", kubernetes_service_account = "mp-storefront" },
      { namespace = "marketplace", kubernetes_service_account = "mp-products" },
      { namespace = "marketplace", kubernetes_service_account = "mp-orders" },
      { namespace = "marketplace", kubernetes_service_account = "mp-payments" },
      { namespace = "marketplace", kubernetes_service_account = "mp-inventory" },
      { namespace = "marketplace", kubernetes_service_account = "mp-shipping" },
      { namespace = "marketplace", kubernetes_service_account = "mp-categories" },
      { namespace = "marketplace", kubernetes_service_account = "mp-coupons" },
      { namespace = "marketplace", kubernetes_service_account = "mp-reviews" },
      { namespace = "marketplace", kubernetes_service_account = "mp-vendors" },
      { namespace = "marketplace", kubernetes_service_account = "mp-customers" },
      { namespace = "marketplace", kubernetes_service_account = "mp-staff" },
      { namespace = "marketplace", kubernetes_service_account = "mp-content" },
      { namespace = "marketplace", kubernetes_service_account = "mp-approvals" },
      { namespace = "marketplace", kubernetes_service_account = "mp-gift-cards" },
      { namespace = "marketplace", kubernetes_service_account = "mp-marketing" },
      { namespace = "marketplace", kubernetes_service_account = "mp-connector" },
      { namespace = "marketplace", kubernetes_service_account = "mp-tax" }
    ]
    bucket_bindings = [
      { bucket = "marketplace-prod-assets-in", role = "roles/storage.objectAdmin" },
      { bucket = "marketplace-prod-public-in", role = "roles/storage.objectAdmin" },
      { bucket = "marketplace-prod-assets-au", role = "roles/storage.objectAdmin" }
    ]
    secret_bindings = []
  },

  # Marketplace Identity Platform Admin — tenant-service needs Identity Platform Admin role
  {
    name               = "mp-tenant-service-sa"
    self_token_creator = true
    display_name       = "Marketplace Tenant Service"
    description        = "Service account for marketplace tenant-service — manages GIP tenants and users"
    project_roles = [
      "roles/secretmanager.secretAccessor",
      "roles/identityplatform.admin",
      "roles/serviceusage.serviceUsageConsumer"
    ]
    workload_identity_bindings = [
      { namespace = "marketplace", kubernetes_service_account = "tenant-service" }
    ]
    bucket_bindings = []
    secret_bindings = [
      { secret_id = "prod-mp-shared-internal-service-key", role = "roles/secretmanager.secretAccessor" },
      { secret_id = "prod-mp-openfga-preshared-key", role = "roles/secretmanager.secretAccessor" }
    ]
  },

  # Marketplace Pub/Sub Publisher — services that publish events
  {
    name         = "mp-pubsub-publisher-sa"
    display_name = "Marketplace Pub/Sub Publisher"
    description  = "Service account for marketplace services that publish events"
    project_roles = [
      "roles/pubsub.publisher"
    ]
    workload_identity_bindings = [
      { namespace = "marketplace", kubernetes_service_account = "settings-service" },
      { namespace = "marketplace", kubernetes_service_account = "subscription-service" },
      { namespace = "marketplace", kubernetes_service_account = "tickets-service" },
      { namespace = "marketplace", kubernetes_service_account = "verification-service" },
      { namespace = "marketplace", kubernetes_service_account = "tenant-router-service" },
      { namespace = "marketplace", kubernetes_service_account = "mp-products" },
      { namespace = "marketplace", kubernetes_service_account = "mp-orders" },
      { namespace = "marketplace", kubernetes_service_account = "mp-payments" },
      { namespace = "marketplace", kubernetes_service_account = "mp-inventory" },
      { namespace = "marketplace", kubernetes_service_account = "mp-staff" },
      { namespace = "marketplace", kubernetes_service_account = "mp-approvals" },
      { namespace = "marketplace", kubernetes_service_account = "mp-gift-cards" },
      { namespace = "marketplace", kubernetes_service_account = "mp-marketing" },
      { namespace = "marketplace", kubernetes_service_account = "mp-tax" }
    ]
    bucket_bindings = []
    secret_bindings = []
  },

  # ===========================================================================
  # BLOG - Blog Assets Writer (upload-only to GCS public bucket)
  # ===========================================================================
  {
    name          = "blog-assets-writer"
    display_name  = "Blog Assets Writer"
    description   = "Upload-only access to tesserix-blog-assets GCS bucket for blog image uploads"
    project_roles = []
    workload_identity_bindings = [
      { namespace = "tesserix", kubernetes_service_account = "tesserix-blog" }
    ]
    bucket_bindings = [
      {
        bucket = "tesserix-blog-assets"
        role   = "roles/storage.objectCreator"
      }
    ]
    secret_bindings = []
  },

  # ===========================================================================
  # OPENBAO - Secret store. Three accounts, one job each, so a compromised
  # snapshot pod cannot write recovery keys and vice versa.
  # ===========================================================================
  # The server itself. Its only privilege is the unseal key, granted in
  # kms_keys above rather than here.
  {
    name          = "openbao"
    display_name  = "OpenBao Server"
    description   = "Auto-unseal via Cloud KMS for the openbao StatefulSet"
    project_roles = []
    workload_identity_bindings = [
      { namespace = "openbao", kubernetes_service_account = "openbao" }
    ]
    bucket_bindings = []
    secret_bindings = []
  },
  # Bootstrap Job. Adds the recovery-key version once, at cluster init; viewer
  # lets it check whether a version already exists before re-initialising.
  {
    name          = "openbao-bootstrap"
    display_name  = "OpenBao Bootstrap"
    description   = "Stores OpenBao recovery keys at cluster initialisation"
    project_roles = []
    workload_identity_bindings = [
      { namespace = "openbao", kubernetes_service_account = "openbao-bootstrap" }
    ]
    bucket_bindings = []
    secret_bindings = [
      { secret_id = "prod-openbao-recovery-keys", role = "roles/secretmanager.viewer" },
      { secret_id = "prod-openbao-recovery-keys", role = "roles/secretmanager.secretVersionAdder" },
      # Reads the root token back when a partial first run left the cluster
      # initialised but Kubernetes auth unconfigured.
      { secret_id = "prod-openbao-recovery-keys", role = "roles/secretmanager.secretAccessor" }
    ]
  },
  # Snapshot CronJob. objectAdmin rather than objectCreator: it prunes
  # snapshots past the retention window as well as writing them.
  {
    name          = "openbao-snapshot"
    display_name  = "OpenBao Snapshot"
    description   = "Writes and prunes raft snapshots in the backups bucket"
    project_roles = []
    workload_identity_bindings = [
      { namespace = "openbao", kubernetes_service_account = "openbao-snapshot" }
    ]
    bucket_bindings = [
      {
        bucket = "tesseract-prod-backups-in"
        role   = "roles/storage.objectAdmin"
      }
    ]
    secret_bindings = []
  },
  # secret-service console, Google Secret Manager backend. The custom role is
  # everything but versions.access, so the console cannot read back a payload
  # it wrote — the same write-blindness its OpenBao policy gives it.
  {
    name         = "secret-service"
    display_name = "Secret Service Console"
    description  = "Manages Secret Manager secrets for the secret-service console"
    project_roles = [
      "projects/tesseracthub-480811/roles/secretManagerWriteBlind"
    ]
    workload_identity_bindings = [
      { namespace = "secret-service", kubernetes_service_account = "secret-service-api" }
    ]
    bucket_bindings = []
    secret_bindings = []
  }
]

# =============================================================================
# Application Secrets Configuration
# =============================================================================
# Products: global, hms, fanzone, homechef, bookkeeping
# =============================================================================

enable_app_secrets = true

namespaces = ["global", "hms", "fanzone", "homechef", "bookkeeping", "marketplace", "external-secrets"]

app_secrets = [
  # Auth Secrets
  {
    name                  = "prod-jwt-secret"
    category              = "auth"
    accessible_namespaces = ["*"]
  },
  {
    name                  = "prod-encryption-key"
    category              = "auth"
    accessible_namespaces = ["*"]
  },
  {
    name                  = "prod-csrf-secret"
    category              = "auth"
    accessible_namespaces = ["global"]
  },

  # Database Secrets
  {
    name                  = "prod-db-password"
    category              = "database"
    accessible_namespaces = ["global", "hms", "fanzone", "homechef", "bookkeeping"]
  },

  # Payment Secrets
  {
    name                  = "prod-razorpay-key"
    category              = "payment"
    accessible_namespaces = ["hms", "homechef"]
  },
  {
    name                  = "prod-stripe-key"
    category              = "payment"
    accessible_namespaces = ["homechef", "marketplace"]
  },

  # Marketplace Secrets
  {
    name                  = "prod-mp-auth-bff-cookie-encryption-key"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-auth-bff-csrf-secret"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-openfga-preshared-key"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-shared-internal-service-key"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-stripe-secret-key"
    category              = "payment"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-stripe-webhook-secret"
    category              = "payment"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-admin-client-secret"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-storefront-client-secret"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-openfga-marketplace-store-id"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },
  {
    name                  = "prod-mp-admin-csrf-secret"
    category              = "auth"
    accessible_namespaces = ["marketplace"]
  },

  # API Secrets
  {
    name                  = "prod-maps-api-key"
    category              = "api"
    accessible_namespaces = ["global", "hms", "homechef"]
  },
  {
    name                  = "prod-fcm-credentials"
    category              = "api"
    accessible_namespaces = ["global", "hms", "fanzone", "homechef"]
  }
]

# =============================================================================
# Communication Services Configuration
# =============================================================================

enable_communication_services = true
enable_pubsub_queues          = true # Enable for production

# =============================================================================
# GitHub ARC Configuration
# =============================================================================
# Enable for production to have self-hosted runners
# =============================================================================

enable_github_arc = true

# github_app_id              = ""  # Set via TF_VAR_github_app_id
# github_app_installation_id = ""  # Set via TF_VAR_github_app_installation_id
# github_app_private_key     = ""  # Set via TF_VAR_github_app_private_key

runner_scale_sets = [
  {
    name              = "tesserix-runner"
    github_config_url = "https://github.com/tesserix"
    min_runners       = 1  # 1 warm runner always ready (scales up on demand)
    max_runners       = 15 # Up to 15 concurrent jobs
    runner_group      = "default"
    runner_image      = "ghcr.io/actions/actions-runner:latest" # Switch to custom ghcr.io/tesserix/arc-runner:latest once built
    resources = {
      limits = {
        cpu    = "3500m"
        memory = "8Gi"
      }
      requests = {
        cpu    = "500m"
        memory = "512Mi"
      }
    }
    node_selector = {} # Run on existing optimized pool (no dedicated CI nodes)
    tolerations   = []
  }
]

# =============================================================================
# NOTE: Cloud Run stack (10-cloud-run) has been removed.
# All services run on GKE.
# =============================================================================

# =============================================================================
# Identity Platform Configuration (Stack 11)
# =============================================================================
# Multi-tenant user authentication with Google Identity Platform.
# Per-product tenants provide user pool isolation between products.
# Tenants are free — cost is per MAU, not per tenant.
#
# OAuth clients are created in GCP Console (Credentials page), not here.
# Authorized domains are project-level and cover all tenants.
# =============================================================================

enable_identity_platform = true

authorized_domains = [
  "tesserix.app",
  "tesseracthub.app",
  "mark8ly.com",
  "localhost",
]

allow_duplicate_emails = false

identity_platform_tenants = [
  # Platform super-admins who manage the entire Tesserix platform
  {
    name                  = "Platform"
    display_name          = "Platform"
    allow_password_signup = true
  },
  # Marketplace store admins, staff, and onboarding users
  {
    name                  = "MP-Internal"
    display_name          = "MP-Internal"
    allow_password_signup = true
  },
  # Marketplace storefront end-users (shoppers)
  {
    name                  = "MP-Customer"
    display_name          = "MP-Customer"
    allow_password_signup = true
  }
]

# =============================================================================
# 12-vertex — Vertex AI private access (PSC + DNS pinning + gateway IAM)
# =============================================================================
vertex_psc_address_name = "vertex-psc-ip"
vertex_psc_ip           = "10.255.0.2"
vertex_psc_rule_name    = "vertexapis"
vertex_dns_zone_name    = "vertex-aiplatform"
devai_workload_sa_email = "app-secrets-devai-prod@tesseracthub-480811.iam.gserviceaccount.com"
agentgateway_ksa        = "agentgateway-system/agentgateway"
kora_agentgateway_ksa   = "agentgateway-system/kora-ai"
devai_agentgateway_ksa  = "agentgateway-system/ai-gateway"
