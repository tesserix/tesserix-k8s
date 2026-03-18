#!/bin/bash
# =============================================================================
# Migrate All Charts to GCP Secret Manager Only
# =============================================================================
# This script updates all app charts to use ONLY GCP Secret Manager
# No Kubernetes secrets fallback - GCP is mandatory for production
# =============================================================================

CHARTS_DIR="/Users/samyakrout/Desktop/samyak-work/projects/tesserix-k8s/charts/apps"

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo "=========================================="
echo "Migrating Charts to GCP Secrets Only"
echo "=========================================="

# Charts that don't need database secrets (frontend only)
FRONTEND_CHARTS="admin storefront fanzone-web homechef-web hms-patient-portal hms-staff-portal bookkeeping-web"

# Charts with complex secrets (need special handling)
COMPLEX_CHARTS="notification-service payment-service shipping-service document-service"

# Charts that need Redis
REDIS_CHARTS="fanzone-api fanzone-auth fanzone-ws hms-appointment-service hms-billing-service hms-patient-service hms-vitals-service homechef-api notification-hub"

# Charts that need JWT
JWT_CHARTS="auth-service fanzone-auth hms-auth-service bookkeeping-auth-service"

# Function to determine namespace for a chart
get_namespace() {
    local chart="$1"
    case "$chart" in
        auth-service|tenant-service|notification-service|notification-hub|verification-service|settings-service|location-service|translation-service|bergamot-service|huggingface-mt-service|search-service|audit-service|feature-flags-service|document-service|qr-service|status-dashboard-service)
            echo "global"
            ;;
        products-service|categories-service|orders-service|inventory-service|customers-service|vendors-service|coupons-service|gift-cards-service|reviews-service|tickets-service|staff-service|payment-service|shipping-service|tax-service|marketplace-connector-service|approval-service|marketing-service|analytics-service|admin|storefront|tenant-onboarding|tenant-router-service|vendor-service)
            echo "marketplace"
            ;;
        hms-*)
            echo "hms"
            ;;
        fanzone-*|sports-data)
            echo "fanzone"
            ;;
        homechef-*)
            echo "homechef"
            ;;
        bookkeeping-*)
            echo "bookkeeping"
            ;;
        *)
            echo "global"
            ;;
    esac
}

# Function to check if chart needs database
needs_database() {
    local chart="$1"
    for fc in $FRONTEND_CHARTS; do
        if [ "$chart" = "$fc" ]; then
            return 1
        fi
    done
    return 0
}

# Function to check if chart needs Redis
needs_redis() {
    local chart="$1"
    for rc in $REDIS_CHARTS; do
        if [ "$chart" = "$rc" ]; then
            return 0
        fi
    done
    return 1
}

# Function to check if chart needs JWT
needs_jwt() {
    local chart="$1"
    for jc in $JWT_CHARTS; do
        if [ "$chart" = "$jc" ]; then
            return 0
        fi
    done
    return 1
}

# Function to update values.yaml to GCP-only
update_values_gcp_only() {
    local values_file="$1"
    local chart_name="$2"
    local namespace=$(get_namespace "$chart_name")

    # Remove old postgresql/jwt K8s secret configurations
    sed -i '' '/^# PostgreSQL password/,/^$/d' "$values_file" 2>/dev/null
    sed -i '' '/^postgresql:/,/^[a-z]/{ /^postgresql:/,/existingSecretKey:/d; }' "$values_file" 2>/dev/null
    sed -i '' '/^# JWT secret/,/^$/d' "$values_file" 2>/dev/null
    sed -i '' '/^jwt:/,/^[a-z]/{ /^jwt:/,/existingSecretKey:/d; }' "$values_file" 2>/dev/null
    sed -i '' '/^# Secrets/,/^$/d' "$values_file" 2>/dev/null
    sed -i '' '/^secrets:/,/^[a-z]/{ /^secrets:/,/data: {}/d; }' "$values_file" 2>/dev/null
    sed -i '' '/^# Sealed Secret/,/^$/d' "$values_file" 2>/dev/null
    sed -i '' '/^sealedSecret:/,/^[a-z]/{ /^sealedSecret:/d; }' "$values_file" 2>/dev/null

    # Update GCP config to be required
    if grep -q "^gcp:" "$values_file"; then
        # Update existing GCP config
        sed -i '' "s/namespace: \"\"/namespace: \"$namespace\"/" "$values_file"
        sed -i '' 's/enabled: false/# Workload Identity is always enabled/' "$values_file"
    fi
}

# Function to create standard deployment with GCP secrets
create_standard_deployment() {
    local chart_dir="$1"
    local chart_name="$2"
    local namespace=$(get_namespace "$chart_name")
    local deployment_file="$chart_dir/templates/deployment.yaml"

    local needs_db=false
    local needs_redis_flag=false
    local needs_jwt_flag=false

    needs_database "$chart_name" && needs_db=true
    needs_redis "$chart_name" && needs_redis_flag=true
    needs_jwt "$chart_name" && needs_jwt_flag=true

    cat > "$deployment_file" << 'DEPEOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "CHART_NAME.fullname" . }}
  labels:
    {{- include "CHART_NAME.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "CHART_NAME.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      labels:
        {{- include "CHART_NAME.labels" . | nindent 8 }}
        {{- with .Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
    spec:
      {{- with .Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      serviceAccountName: {{ include "CHART_NAME.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.podSecurityContext | nindent 8 }}
      containers:
        - name: {{ .Chart.Name }}
          securityContext:
            {{- toYaml .Values.securityContext | nindent 12 }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: {{ .Values.service.port | default .Values.service.targetPort | default 8080 }}
              protocol: TCP
          env:
            {{- range $key, $value := .Values.env }}
            - name: {{ $key }}
              value: {{ $value | quote }}
            {{- end }}
            # GCP Secret Manager Configuration (required)
            - name: GCP_PROJECT_ID
              value: {{ required "gcp.projectId is required" .Values.gcp.projectId | quote }}
            - name: GCP_SECRET_PREFIX
              value: {{ .Values.gcp.secretManager.secretPrefix | quote }}
            - name: USE_GCP_SECRET_MANAGER
              value: "true"
DEPEOF

    # Add database secrets if needed
    if [ "$needs_db" = true ]; then
        cat >> "$deployment_file" << 'DBEOF'
            # Database password from GCP Secret Manager
            - name: DB_PASSWORD_SECRET_NAME
              value: {{ printf "%s-%s-postgresql-password" .Values.gcp.secretManager.secretPrefix (.Values.gcp.namespace | default .Release.Namespace) | quote }}
DBEOF
    fi

    # Add Redis secrets if needed
    if [ "$needs_redis_flag" = true ]; then
        cat >> "$deployment_file" << 'REDISEOF'
            # Redis password from GCP Secret Manager
            - name: REDIS_PASSWORD_SECRET_NAME
              value: {{ printf "%s-%s-redis-password" .Values.gcp.secretManager.secretPrefix (.Values.gcp.namespace | default .Release.Namespace) | quote }}
REDISEOF
    fi

    # Add JWT secrets if needed
    if [ "$needs_jwt_flag" = true ]; then
        cat >> "$deployment_file" << 'JWTEOF'
            # JWT secret from GCP Secret Manager
            - name: JWT_SECRET_SECRET_NAME
              value: {{ printf "%s-jwt-secret" .Values.gcp.secretManager.secretPrefix | quote }}
JWTEOF
    fi

    # Add probes and resources
    cat >> "$deployment_file" << 'PROBESEOF'
          {{- if .Values.livenessProbe }}
          {{- if .Values.livenessProbe.enabled }}
          livenessProbe:
            httpGet:
              path: {{ .Values.livenessProbe.httpGet.path | default "/health" }}
              port: http
            initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds | default 10 }}
            periodSeconds: {{ .Values.livenessProbe.periodSeconds | default 30 }}
            timeoutSeconds: {{ .Values.livenessProbe.timeoutSeconds | default 3 }}
            failureThreshold: {{ .Values.livenessProbe.failureThreshold | default 3 }}
          {{- end }}
          {{- end }}
          {{- if .Values.readinessProbe }}
          {{- if .Values.readinessProbe.enabled }}
          readinessProbe:
            httpGet:
              path: {{ .Values.readinessProbe.httpGet.path | default "/ready" }}
              port: http
            initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds | default 5 }}
            periodSeconds: {{ .Values.readinessProbe.periodSeconds | default 10 }}
            timeoutSeconds: {{ .Values.readinessProbe.timeoutSeconds | default 3 }}
            failureThreshold: {{ .Values.readinessProbe.failureThreshold | default 3 }}
          {{- end }}
          {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
PROBESEOF

    # Replace CHART_NAME with actual chart name
    sed -i '' "s/CHART_NAME/${chart_name}/g" "$deployment_file"
}

# Process each chart
for chart_dir in "$CHARTS_DIR"/*/; do
    chart_name=$(basename "$chart_dir")

    # Skip common library chart
    if [ "$chart_name" = "common" ]; then
        continue
    fi

    echo ""
    echo "Processing: $chart_name"
    echo "-------------------------------------------"

    values_file="$chart_dir/values.yaml"
    deployment_file="$chart_dir/templates/deployment.yaml"
    namespace=$(get_namespace "$chart_name")

    echo -e "  Namespace: ${GREEN}$namespace${NC}"

    # Update values.yaml
    if [ -f "$values_file" ]; then
        update_values_gcp_only "$values_file" "$chart_name"
        echo -e "  ${GREEN}[UPDATED]${NC} values.yaml - removed K8s secret configs"
    fi

    # Skip deployment update for complex charts (handled separately)
    is_complex=false
    for cc in $COMPLEX_CHARTS; do
        if [ "$chart_name" = "$cc" ]; then
            is_complex=true
            break
        fi
    done

    if [ "$is_complex" = true ]; then
        echo -e "  ${YELLOW}[SKIP]${NC} deployment.yaml - complex chart, manual update needed"
        continue
    fi

    # Create standard deployment for regular charts
    if [ -f "$deployment_file" ]; then
        create_standard_deployment "$chart_dir" "$chart_name"
        echo -e "  ${GREEN}[UPDATED]${NC} deployment.yaml - GCP secrets only"
    fi
done

echo ""
echo "=========================================="
echo "Migration Complete!"
echo "=========================================="
echo ""
echo -e "${YELLOW}Manual updates needed for:${NC}"
echo "  - notification-service (complex secrets)"
echo "  - payment-service (complex secrets)"
echo "  - shipping-service (complex secrets)"
echo "  - document-service (complex secrets)"
