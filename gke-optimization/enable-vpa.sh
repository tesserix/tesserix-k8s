#!/bin/bash
# =============================================================================
# Enable VPA on GKE and Apply Configurations
# =============================================================================

set -e

CLUSTER_NAME="tesseract-devtest-gke"
REGION="australia-southeast1"
PROJECT_ID="tesseracthub-480811"

echo "==================================="
echo "GKE VPA Enablement Script"
echo "==================================="

# Step 1: Enable VPA on GKE cluster
echo ""
echo "[Step 1] Enabling Vertical Pod Autoscaler on GKE..."
gcloud container clusters update $CLUSTER_NAME \
  --enable-vertical-pod-autoscaling \
  --region $REGION \
  --project $PROJECT_ID

echo "VPA enabled successfully!"

# Step 2: Wait for VPA to be ready
echo ""
echo "[Step 2] Waiting for VPA components to be ready..."
sleep 30

# Check VPA pods
kubectl get pods -n kube-system | grep vpa

# Step 3: Apply VPA configurations
echo ""
echo "[Step 3] Applying VPA configurations..."
kubectl apply -f vpa-configs.yaml

echo ""
echo "==================================="
echo "VPA Setup Complete!"
echo "==================================="
echo ""
echo "To check VPA recommendations:"
echo "  kubectl get vpa -n devtest"
echo ""
echo "To see detailed recommendations:"
echo "  kubectl describe vpa <vpa-name> -n devtest"
