#!/usr/bin/env bash
# =============================================================================
# BOOTSTRAP: First-time GKE cluster setup
# =============================================================================
# Run after terraform apply of 05-gke and 06-k8s-bootstrap.
# This script applies K8s manifests that aren't managed by ArgoCD/Terraform.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-tesserix-gke}"
REGION="${REGION:-asia-south1}"
PROJECT="${PROJECT:-tesserix}"

echo "=== Tesserix GKE Bootstrap ==="
echo "Cluster: $CLUSTER_NAME | Region: $REGION | Project: $PROJECT"
echo ""

# 1. Get cluster credentials
echo "--- Getting cluster credentials ---"
gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION" --project "$PROJECT"

# 2. Verify cluster access
echo "--- Verifying cluster access ---"
kubectl cluster-info
kubectl get nodes

# 3. Apply namespaces (should already exist from Terraform, but idempotent)
echo "--- Ensuring namespaces ---"
for ns in tesserix shared marketplace ingress monitoring argocd; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# 4. Apply cluster config (Istio policies, network policies, cloudflared)
echo "--- Applying cluster config ---"
kubectl apply -R -f "$REPO_ROOT/k8s/cluster/"

# 5. Apply ArgoCD bootstrap (app-of-apps)
echo "--- Applying ArgoCD bootstrap ---"
kubectl apply -f "$REPO_ROOT/k8s/argocd/projects/"
kubectl apply -f "$REPO_ROOT/k8s/argocd/bootstrap.yaml"

# 7. Verify ArgoCD apps
echo "--- Waiting for ArgoCD apps to sync ---"
sleep 10
kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD applications not yet available"

echo ""
echo "=== Bootstrap complete ==="
echo ""
echo "Next steps:"
echo "  1. Configure ArgoCD repo credentials: kubectl -n argocd create secret generic repo-creds ..."
echo "  2. Configure Cloudflare tunnel credentials in GCP Secret Manager"
echo "  3. Push service images to GHCR"
echo "  4. Monitor: kubectl get ksvc -A"
