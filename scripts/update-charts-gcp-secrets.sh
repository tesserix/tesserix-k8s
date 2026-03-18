#!/bin/bash
# =============================================================================
# Update Helm Charts for GCP Secret Manager Integration
# =============================================================================
# This script updates all app charts to:
# 1. Add common library dependency
# 2. Update serviceaccount.yaml with Workload Identity
# 3. Update deployment.yaml with GCP Secret Manager env vars
# 4. Add GCP configuration to values.yaml
# 5. Remove sealed-secret.yaml templates
# =============================================================================

CHARTS_DIR="/Users/samyakrout/Desktop/samyak-work/projects/tesserix-k8s/charts/apps"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "=========================================="
echo "GCP Secret Manager Chart Update Script"
echo "=========================================="

# Function to add common dependency to Chart.yaml
add_common_dependency() {
    local chart_yaml="$1"
    local chart_name=$(basename $(dirname "$chart_yaml"))

    # Check if dependency already exists
    if grep -q "name: common" "$chart_yaml" 2>/dev/null; then
        echo -e "${YELLOW}  [SKIP] common dependency already exists${NC}"
        return 0
    fi

    # Add dependency section if it doesn't exist
    if ! grep -q "^dependencies:" "$chart_yaml"; then
        echo "" >> "$chart_yaml"
        echo "dependencies:" >> "$chart_yaml"
        echo "  - name: common" >> "$chart_yaml"
        echo "    version: \"1.0.0\"" >> "$chart_yaml"
        echo "    repository: \"file://../../common\"" >> "$chart_yaml"
        echo -e "${GREEN}  [ADDED] common dependency${NC}"
    else
        # Append to existing dependencies
        sed -i '' '/^dependencies:/a\
  - name: common\
    version: "1.0.0"\
    repository: "file://../../common"
' "$chart_yaml"
        echo -e "${GREEN}  [ADDED] common dependency to existing section${NC}"
    fi
}

# Function to update serviceaccount.yaml with Workload Identity
update_serviceaccount() {
    local sa_file="$1"
    local chart_name="$2"

    if [ ! -f "$sa_file" ]; then
        echo -e "${YELLOW}  [SKIP] No serviceaccount.yaml${NC}"
        return 0
    fi

    # Check if already updated
    if grep -q "gcp.workloadIdentity" "$sa_file" 2>/dev/null; then
        echo -e "${YELLOW}  [SKIP] Already has Workload Identity${NC}"
        return 0
    fi

    # Create updated serviceaccount template
    cat > "$sa_file" << 'SAEOF'
{{- if .Values.serviceAccount.create -}}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "CHART_NAME.serviceAccountName" . }}
  labels:
    {{- include "CHART_NAME.labels" . | nindent 4 }}
  annotations:
    {{- if and .Values.gcp .Values.gcp.workloadIdentity .Values.gcp.workloadIdentity.enabled }}
    iam.gke.io/gcp-service-account: {{ .Values.gcp.workloadIdentity.gcpServiceAccount }}
    {{- end }}
    {{- with .Values.serviceAccount.annotations }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
automountServiceAccountToken: {{ .Values.serviceAccount.automount | default true }}
{{- end }}
SAEOF

    # Replace CHART_NAME with actual chart name
    sed -i '' "s/CHART_NAME/${chart_name}/g" "$sa_file"
    echo -e "${GREEN}  [UPDATED] serviceaccount.yaml${NC}"
}

# Function to add GCP config to values.yaml
add_gcp_config() {
    local values_file="$1"

    # Check if already has GCP config
    if grep -q "^gcp:" "$values_file" 2>/dev/null; then
        echo -e "${YELLOW}  [SKIP] Already has GCP config${NC}"
        return 0
    fi

    # Add GCP configuration section
    cat >> "$values_file" << 'GCPEOF'

# GCP Secret Manager configuration
# When enabled, secrets are fetched from GCP Secret Manager via Workload Identity
gcp:
  projectId: ""  # Set by ArgoCD per environment
  namespace: ""  # Override if different from release namespace
  workloadIdentity:
    enabled: false
    gcpServiceAccount: ""  # e.g., app-secrets-global@project.iam.gserviceaccount.com
  secretManager:
    enabled: false
    secretPrefix: "dev"  # Environment prefix: dev, staging, prod
GCPEOF

    echo -e "${GREEN}  [ADDED] GCP configuration${NC}"
}

# Function to remove sealed-secret.yaml
remove_sealed_secret() {
    local templates_dir="$1"
    local sealed_secret="$templates_dir/sealed-secret.yaml"

    if [ -f "$sealed_secret" ]; then
        rm "$sealed_secret"
        echo -e "${GREEN}  [REMOVED] sealed-secret.yaml${NC}"
    fi
}

# Process each chart
for chart_dir in "$CHARTS_DIR"/*/; do
    chart_name=$(basename "$chart_dir")
    echo ""
    echo "Processing: $chart_name"
    echo "-------------------------------------------"

    chart_yaml="$chart_dir/Chart.yaml"
    values_file="$chart_dir/values.yaml"
    templates_dir="$chart_dir/templates"
    sa_file="$templates_dir/serviceaccount.yaml"

    # Skip if Chart.yaml doesn't exist
    if [ ! -f "$chart_yaml" ]; then
        echo -e "${RED}  [ERROR] No Chart.yaml found${NC}"
        continue
    fi

    # 1. Add common dependency
    add_common_dependency "$chart_yaml"

    # 2. Update serviceaccount.yaml
    update_serviceaccount "$sa_file" "$chart_name"

    # 3. Add GCP config to values.yaml
    if [ -f "$values_file" ]; then
        add_gcp_config "$values_file"
    fi

    # 4. Remove sealed-secret.yaml
    remove_sealed_secret "$templates_dir"
done

echo ""
echo "=========================================="
echo "Update Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Run 'helm dependency update' for each chart"
echo "2. Update deployment.yaml files for complex services manually"
echo "3. Run 'helm lint' to validate changes"
