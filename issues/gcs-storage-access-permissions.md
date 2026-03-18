# GCS Storage Access Permissions Fix

## Issue Summary

**Error**: `app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com does not have storage.buckets.get access to the Google Cloud Storage bucket`

**Root Cause**: The `app-secrets-marketplace` service account (used by most marketplace services) only had Secret Manager access permissions but not Google Cloud Storage access.

## Affected Services

Most marketplace services use the shared `app-secrets-marketplace` service account via Workload Identity:
- admin
- products-service
- categories-service
- orders-service
- customers-service
- inventory-service
- vendor-service
- ... and 25+ other services

Only `document-service` had its own dedicated SA (`document-service-sa`) with proper GCS permissions.

## Resolution

### Permissions Granted

Added the following IAM roles to `app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com` on GCS buckets:

| Bucket | Role | Permissions |
|--------|------|-------------|
| tesseracthub-devtest-assets | roles/storage.objectAdmin | Full object CRUD operations |
| tesseracthub-devtest-assets | roles/storage.legacyBucketReader | storage.buckets.get, storage.buckets.list |
| tesseracthub-devtest-backups | roles/storage.objectAdmin | Full object CRUD operations |
| tesseracthub-devtest-backups | roles/storage.legacyBucketReader | storage.buckets.get, storage.buckets.list |

### Commands Executed

```bash
# Grant object admin permissions on assets bucket
gcloud storage buckets add-iam-policy-binding gs://tesseracthub-devtest-assets \
  --member="serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

# Grant bucket reader for buckets.get permission on assets bucket
gcloud storage buckets add-iam-policy-binding gs://tesseracthub-devtest-assets \
  --member="serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com" \
  --role="roles/storage.legacyBucketReader"

# Grant same permissions on backups bucket
gcloud storage buckets add-iam-policy-binding gs://tesseracthub-devtest-backups \
  --member="serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gcloud storage buckets add-iam-policy-binding gs://tesseracthub-devtest-backups \
  --member="serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com" \
  --role="roles/storage.legacyBucketReader"
```

## Current IAM Policy

### tesseracthub-devtest-assets Bucket

| Service Account | Roles |
|-----------------|-------|
| app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com | storage.objectAdmin, storage.legacyBucketReader |
| document-service-sa@tesseracthub-480811.iam.gserviceaccount.com | storage.objectAdmin, storage.legacyBucketReader |
| tenant-onboarding-sa@tesseracthub-480811.iam.gserviceaccount.com | storage.objectAdmin, storage.legacyBucketReader |

## Architecture

### Workload Identity Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GKE Cluster (devtest)                        │
├─────────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │                   marketplace namespace                      │    │
│  │                                                              │    │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │    │
│  │  │ admin        │  │ products-svc │  │ document-service │   │    │
│  │  │              │  │              │  │                  │   │    │
│  │  │ K8s SA:      │  │ K8s SA:      │  │ K8s SA:          │   │    │
│  │  │ admin        │  │ products-svc │  │ document-service │   │    │
│  │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘   │    │
│  │         │                 │                    │              │    │
│  └─────────┼─────────────────┼────────────────────┼──────────────┘    │
│            │                 │                    │                   │
│   ┌────────▼─────────────────▼────────┐  ┌───────▼───────────┐       │
│   │  app-secrets-marketplace@gcp.sa   │  │ document-service-sa│       │
│   │  (Workload Identity)              │  │ (Workload Identity)│       │
│   └────────────────┬──────────────────┘  └─────────┬─────────┘       │
└────────────────────┼────────────────────────────────┼─────────────────┘
                     │                                │
                     ▼                                ▼
              ┌──────────────────────────────────────────┐
              │        Google Cloud Storage               │
              │  ┌────────────────────────────────────┐  │
              │  │   tesseracthub-devtest-assets      │  │
              │  │   tesseracthub-devtest-backups     │  │
              │  └────────────────────────────────────┘  │
              └──────────────────────────────────────────┘
```

### Service Account Mapping

| K8s Service Account | GCP Service Account | GCS Access |
|---------------------|---------------------|------------|
| marketplace/admin | app-secrets-marketplace | Yes (after fix) |
| marketplace/products-service | app-secrets-marketplace | Yes (after fix) |
| marketplace/document-service | document-service-sa | Yes (dedicated SA) |
| marketplace/tenant-service | app-secrets-marketplace | Yes (after fix) |
| marketplace/* (others) | app-secrets-marketplace | Yes (after fix) |

## Production Checklist

- [x] Grant GCS permissions to app-secrets-marketplace SA on devtest buckets
- [x] Add IAM bindings to Terraform configuration
- [x] Create region-specific marketplace buckets (AU, IN)
- [ ] Run `terraform apply` to create new regional buckets
- [ ] Verify document upload/download works in admin panel
- [ ] Grant same permissions on production buckets when ready

---

# Part 2: Terraform Configuration

## Regional Bucket Strategy

For data residency and performance, marketplace now uses region-specific buckets:

| Bucket Name | Region | Purpose |
|-------------|--------|---------|
| `tesseracthub-devtest-assets` | australia-southeast1 | Legacy/shared assets |
| `marketplace-devtest-assets-au` | australia-southeast1 | AU tenant assets |
| `marketplace-devtest-assets-in` | asia-south1 | IN tenant assets |

## Terraform Changes

### File: `terraform/configs/devtest/terraform.tfvars`

Added IAM bindings to existing buckets:
```hcl
{
  name = "tesseracthub-devtest-assets"
  # ... existing config ...
  iam_bindings = [
    {
      role   = "roles/storage.objectAdmin"
      member = "serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com"
    },
    {
      role   = "roles/storage.legacyBucketReader"
      member = "serviceAccount:app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com"
    }
  ]
}
```

Added new regional buckets for marketplace:
```hcl
# Australia (AU) - australia-southeast1
{
  name     = "marketplace-devtest-assets-au"
  location = "australia-southeast1"
  labels = {
    purpose = "assets"
    product = "marketplace"
    region  = "au"
  }
  iam_bindings = [
    # app-secrets-marketplace SA (used by most marketplace services)
    { role = "roles/storage.objectAdmin", member = "serviceAccount:app-secrets-marketplace@..." },
    { role = "roles/storage.legacyBucketReader", member = "serviceAccount:app-secrets-marketplace@..." },
    # document-service-sa (dedicated document service SA)
    { role = "roles/storage.objectAdmin", member = "serviceAccount:document-service-sa@..." },
    { role = "roles/storage.legacyBucketReader", member = "serviceAccount:document-service-sa@..." }
  ]
}

# India (IN) - asia-south1
{
  name     = "marketplace-devtest-assets-in"
  location = "asia-south1"
  # ... similar config ...
}
```

## Apply Terraform Changes

```bash
cd terraform

# Initialize
terraform init

# Plan changes for devtest
terraform plan -var-file=configs/devtest/terraform.tfvars

# Apply changes
terraform apply -var-file=configs/devtest/terraform.tfvars
```

## Document Service Configuration

Update document-service to select bucket based on tenant region:

```yaml
# charts/apps/document-service/values.yaml
env:
  STORAGE_PROVIDER: "gcp"
  STORAGE_DEFAULT_BUCKET: "tesseracthub-devtest-assets"
  STORAGE_BUCKET_AU: "marketplace-devtest-assets-au"
  STORAGE_BUCKET_IN: "marketplace-devtest-assets-in"
  GOOGLE_CLOUD_PROJECT: "tesseracthub-480811"
```

## Production Setup

For production, add similar buckets with stricter lifecycle rules:

```hcl
# terraform/configs/prod/terraform.tfvars
{
  name                        = "marketplace-prod-assets-au"
  location                    = "australia-southeast1"
  storage_class               = "STANDARD"
  force_destroy               = false  # NEVER force destroy in prod
  uniform_bucket_level_access = true
  versioning                  = true   # Enable versioning in prod
  labels = {
    purpose  = "assets"
    product  = "marketplace"
    region   = "au"
    critical = "true"
  }
  lifecycle_rules = [
    {
      action = { type = "SetStorageClass", storage_class = "NEARLINE" }
      condition = { age = 90 }
    },
    {
      action = { type = "SetStorageClass", storage_class = "COLDLINE" }
      condition = { age = 365 }
    }
  ]
  iam_bindings = [
    { role = "roles/storage.objectAdmin", member = "serviceAccount:app-secrets-marketplace@..." },
    { role = "roles/storage.legacyBucketReader", member = "serviceAccount:app-secrets-marketplace@..." }
  ]
}
```

## Troubleshooting

### Verify Permissions
```bash
# Check bucket IAM policy
gcloud storage buckets get-iam-policy gs://tesseracthub-devtest-assets --format=yaml

# Test access from a pod using the SA
kubectl run gcs-test --rm -it --restart=Never \
  --image=google/cloud-sdk:alpine \
  --serviceaccount=admin \
  -n marketplace \
  -- gsutil ls gs://tesseracthub-devtest-assets/
```

### Check Workload Identity Binding
```bash
# Verify K8s SA annotation
kubectl get sa admin -n marketplace -o yaml | grep iam.gke.io

# Check GCP SA has workload identity binding
gcloud iam service-accounts get-iam-policy \
  app-secrets-marketplace@tesseracthub-480811.iam.gserviceaccount.com
```

---

# Part 3: Dynamic Configuration (Production Ready)

## Dynamic Terraform Variables

Terraform now uses dynamic variable interpolation to avoid hardcoded values:

### Service Account Configuration
```hcl
# terraform/configs/devtest/terraform.tfvars
marketplace_gcs_service_accounts = [
  {
    name  = "app-secrets-marketplace"
    roles = ["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]
  },
  {
    name  = "document-service-sa"
    roles = ["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]
  },
  {
    name  = "tenant-onboarding-sa"
    roles = ["roles/storage.objectAdmin", "roles/storage.legacyBucketReader"]
  }
]

# SA emails are constructed dynamically: {name}@{project_id}.iam.gserviceaccount.com
```

### Regional Bucket Configuration
```hcl
# terraform/configs/devtest/terraform.tfvars
marketplace_regional_buckets = [
  {
    region_code   = "au"
    gcs_location  = "australia-southeast1"
    storage_class = "STANDARD"
    force_destroy = true  # DevTest only
    versioning    = false
  },
  {
    region_code   = "in"
    gcs_location  = "asia-south1"
    storage_class = "STANDARD"
    force_destroy = true
    versioning    = false
  }
]

# Bucket names generated: marketplace-{environment}-assets-{region_code}
```

### main.tf Locals (Dynamic Generation)
```hcl
locals {
  # Construct full SA emails dynamically
  marketplace_gcs_iam_bindings = flatten([
    for sa in var.marketplace_gcs_service_accounts : [
      for role in sa.roles : {
        role   = role
        member = "serviceAccount:${sa.name}@${var.project_id}.iam.gserviceaccount.com"
      }
    ]
  ])

  # Generate regional bucket configs
  marketplace_regional_bucket_configs = [
    for region in var.marketplace_regional_buckets : {
      name     = "marketplace-${var.environment}-assets-${region.region_code}"
      location = region.gcs_location
      # ... IAM bindings from marketplace_gcs_iam_bindings
    }
  ]

  # Combine with user-defined buckets
  all_buckets = concat(var.buckets, local.marketplace_regional_bucket_configs)
}
```

## Document Service Dynamic Bucket Selection

The document-service now supports dynamic bucket selection based on tenant region:

### Environment Variables
```yaml
# charts/apps/document-service/values.yaml
env:
  # Default bucket (fallback)
  STORAGE_DEFAULT_BUCKET: "tesseracthub-devtest-assets"

  # Regional buckets
  STORAGE_BUCKET_AU: "marketplace-devtest-assets-au"
  STORAGE_BUCKET_IN: "marketplace-devtest-assets-in"

  # Enable dynamic selection
  ENABLE_REGIONAL_BUCKETS: "true"
```

### Bucket Selection Logic
```
1. Request comes in with X-Region header (e.g., "AU", "IN")
2. document-service reads STORAGE_BUCKET_{REGION} env var
3. If region not recognized, falls back to STORAGE_DEFAULT_BUCKET
4. All operations use the selected bucket
```

## Production Configuration

### terraform/configs/prod/terraform.tfvars
```hcl
marketplace_regional_buckets = [
  {
    region_code   = "au"
    gcs_location  = "australia-southeast1"
    storage_class = "STANDARD"
    force_destroy = false  # Never force destroy in prod!
    versioning    = true   # Enable versioning for compliance
  },
  {
    region_code   = "in"
    gcs_location  = "asia-south1"
    storage_class = "STANDARD"
    force_destroy = false
    versioning    = true
  }
]
```

## Related Issues

- Network Policies Cross-Namespace Access: `issues/network-policies-cross-namespace-access.md`
- PostgreSQL SSL Configuration: `issues/postgresql-ssl-configuration.md`

## Commits

1. `fix(iam): grant GCS access to app-secrets-marketplace service account`
2. `fix(terraform): dynamic bucket and IAM configuration`
3. `feat(document-service): add regional bucket selection`

---

*Last Updated: 2026-01-08*
