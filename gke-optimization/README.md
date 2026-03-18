# GKE Cluster Optimization Guide

## Current State Analysis

### Cluster: tesseract-devtest-gke
- **Region:** australia-southeast1
- **Nodes:** 6 x e2-standard-4 (4 vCPU, 16GB RAM)
- **Total Pods:** ~185
- **Resource Utilization:** 5-25% CPU, 28-39% Memory (actual)

### Problem
- Pods over-request resources by 5-10x
- 6 small nodes have higher overhead than fewer large nodes
- VPA not installed for automatic resource optimization
- Max 110 pods/node limits density

## Recommended Architecture

### Node Configuration
```
Instance Type: e2-standard-8 (8 vCPU, 32GB RAM)
Min Nodes: 2
Max Nodes: 4
Max Pods per Node: 110 (can be increased with proper CIDR)
```

### Autoscaling Strategy
1. **Cluster Autoscaler** - Scale nodes based on pending pods
2. **VPA (Vertical Pod Autoscaler)** - Right-size pod resources
3. **HPA (Horizontal Pod Autoscaler)** - Scale replicas based on load

## Implementation Steps

### Step 1: Install VPA
```bash
# Enable VPA on GKE
gcloud container clusters update tesseract-devtest-gke \
  --enable-vertical-pod-autoscaling \
  --region australia-southeast1
```

### Step 2: Create New Node Pool
```bash
# Create optimized node pool
gcloud container node-pools create optimized-pool \
  --cluster=tesseract-devtest-gke \
  --region=australia-southeast1 \
  --machine-type=e2-standard-8 \
  --num-nodes=2 \
  --min-nodes=2 \
  --max-nodes=4 \
  --enable-autoscaling \
  --max-pods-per-node=110 \
  --disk-size=100GB \
  --disk-type=pd-ssd \
  --node-labels=workload=production
```

### Step 3: Migrate Workloads
```bash
# Cordon old nodes
kubectl cordon -l cloud.google.com/gke-nodepool=default

# Drain old nodes (one at a time)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
```

### Step 4: Delete Old Node Pool
```bash
gcloud container node-pools delete default \
  --cluster=tesseract-devtest-gke \
  --region=australia-southeast1
```

## Cost Savings
- Current: 6 x e2-standard-4 = ~$720/month
- Optimized: 2-4 x e2-standard-8 = ~$360-720/month
- Potential savings: 25-50%
