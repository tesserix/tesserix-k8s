# TesseractHub Terraform Infrastructure (Refactored)

Production-ready Terraform infrastructure for the TesseractHub platform with separate state files per stack for better isolation and debugging.

## Project Information

- **Project Name:** TesseractHub
- **Project ID:** tesseracthub-480811
- **Project Number:** 480811
- **Admin User:** unidevidp@gmail.com

**Note:** All environments (devtest, pilot, prod) now use the same GCP project: `tesseracthub-480811`

## Architecture

```
terraform-new/
├── dependencies.yaml           # Dependency graph and orchestration config
├── Makefile                    # Build automation
├── README.md                   # This file
├── scripts/
│   └── orchestrator.sh         # Stack orchestration script
├── environments/
│   └── prod/
│       └── terraform.tfvars    # Production configuration
└── stacks/
    ├── 01-foundation/          # GCP APIs
    ├── 02-network/             # VPC, Subnets, Firewall, NAT
    ├── 03-storage/             # Buckets, Secrets, KMS
    ├── 04-gke/                 # GKE Cluster
    ├── 05-k8s-bootstrap/       # Kong, Cert-Manager, ArgoCD, External Secrets
    ├── 06-workload-identity/   # Service Accounts, WI Bindings
    ├── 07-app-secrets/         # Application Secrets
    ├── 08-communication-services/ # Email, SMS, Push
    └── 09-github-arc/          # GitHub Actions Runners
```

## Stack Dependencies

```
01-foundation (no dependencies)
     │
     ├──────────────┬────────────────────┐
     ▼              ▼                    ▼
02-network    03-storage    08-communication-services
     │
     ▼
04-gke
     │
     ├──────────────┐
     ▼              ▼
05-k8s-bootstrap  06-workload-identity
     │                    │
     │                    ▼
     │              07-app-secrets
     ▼
09-github-arc
```

## Quick Start

### Prerequisites

1. **Install required tools:**
   ```bash
   # Terraform
   brew install terraform

   # Google Cloud SDK
   brew install google-cloud-sdk

   # yq and jq (for orchestrator)
   brew install yq jq
   ```

2. **Authenticate with GCP:**
   ```bash
   gcloud auth login
   gcloud auth application-default login
   gcloud config set project tesseracthub-480811
   ```

### Bootstrap (First Time Setup)

1. **Create the state bucket:**
   ```bash
   make bootstrap
   ```

2. **Deploy all stacks:**
   ```bash
   make all
   ```

### Individual Stack Operations

```bash
# Initialize a single stack
make init-01-foundation

# Plan a single stack
make plan-04-gke

# Apply a single stack
make apply-02-network

# Destroy a single stack
make destroy-09-github-arc
```

### Full Deployment

```bash
# Plan all stacks
make plan

# Apply all stacks (in dependency order)
make apply

# Destroy all stacks (in reverse order)
make destroy
```

## State Management

Each stack has its own state file stored in GCS:

| Stack | State Prefix |
|-------|-------------|
| 01-foundation | `stacks/prod/foundation` |
| 02-network | `stacks/prod/network` |
| 03-storage | `stacks/prod/storage` |
| 04-gke | `stacks/prod/gke` |
| 05-k8s-bootstrap | `stacks/prod/k8s-bootstrap` |
| 06-workload-identity | `stacks/prod/workload-identity` |
| 07-app-secrets | `stacks/prod/app-secrets` |
| 08-communication-services | `stacks/prod/communication-services` |
| 09-github-arc | `stacks/prod/github-arc` |

**State Bucket:** `tesseract-terraform-states`

## Cross-Stack References

Stacks reference outputs from dependent stacks using `terraform_remote_state`:

```hcl
data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "stacks/${var.environment}/network"
  }
}

# Use outputs from network stack
resource "google_container_cluster" "primary" {
  network    = data.terraform_remote_state.network.outputs.vpc_name
  subnetwork = data.terraform_remote_state.network.outputs.subnet_name
  # ...
}
```

## Environment Configuration

Configuration is managed in `environments/prod/terraform.tfvars`. Sensitive values should be set via environment variables:

```bash
# Required for Cert-Manager (Let's Encrypt)
export TF_VAR_cloudflare_api_token="your-cloudflare-token"
export TF_VAR_cloudflare_domain="tesseracthub.app"
export TF_VAR_letsencrypt_email="admin@tesseracthub.app"

# Required for ArgoCD
export TF_VAR_argocd_hostname="argocd.tesseracthub.app"

# Optional: ArgoCD SSO
export TF_VAR_google_oauth_client_id="your-oauth-client-id"
export TF_VAR_google_oauth_client_secret="your-oauth-client-secret"

# Optional: GitHub ARC
export TF_VAR_github_app_id="your-app-id"
export TF_VAR_github_app_installation_id="your-installation-id"
export TF_VAR_github_app_private_key="$(cat path/to/private-key.pem)"
```

## Common Operations

### View Dependency Graph

```bash
make deps
# or
./scripts/orchestrator.sh deps
```

### Validate All Configurations

```bash
make validate
```

### Clean Terraform Files

```bash
make clean
```

### Get kubectl Access

After deploying GKE:

```bash
gcloud container clusters get-credentials tesseract-prod-cluster \
  --region us-central1 \
  --project tesseracthub-480811
```

## Troubleshooting

### State Lock Issues

If a state is locked:

```bash
# List locked states
gsutil ls -l gs://tesseract-terraform-states/stacks/prod/*/default.tfstate

# Force unlock (use with caution!)
cd stacks/<stack-name>
terraform force-unlock <lock-id>
```

### Dependency Failures

If a stack fails due to missing dependencies:

1. Check that dependent stacks have been applied
2. Verify state files exist in GCS
3. Run the stack initialization again

### GKE Connection Issues

If k8s-bootstrap or github-arc fail to connect to GKE:

```bash
# Refresh credentials
gcloud container clusters get-credentials tesseract-prod-cluster \
  --region us-central1 \
  --project tesseracthub-480811

# Verify connection
kubectl cluster-info
```

## Security Best Practices

1. **Restrict master_authorized_networks** - Change `0.0.0.0/0` to specific CIDR ranges
2. **Enable ArgoCD SSO** - Configure Google OAuth for production
3. **Use CMEK** - Customer-managed encryption keys are enabled by default
4. **Limit IAM permissions** - Review and restrict workload identity bindings
5. **Enable deletion protection** - Already enabled for GKE cluster

## Cost Optimization

The configuration includes several cost optimizations:

- NAT Gateway uses STANDARD tier (not PREMIUM)
- VPC Flow Logs disabled by default
- Logging/Monitoring can be disabled for non-production
- Lifecycle rules for storage class transitions
- Node pools with autoscaling

## Migration from Old Terraform

To migrate resources from the old terraform directory:

1. Export existing resource IDs
2. Update terraform.tfvars with matching configuration
3. Import resources into new state files:
   ```bash
   cd stacks/02-network
   terraform import google_compute_network.vpc projects/tesseracthub-480811/global/networks/tesseract-prod-vpc
   ```

## Support

For issues or questions, contact: samyak.rout@gmail.com
