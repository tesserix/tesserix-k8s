# GitHub Workflow Integration Guide

This guide explains how to integrate GitHub Actions workflows with the Tesserix GCP projects using Workload Identity Federation (WIF).

## Overview

The infrastructure supports two environments with separate GCP projects:

| Environment | Project ID | Project Number | Region | State Bucket Location |
|-------------|------------|----------------|--------|----------------------|
| **devtest** | tesseracthub-480811 | 480811 | australia-southeast1 | australia-southeast1 |
| **prod** | tesseracthub-480811 | 480811 | asia-south1 (India) | australia-southeast1 |

## Authentication Method: Workload Identity Federation

We use **Workload Identity Federation (WIF)** instead of service account keys for these benefits:

- No long-lived credentials to manage or rotate
- Short-lived tokens (1 hour by default)
- Better audit trail in GCP
- GitHub's OIDC tokens provide identity verification

## Setup Steps

### Step 1: Run the Setup Script

```bash
# For production (tesseracthub-480811 project)
./scripts/setup-gcp-wif.sh prod

# For devtest (tesseracthub project)
./scripts/setup-gcp-wif.sh devtest
```

The script will:
1. Enable required GCP APIs
2. Create Workload Identity Pool (`github-pool`)
3. Create OIDC Provider (`github-provider`)
4. Create service account (`github-actions@<project>.iam.gserviceaccount.com`)
5. Bind the service account to WIF
6. Grant necessary IAM roles

### Step 2: Configure GitHub Secrets

Add the following secrets to your GitHub repository:

**For Production (tesseracthub-480811):**

| Secret Name | Value |
|-------------|-------|
| `GCP_PROD_PROJECT_ID` | `tesseracthub-480811` |
| `GCP_PROD_WIF_PROVIDER` | `projects/849928263410/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_PROD_WIF_SA_EMAIL` | `github-actions@tesseracthub-480811.iam.gserviceaccount.com` |

**For DevTest (tesseracthub):**

| Secret Name | Value |
|-------------|-------|
| `GCP_DEVTEST_PROJECT_ID` | `tesseracthub-480811` |
| `GCP_DEVTEST_WIF_PROVIDER` | `projects/tesseracthub-480811/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `GCP_DEVTEST_WIF_SA_EMAIL` | `github-actions@tesseracthub-480811.iam.gserviceaccount.com` |

**Common Secrets (already configured):**

| Secret Name | Description |
|-------------|-------------|
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token for DNS-01 challenge |
| `CLOUDFLARE_ZONE_ID` | Cloudflare zone ID for the domain |
| `LETSENCRYPT_EMAIL` | Email for Let's Encrypt notifications |
| `GOOGLE_OAUTH_CLIENT_ID` | OAuth client ID for ArgoCD SSO |
| `GOOGLE_OAUTH_CLIENT_SECRET` | OAuth client secret for ArgoCD SSO |
| `ARGOCD_GITHUB_APP_ID` | GitHub App ID for ArgoCD |
| `ARGOCD_GITHUB_APP_INSTALLATION_ID` | GitHub App installation ID |
| `ARGOCD_GITHUB_APP_PRIVATE_KEY` | GitHub App private key (PEM format) |

### Step 3: Update Repository Settings

1. Go to **Settings > Actions > General**
2. Under "Workflow permissions", ensure "Read and write permissions" is enabled
3. Enable "Allow GitHub Actions to create and approve pull requests" if needed

## Example Workflows

### Terraform Deployment Workflow

```yaml
# .github/workflows/terraform-deploy.yml
name: Terraform Deploy

on:
  push:
    branches: [main]
    paths:
      - 'terraform-new/**'
  pull_request:
    branches: [main]
    paths:
      - 'terraform-new/**'
  workflow_dispatch:
    inputs:
      environment:
        description: 'Environment to deploy'
        required: true
        default: 'prod'
        type: choice
        options:
          - prod
          - devtest
      stack:
        description: 'Stack to deploy (or "all")'
        required: true
        default: 'all'
        type: choice
        options:
          - all
          - 01-foundation
          - 02-network
          - 03-storage
          - 04-gke
          - 05-k8s-bootstrap
          - 06-workload-identity
          - 07-app-secrets
          - 08-communication-services
          - 09-github-arc

permissions:
  contents: read
  id-token: write  # Required for Workload Identity Federation

env:
  TF_VERSION: '1.6.0'
  ENVIRONMENT: ${{ github.event.inputs.environment || 'prod' }}

jobs:
  plan:
    runs-on: ubuntu-latest
    outputs:
      has_changes: ${{ steps.plan.outputs.has_changes }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Set GCP Variables
        id: gcp
        run: |
          if [[ "${{ env.ENVIRONMENT }}" == "prod" ]]; then
            echo "PROJECT_ID=${{ secrets.GCP_PROD_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_PROD_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_PROD_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          else
            echo "PROJECT_ID=${{ secrets.GCP_DEVTEST_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_DEVTEST_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_DEVTEST_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          fi

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ steps.gcp.outputs.WIF_PROVIDER }}
          service_account: ${{ steps.gcp.outputs.SA_EMAIL }}
          project_id: ${{ steps.gcp.outputs.PROJECT_ID }}

      - name: Setup gcloud CLI
        uses: google-github-actions/setup-gcloud@v2
        with:
          project_id: ${{ steps.gcp.outputs.PROJECT_ID }}

      - name: Terraform Plan
        id: plan
        run: |
          cd terraform-new
          make plan ENVIRONMENT=${{ env.ENVIRONMENT }} \
                    PROJECT_ID=${{ steps.gcp.outputs.PROJECT_ID }} \
                    STATE_BUCKET=${{ steps.gcp.outputs.STATE_BUCKET }}

  apply:
    needs: plan
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    environment: ${{ github.event.inputs.environment || 'prod' }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Set GCP Variables
        id: gcp
        run: |
          if [[ "${{ env.ENVIRONMENT }}" == "prod" ]]; then
            echo "PROJECT_ID=${{ secrets.GCP_PROD_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_PROD_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_PROD_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          else
            echo "PROJECT_ID=${{ secrets.GCP_DEVTEST_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_DEVTEST_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_DEVTEST_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          fi

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ steps.gcp.outputs.WIF_PROVIDER }}
          service_account: ${{ steps.gcp.outputs.SA_EMAIL }}
          project_id: ${{ steps.gcp.outputs.PROJECT_ID }}

      - name: Setup gcloud CLI
        uses: google-github-actions/setup-gcloud@v2
        with:
          project_id: ${{ steps.gcp.outputs.PROJECT_ID }}

      - name: Terraform Apply
        run: |
          cd terraform-new
          make apply ENVIRONMENT=${{ env.ENVIRONMENT }} \
                     PROJECT_ID=${{ steps.gcp.outputs.PROJECT_ID }} \
                     STATE_BUCKET=${{ steps.gcp.outputs.STATE_BUCKET }}
        env:
          TF_VAR_cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          TF_VAR_cloudflare_zone_id: ${{ secrets.CLOUDFLARE_ZONE_ID }}
          TF_VAR_letsencrypt_email: ${{ secrets.LETSENCRYPT_EMAIL }}
          TF_VAR_google_oauth_client_id: ${{ secrets.GOOGLE_OAUTH_CLIENT_ID }}
          TF_VAR_google_oauth_client_secret: ${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}
          TF_VAR_argocd_github_app_id: ${{ secrets.ARGOCD_GITHUB_APP_ID }}
          TF_VAR_argocd_github_app_installation_id: ${{ secrets.ARGOCD_GITHUB_APP_INSTALLATION_ID }}
          TF_VAR_argocd_github_app_private_key: ${{ secrets.ARGOCD_GITHUB_APP_PRIVATE_KEY }}
```

### Single Stack Deployment

```yaml
# .github/workflows/deploy-stack.yml
name: Deploy Stack

on:
  workflow_dispatch:
    inputs:
      environment:
        description: 'Target environment'
        required: true
        type: choice
        options:
          - prod
          - devtest
      stack:
        description: 'Stack to deploy'
        required: true
        type: choice
        options:
          - 01-foundation
          - 02-network
          - 03-storage
          - 04-gke
          - 05-k8s-bootstrap
          - 06-workload-identity
          - 07-app-secrets
          - 08-communication-services
          - 09-github-arc
      action:
        description: 'Terraform action'
        required: true
        type: choice
        options:
          - plan
          - apply
          - destroy

permissions:
  contents: read
  id-token: write

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: ${{ github.event.inputs.environment }}

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: '1.6.0'

      - name: Set GCP Variables
        id: gcp
        run: |
          if [[ "${{ github.event.inputs.environment }}" == "prod" ]]; then
            echo "PROJECT_ID=${{ secrets.GCP_PROD_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_PROD_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_PROD_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          else
            echo "PROJECT_ID=${{ secrets.GCP_DEVTEST_PROJECT_ID }}" >> $GITHUB_OUTPUT
            echo "WIF_PROVIDER=${{ secrets.GCP_DEVTEST_WIF_PROVIDER }}" >> $GITHUB_OUTPUT
            echo "SA_EMAIL=${{ secrets.GCP_DEVTEST_WIF_SA_EMAIL }}" >> $GITHUB_OUTPUT
            echo "STATE_BUCKET=tesseract-terraform-states" >> $GITHUB_OUTPUT
          fi

      - name: Authenticate to Google Cloud
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: ${{ steps.gcp.outputs.WIF_PROVIDER }}
          service_account: ${{ steps.gcp.outputs.SA_EMAIL }}

      - name: Run Terraform
        run: |
          cd terraform-new
          make ${{ github.event.inputs.action }}-${{ github.event.inputs.stack }} \
            ENVIRONMENT=${{ github.event.inputs.environment }} \
            PROJECT_ID=${{ steps.gcp.outputs.PROJECT_ID }} \
            STATE_BUCKET=${{ steps.gcp.outputs.STATE_BUCKET }}
```

## Multi-Region Deployment

The infrastructure supports multi-region deployment. To deploy to a different region:

### State File Structure

```
gs://tesseract-terraform-states/
├── stacks/
│   ├── prod/
│   │   ├── in/           # India region
│   │   │   ├── foundation/
│   │   │   ├── network/
│   │   │   ├── gke/
│   │   │   └── ...
│   │   └── au/           # Australia region (future)
│   │       ├── foundation/
│   │       ├── network/
│   │       └── ...
│   └── devtest/
│       └── au/           # Australia region
│           ├── foundation/
│           ├── network/
│           └── ...
```

### Region-Specific Workflow

```yaml
jobs:
  deploy:
    strategy:
      matrix:
        region: [in, au]  # Deploy to both regions

    steps:
      - name: Deploy to ${{ matrix.region }}
        run: |
          cd terraform-new
          make apply ENVIRONMENT=prod \
                     REGION=${{ matrix.region }} \
                     PROJECT_ID=${{ steps.gcp.outputs.PROJECT_ID }}
```

## Troubleshooting

### Authentication Errors

**Error: "Unable to authenticate"**

1. Verify the WIF provider configuration:
```bash
gcloud iam workload-identity-pools providers describe github-provider \
  --project=tesseracthub-480811 \
  --location=global \
  --workload-identity-pool=github-pool
```

2. Check attribute conditions match your repository:
```bash
# The condition should allow your repository owner
attribute.repository_owner == 'tesserix'
```

3. Verify service account has WIF binding:
```bash
gcloud iam service-accounts get-iam-policy \
  github-actions@tesseracthub-480811.iam.gserviceaccount.com \
  --project=tesseracthub-480811
```

### Permission Errors

**Error: "Permission denied"**

1. Verify service account has required roles:
```bash
gcloud projects get-iam-policy tesseracthub-480811 \
  --flatten="bindings[].members" \
  --filter="bindings.members:github-actions@tesseracthub-480811.iam.gserviceaccount.com" \
  --format="table(bindings.role)"
```

2. Required roles:
   - `roles/compute.admin`
   - `roles/container.admin`
   - `roles/iam.serviceAccountAdmin`
   - `roles/secretmanager.admin`
   - `roles/storage.admin`
   - `roles/cloudkms.admin`

### State Lock Issues

**Error: "Error acquiring the state lock"**

```bash
# Find and remove stale lock
gsutil ls -l gs://tesseract-terraform-states/stacks/prod/*/default.tfstate

# Force unlock (use with caution!)
cd terraform-new/stacks/<stack>
terraform force-unlock <lock-id>
```

## Security Best Practices

1. **Repository Restrictions**: Update WIF attribute conditions to restrict to specific repositories:
   ```
   assertion.repository == 'tesserix/tesserix-k8s'
   ```

2. **Branch Restrictions**: Add branch conditions for production:
   ```
   assertion.ref == 'refs/heads/main'
   ```

3. **Environment Protection**: Configure GitHub environment protection rules:
   - Require reviewers for production deployments
   - Restrict deployment branches
   - Add deployment wait timer

4. **Secret Rotation**: Rotate OAuth and API tokens periodically

5. **Audit Logging**: Enable GCP audit logs to track all API calls

## Support

For issues or questions:
- Check the troubleshooting section above
- Review GCP Cloud Logging for detailed error messages
- Contact: samyak.rout@gmail.com
