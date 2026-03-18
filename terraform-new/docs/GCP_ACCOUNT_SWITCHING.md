# GCP Account Switching Guide

This guide explains how to switch between DevTest and Production GCP environments for Tesseract infrastructure management.

## Account Overview

> **Note**: Both DevTest and Production environments now use the same GCP project (`tesseracthub-480811`) and account (`unidevidp@gmail.com`). They differ only in region and resource naming.

| Environment | Account | Project ID | Project Number | Region | Cluster |
|-------------|---------|------------|----------------|--------|---------|
| **DevTest** | unidevidp@gmail.com | tesseracthub-480811 | 480811 | australia-southeast1 | tesseract-devtest-gke (regional) |
| **Production** | unidevidp@gmail.com | tesseracthub-480811 | 480811 | asia-south1 | tesseract-prod-in-gke (regional) |

## Quick Reference

```bash
# Switch to DevTest (default)
gcloud config configurations activate devtest

# Switch to Production
gcloud config configurations activate prod

# Check current configuration
gcloud config configurations list

# Show current account details
gcloud config list
```

## Detailed Commands

### Check Current Configuration

```bash
# List all configurations (shows which is active)
gcloud config configurations list

# Output example:
# NAME     IS_ACTIVE  ACCOUNT                PROJECT              REGION
# devtest  True       unidevidp@gmail.com    tesseracthub-480811  australia-southeast1
# prod     False      unidevidp@gmail.com  tesseracthub-480811  asia-south1
```

### Switch to DevTest

```bash
gcloud config configurations activate devtest

# Verify
gcloud config list --format="table(core.account,core.project,compute.region)"
```

### Switch to Production

```bash
gcloud config configurations activate prod

# Verify
gcloud config list --format="table(core.account,core.project,compute.region)"
```

## Shell Aliases (Recommended)

Add these aliases to your `~/.zshrc` or `~/.bashrc` for quick switching:

```bash
# GCP Account Switching
alias gcp-dev='gcloud config configurations activate devtest && echo "✓ Switched to DevTest (tesseracthub-480811)"'
alias gcp-prod='gcloud config configurations activate prod && echo "✓ Switched to Production (tesseracthub-480811)"'
alias gcp-status='gcloud config configurations list'
alias gcp-whoami='echo "Account: $(gcloud config get-value account)" && echo "Project: $(gcloud config get-value project)" && echo "Region: $(gcloud config get-value compute/region)"'
```

Apply the changes:

```bash
source ~/.zshrc  # or source ~/.bashrc
```

Then use:

```bash
gcp-dev      # Switch to DevTest
gcp-prod     # Switch to Production
gcp-status   # Show all configurations
gcp-whoami   # Show current account details
```

## Using the Helper Script

A helper script is available at `terraform-new/scripts/gcp-switch.sh`:

```bash
# From the project root
cd /path/to/tesserix-k8s

# Show current status
source ./terraform-new/scripts/gcp-switch.sh status

# Switch to DevTest
source ./terraform-new/scripts/gcp-switch.sh devtest

# Switch to Production
source ./terraform-new/scripts/gcp-switch.sh prod

# Login to current configuration
source ./terraform-new/scripts/gcp-switch.sh login
```

## Terraform Usage

When running Terraform commands, ensure you're using the correct configuration:

### For DevTest

```bash
# Switch to devtest
gcloud config configurations activate devtest

# Run Terraform
cd terraform-new
make plan-04-gke ENVIRONMENT=devtest PROJECT_ID=tesseracthub-480811 STATE_BUCKET=tesseract-terraform-states
```

### For Production

```bash
# Switch to prod
gcloud config configurations activate prod

# Run Terraform
cd terraform-new
make plan-04-gke ENVIRONMENT=prod PROJECT_ID=tesseracthub-480811 STATE_BUCKET=tesseract-terraform-states
```

## Re-Authentication

If your authentication expires, re-authenticate with:

### DevTest

```bash
gcloud config configurations activate devtest
gcloud auth login unidevidp@gmail.com
gcloud auth application-default login
```

### Production

```bash
gcloud config configurations activate prod
gcloud auth login unidevidp@gmail.com
gcloud auth application-default login
```

## Troubleshooting

### "You do not currently have an active account selected"

```bash
# Check which configuration is active
gcloud config configurations list

# Re-authenticate
gcloud auth login
```

### "Permission denied" errors

Ensure you're using the correct configuration for the project:

```bash
# Check current project
gcloud config get-value project

# If wrong, switch configurations
gcloud config configurations activate <devtest|prod>
```

### Application Default Credentials mismatch

```bash
# Update ADC for current configuration
gcloud auth application-default login

# Set quota project
gcloud auth application-default set-quota-project $(gcloud config get-value project)
```

## GKE Cluster Switching (kubectl)

Separate kubeconfig files are maintained for each cluster to enable quick switching between environments.

### Kubeconfig Files

| File | Cluster | Region/Zone | Project |
|------|---------|-------------|---------|
| `~/.kube/gke-devtest` | tesseract-devtest-gke | australia-southeast1 (regional) | tesseracthub-480811 |
| `~/.kube/gke-prod` | tesseract-prod-in-gke | asia-south1 (regional) | tesseracthub-480811 |

### Shell Functions (in ~/.zshrc)

These functions switch the KUBECONFIG and display cluster information:

```bash
gke-devtest   # Switch to devtest cluster (default)
gke-prod      # Switch to prod cluster
gke-which     # Show current cluster and account
```

Example output:
```bash
❯ gke-prod
Switched to PROD cluster
  Cluster: tesseract-prod-in-gke
  Region:  asia-south1
  Project: tesseracthub-480811
  Account: unidevidp@gmail.com

❯ gke-devtest
Switched to DEVTEST cluster
  Cluster: tesseract-devtest-gke
  Region:  australia-southeast1
  Project: tesseracthub-480811
  Account: unidevidp@gmail.com
```

### Default Configuration

- **KUBECONFIG** defaults to `~/.kube/gke-devtest`
- New terminal sessions automatically connect to the DevTest cluster

### Manual KUBECONFIG Usage

If you prefer explicit control without the shell functions:

```bash
# DevTest
export KUBECONFIG=~/.kube/gke-devtest
gcloud config set account unidevidp@gmail.com

# Production
export KUBECONFIG=~/.kube/gke-prod
gcloud config set account unidevidp@gmail.com
```

### Refreshing Cluster Credentials

If credentials expire, refresh them:

```bash
# DevTest
gcloud config set account unidevidp@gmail.com
KUBECONFIG=~/.kube/gke-devtest gcloud container clusters get-credentials tesseract-devtest-gke \
  --region australia-southeast1 --project tesseracthub-480811

# Production
gcloud config set account unidevidp@gmail.com
KUBECONFIG=~/.kube/gke-prod gcloud container clusters get-credentials tesseract-prod-in-gke \
  --region asia-south1 --project tesseracthub-480811
```

### Verifying Connection

```bash
# Check current cluster
kubectl cluster-info

# Check nodes
kubectl get nodes
```

## Best Practices

1. **Always verify before running commands**: Run `gcp-status` or `gcloud config configurations list` before executing infrastructure commands.

2. **Use DevTest as default**: Keep DevTest as your active configuration to avoid accidental production changes.

3. **Double-check for Production**: Before any production changes, explicitly verify:
   ```bash
   gcloud config get-value project  # Should show "tesseracthub-480811"
   gke-which  # Should show PROD cluster
   ```

4. **Use environment-specific terminals**: Consider using separate terminal windows/tabs for each environment, with visual indicators (different colors/labels).

5. **Leverage Makefile targets**: The Makefile accepts `ENVIRONMENT` and `PROJECT_ID` parameters, making it explicit which environment you're targeting.

6. **Use gke-which before kubectl commands**: Always verify which cluster you're connected to before running kubectl commands, especially destructive ones.
