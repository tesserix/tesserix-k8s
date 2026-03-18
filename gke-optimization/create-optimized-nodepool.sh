#!/bin/bash
# =============================================================================
# Create Optimized Node Pool for Production
# =============================================================================
# This script creates a new node pool with larger, more efficient nodes
# and migrates workloads from the old pool.
# =============================================================================

set -e

CLUSTER_NAME="tesseract-devtest-gke"
REGION="australia-southeast1"
PROJECT_ID="tesseracthub-480811"
NEW_POOL_NAME="optimized-pool"
OLD_POOL_NAME="default"

# Configuration for optimized nodes
MACHINE_TYPE="e2-standard-8"  # 8 vCPU, 32GB RAM
MIN_NODES=2
MAX_NODES=4
MAX_PODS_PER_NODE=110
DISK_SIZE="100GB"
DISK_TYPE="pd-ssd"

echo "=============================================="
echo "GKE Optimized Node Pool Creation"
echo "=============================================="
echo "Cluster: $CLUSTER_NAME"
echo "Region: $REGION"
echo "Machine Type: $MACHINE_TYPE"
echo "Nodes: $MIN_NODES (min) - $MAX_NODES (max)"
echo "=============================================="
echo ""

# Step 1: Create new optimized node pool
echo "[Step 1] Creating new optimized node pool..."
gcloud container node-pools create $NEW_POOL_NAME \
  --cluster=$CLUSTER_NAME \
  --region=$REGION \
  --project=$PROJECT_ID \
  --machine-type=$MACHINE_TYPE \
  --num-nodes=$MIN_NODES \
  --min-nodes=$MIN_NODES \
  --max-nodes=$MAX_NODES \
  --enable-autoscaling \
  --max-pods-per-node=$MAX_PODS_PER_NODE \
  --disk-size=$DISK_SIZE \
  --disk-type=$DISK_TYPE \
  --node-labels=workload=production,optimized=true \
  --node-taints="" \
  --metadata=disable-legacy-endpoints=true \
  --shielded-secure-boot \
  --shielded-integrity-monitoring

echo "New node pool created successfully!"
echo ""

# Step 2: Wait for new nodes to be ready
echo "[Step 2] Waiting for new nodes to be ready..."
sleep 60

kubectl get nodes -l cloud.google.com/gke-nodepool=$NEW_POOL_NAME

echo ""
echo "=============================================="
echo "Node Pool Created Successfully!"
echo "=============================================="
echo ""
echo "Next steps to migrate workloads:"
echo ""
echo "1. Cordon old nodes:"
echo "   kubectl cordon -l cloud.google.com/gke-nodepool=$OLD_POOL_NAME"
echo ""
echo "2. Drain old nodes one by one:"
echo "   kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data"
echo ""
echo "3. Delete old node pool:"
echo "   gcloud container node-pools delete $OLD_POOL_NAME \\"
echo "     --cluster=$CLUSTER_NAME --region=$REGION"
echo ""
echo "=============================================="
