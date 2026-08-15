# Manual Kubernetes Work Documentation

This document records manual Kubernetes operations performed during cluster setup and configuration. These operations are typically one-time setup tasks or troubleshooting steps that may need to be repeated in case of cluster recreation.

## Kargo GHCR Credentials

Kargo requires credentials to access private container images from GHCR (GitHub Container Registry). The credentials must be created in the Kargo project namespace with specific labels.

### Create GHCR Image Credentials for Kargo

```bash
# Create the secret with regex pattern for image matching
kubectl create secret generic ghcr-image-creds \
  --namespace=tesseract-hub-devtest \
  --from-literal=repoURL='^ghcr\.io/tesserix/.*' \
  --from-literal=repoURLIsRegex='true' \
  --from-literal=username=tesserix \
  --from-literal=password='<GITHUB_PAT>' \
  --dry-run=client -o yaml | kubectl apply -f -

# Add the Kargo credential label
kubectl label secret ghcr-image-creds \
  --namespace=tesseract-hub-devtest \
  kargo.akuity.io/cred-type=image
```

**Important Notes:**
- The `repoURL` uses regex pattern `^ghcr\.io/tesserix/.*` to match all images under the organization
- `repoURLIsRegex: "true"` must be set for the pattern to work
- The `kargo.akuity.io/cred-type: image` label is required for Kargo to recognize it as image credentials

## Kargo Dex Configuration

The Kargo Dex GitHub connector requires specific configuration for organization group membership to work correctly.

### Key Configuration Points

1. **loadAllGroups vs orgs filter**: These are mutually exclusive
   - Using `loadAllGroups: true` will return all organization memberships as groups
   - The `orgs` filter restricts which orgs to check but prevents `loadAllGroups` from working
   - For full group membership, use `loadAllGroups: true` WITHOUT the `orgs` filter

2. **Current Working Configuration** (in `/tmp/kargo-values-upgrade.yaml`):

```yaml
api:
  oidc:
    enabled: true
    dex:
      enabled: true
      connectors:
      - id: github
        name: GitHub
        type: github
        config:
          clientID: <GITHUB_OAUTH_CLIENT_ID>
          clientSecret: $GITHUB_CLIENT_SECRET
          redirectURI: https://dev-kargo.tesserix.app/dex/callback
          # NOTE: loadAllGroups only works without orgs filter
          # This will return all org memberships as groups
          loadAllGroups: true
      env:
      - name: GITHUB_CLIENT_SECRET
        value: "<GITHUB_CLIENT_SECRET>"
```

### Restarting Dex After Config Changes

After updating Dex configuration, restart the Dex server:

```bash
# Patch the secret with new config (if updating directly)
kubectl patch secret kargo-dex-server -n kargo --type='json' \
  -p='[{"op": "replace", "path": "/data/config.yaml", "value": "<base64-encoded-config>"}]'

# Restart the Dex server
kubectl rollout restart deployment kargo-dex-server -n kargo
```

## Namespace Cleanup for Kargo Projects

When recreating Kargo projects, existing namespaces may cause conflicts.

### Issue: Namespace Already Exists

If you see this error:
```
namespace already exists and is not labeled as a Project namespace
```

### Solution: Delete and Recreate

```bash
# Delete the existing namespace
kubectl delete namespace tesseract-hub-devtest --wait=true

# Delete the ArgoCD application to allow clean recreation
kubectl delete application kargo-tesseract-hub-devtest -n argocd

# Re-apply the ArgoCD application
kubectl apply -f kargo/devtest/kargo-application.yaml
```

**Note**: This will delete all resources in the namespace. Use with caution in production.

## kubectl Cache Issues

Sometimes kubectl caches cause API errors.

### Issue: Invalid Character '<' Errors

If you see errors like:
```
invalid character '<' looking for beginning of value
```

### Solution: Clear kubectl Cache

```bash
rm -rf ~/.kube/cache
```

## ArgoCD Application Sync Issues

### Force Sync with Prune

```bash
argocd app sync <app-name> --prune --force
```

### Server-Side Apply for Complex Resources

If you encounter merge conflicts with ArgoCD, add to syncOptions:

```yaml
syncOptions:
  - ServerSideApply=true
```

## Environment Configuration

### KUBECONFIG Setup

```bash
export KUBECONFIG=~/.kube/marketplace-aks-cluster
```

### Verify Connection

```bash
kubectl cluster-info
kubectl get nodes
```

## Troubleshooting Commands

### Check Kargo Resources

```bash
# List all Kargo projects
kubectl get projects.kargo.akuity.io -A

# List all Warehouses and their status
kubectl get warehouses.kargo.akuity.io -n tesseract-hub-devtest

# List all Stages
kubectl get stages.kargo.akuity.io -n tesseract-hub-devtest

# List all Freights
kubectl get freights.kargo.akuity.io -n tesseract-hub-devtest

# Check Warehouse details
kubectl describe warehouse <warehouse-name> -n tesseract-hub-devtest
```

### Check ArgoCD Applications

```bash
# List all applications
kubectl get applications -n argocd

# Check app sync status
argocd app list

# Get detailed app info
argocd app get <app-name>
```
