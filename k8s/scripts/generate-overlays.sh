#!/usr/bin/env bash
# =============================================================================
# GENERATE SERVICE OVERLAYS from services.yaml
# =============================================================================
# Creates kustomization.yaml, configmap, and external-secret for each service.
# Run from repo root: ./scripts/generate-overlays.sh
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPS_DIR="$REPO_ROOT/k8s/apps"
SERVICES_YAML="$REPO_ROOT/services.yaml"
GHCR_URL="ghcr.io/tesserix"
CLOUD_SQL_PRIVATE_IP="${CLOUD_SQL_PRIVATE_IP:-10.0.0.3}"

# Check yq is installed
command -v yq >/dev/null 2>&1 || { echo "yq is required. Install: brew install yq"; exit 1; }

# Namespace mapping
namespace_for() {
  local svc="$1"
  local group
  group=$(yq ".services.\"$svc\".appGroup" "$SERVICES_YAML")
  case "$group" in
    platform) echo "shared" ;;  # Most platform services go to shared
    mark8ly)  echo "marketplace" ;;
    *)        echo "shared" ;;
  esac
}

# Override namespace for specific services
override_namespace() {
  local svc="$1"
  case "$svc" in
    auth-bff|tesserix-home) echo "tesserix" ;;
    qr-service|feature-flags-service|status-service) echo "stateless" ;;
    *) namespace_for "$svc" ;;
  esac
}

# Determine base template
base_for() {
  local svc="$1"
  local lang has_db
  lang=$(yq ".services.\"$svc\".lang" "$SERVICES_YAML")
  has_db=$(yq ".services.\"$svc\".hasDb" "$SERVICES_YAML")

  if [ "$svc" = "openfga" ]; then
    echo "openfga"
  elif [ "$lang" = "nextjs" ]; then
    echo "nextjs-service"
  elif [ "$has_db" = "true" ]; then
    echo "go-service"
  else
    echo "go-stateless"
  fi
}

# DB config for services with databases
db_config() {
  local svc="$1"
  local db_name db_user
  # Consistent naming: {prefix}_db / {prefix}_user (underscores only)
  case "$svc" in
    tenant-router-service) db_name="tenant_router_db"; db_user="tenant_router_user" ;;
    marketplace-onboarding) db_name="mp_onboarding_db"; db_user="mp_onboarding_user" ;;
    mp-gift-cards) db_name="mp_gift_cards_db"; db_user="mp_gift_cards_user" ;;
    mp-*) db_name="mp_${svc#mp-}_db"; db_user="mp_${svc#mp-}_user" ;;
    *-service) local prefix="${svc%-service}"; prefix="${prefix//-/_}"; db_name="${prefix}_db"; db_user="${prefix}_user" ;;
    *) db_name="${svc//-/_}_db"; db_user="${svc//-/_}_user" ;;
  esac
  echo "$db_name|$db_user"
}

# Service URL resolver (K8s DNS format)
resolve_url() {
  local target="$1"
  local target_ns
  target_ns=$(override_namespace "$target")
  # Map stateless to shared for DNS
  [ "$target_ns" = "stateless" ] && target_ns="shared"
  echo "http://${target}.${target_ns}.svc.cluster.local"
}

# Port override
port_for() {
  local svc="$1"
  case "$svc" in
    mp-inventory) echo "8088" ;;
    mp-approvals) echo "8099" ;;
    tenant-router-service) echo "8089" ;;
    analytics-service) echo "8091" ;;
    *) echo "8080" ;;
  esac
}

# Generate overlay for a single service
generate_service() {
  local svc="$1"
  local ns base has_db lang port
  ns=$(override_namespace "$svc")
  base=$(base_for "$svc")
  has_db=$(yq ".services.\"$svc\".hasDb" "$SERVICES_YAML")
  lang=$(yq ".services.\"$svc\".lang" "$SERVICES_YAML")
  port=$(port_for "$svc")

  local svc_dir="$APPS_DIR/$ns/$svc"
  mkdir -p "$svc_dir"

  # Resolve actual namespace (stateless services deploy to shared)
  local actual_ns
  actual_ns=$([ "$ns" = "stateless" ] && echo "shared" || echo "$ns")

  # Skip openfga — uses its own base with hardcoded config
  if [ "$svc" = "openfga" ]; then
    cat > "$svc_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: shared
resources:
  - ../../../bases/openfga
EOF
    echo "  Generated: $ns/$svc (openfga base)"
    return
  fi

  local rel_base="../../../bases/$base"
  local image_name="$GHCR_URL/$svc"
  local has_secrets
  has_secrets=$(yq -r ".services.\"$svc\".secrets[]" "$SERVICES_YAML" 2>/dev/null | head -1 || true)

  # Check if this go-stateless service needs a configmap
  local stateless_needs_configmap="false"
  if [ "$base" = "go-stateless" ]; then
    local _uses_gs
    _uses_gs=$(yq ".services.\"$svc\".usesGoShared" "$SERVICES_YAML")
    local _has_invokes
    _has_invokes=$(yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null | head -1 || true)
    if [ "$_uses_gs" = "true" ] || [ -n "$_has_invokes" ]; then
      stateless_needs_configmap="true"
    fi
  fi

  # Build resources list
  local resources="  - $rel_base"
  if [ "$has_db" = "true" ] || [ -n "$has_secrets" ]; then
    resources="$resources
  - external-secret.yaml"
  fi
  if [ "$has_db" = "true" ] && [ "$base" = "go-service" ]; then
    resources="$resources
  - configmap.yaml"
  fi
  if [ "$stateless_needs_configmap" = "true" ]; then
    resources="$resources
  - configmap.yaml"
  fi

  # Build patches
  local patches=""

  # All bases have envFrom with SERVICE_NAME-config and SERVICE_NAME-secrets (optional: true)
  # We always patch serviceAccountName and envFrom refs
  local envfrom_patches="      - op: replace
        path: /spec/template/spec/serviceAccountName
        value: $svc
      - op: replace
        path: /spec/template/spec/containers/0/envFrom/0/configMapRef/name
        value: ${svc}-config
      - op: replace
        path: /spec/template/spec/containers/0/envFrom/1/secretRef/name
        value: ${svc}-secrets"

  patches="  - target:
      kind: Service
      name: SERVICE_NAME
    patch: |
      - op: replace
        path: /metadata/name
        value: $svc
$envfrom_patches
  - target:
      kind: ServiceAccount
      name: SERVICE_NAME
    patch: |
      - op: replace
        path: /metadata/name
        value: $svc
      - op: replace
        path: /metadata/annotations/iam.gke.io~1gcp-service-account
        value: sa-${svc}@tesserix.iam.gserviceaccount.com"

  # Port override patch
  if [ "$port" != "8080" ] && [ "$base" != "nextjs-service" ]; then
    patches="$patches
  - target:
      kind: Service
      name: $svc
    patch: |
      - op: replace
        path: /spec/template/spec/containers/0/ports/0/containerPort
        value: $port"
  fi

  cat > "$svc_dir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $actual_ns

resources:
$resources

patches:
$patches

images:
  - name: PLACEHOLDER
    newName: $image_name
    newTag: latest
EOF

  # --- ConfigMap (for go-service with DB) ---
  if [ "$has_db" = "true" ] && [ "$base" = "go-service" ]; then
    local db_info db_name db_user
    db_info=$(db_config "$svc")
    db_name="${db_info%%|*}"
    db_user="${db_info##*|}"

    local ssl_key="DB_SSLMODE"
    [ "$svc" = "analytics-service" ] && ssl_key="DB_SSL_MODE"

    # Build service URL env vars
    local invokes_envs=""
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      local env_name url_val
      case "$target" in
        openfga) env_name="OPENFGA_URL" ;;
        *-service) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
        mp-*) env_name="$(echo "${target#mp-}" | tr '[:lower:]-' '[:upper:]_')_SERVICE_URL" ;;
        *) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
      esac
      url_val=$(resolve_url "$target")
      invokes_envs="${invokes_envs}  ${env_name}: \"${url_val}\"\n"
    done < <(yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null || true)

    # Determine go-shared auth modes
    local uses_go_shared invokes_openfga
    uses_go_shared=$(yq ".services.\"$svc\".usesGoShared" "$SERVICES_YAML")
    invokes_openfga=""
    yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null | grep -q "^openfga$" && invokes_openfga="true"

    cat > "$svc_dir/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${svc}-config
data:
  ENVIRONMENT: "production"
  GCP_PROJECT_ID: "tesserix"
  DB_HOST: "$CLOUD_SQL_PRIVATE_IP"
  DB_PORT: "5432"
  DB_NAME: "$db_name"
  DB_USER: "$db_user"
  $ssl_key: "require"
$([ "$uses_go_shared" = "true" ] && echo '  SERVICE_AUTH_MODE: "mesh"' || true)$([ -n "$invokes_openfga" ] && echo '
  OPENFGA_AUTH_MODE: "mesh"' || true)$([ -n "$invokes_envs" ] && echo "" && echo -ne "$invokes_envs" || true)
EOF
  fi

  # --- ConfigMap for go-stateless services (no DB but need mesh config) ---
  if [ "$base" = "go-stateless" ]; then
    local uses_go_shared invokes_openfga
    uses_go_shared=$(yq ".services.\"$svc\".usesGoShared" "$SERVICES_YAML")
    invokes_openfga=""
    yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null | grep -q "^openfga$" && invokes_openfga="true"

    # Build service URL env vars
    local invokes_envs=""
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      local env_name url_val
      case "$target" in
        openfga) env_name="OPENFGA_URL" ;;
        *-service) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
        mp-*) env_name="$(echo "${target#mp-}" | tr '[:lower:]-' '[:upper:]_')_SERVICE_URL" ;;
        *) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
      esac
      url_val=$(resolve_url "$target")
      invokes_envs="${invokes_envs}  ${env_name}: \"${url_val}\"\n"
    done < <(yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null || true)

    if [ "$uses_go_shared" = "true" ] || [ -n "$invokes_envs" ]; then
      cat > "$svc_dir/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${svc}-config
data:
  ENVIRONMENT: "production"
  GCP_PROJECT_ID: "tesserix"
$([ "$uses_go_shared" = "true" ] && echo '  SERVICE_AUTH_MODE: "mesh"' || true)$([ -n "$invokes_openfga" ] && echo '
  OPENFGA_AUTH_MODE: "mesh"' || true)$([ -n "$invokes_envs" ] && echo "" && echo -ne "$invokes_envs" || true)
EOF
      # Add configmap to resources
      if ! grep -q "configmap.yaml" "$svc_dir/kustomization.yaml" 2>/dev/null; then
        sed -i '' "s|^resources:|resources:\n  - configmap.yaml|" "$svc_dir/kustomization.yaml" 2>/dev/null || true
      fi
    fi
  fi

  # --- ConfigMap for nextjs services with invokes ---
  if [ "$base" = "nextjs-service" ]; then
    local invokes_envs=""
    while IFS= read -r target; do
      [ -z "$target" ] && continue
      local env_name url_val
      case "$target" in
        auth-bff) env_name="AUTH_BFF_URL" ;;
        openfga) env_name="OPENFGA_URL" ;;
        *-service) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
        mp-*) env_name="$(echo "${target#mp-}" | tr '[:lower:]-' '[:upper:]_')_SERVICE_URL" ;;
        *) env_name="$(echo "$target" | tr '[:lower:]-' '[:upper:]_')_URL" ;;
      esac
      url_val=$(resolve_url "$target")
      invokes_envs="${invokes_envs}  ${env_name}: \"${url_val}\"\n"
    done < <(yq -r ".services.\"$svc\".invokes[]" "$SERVICES_YAML" 2>/dev/null || true)

    if [ -n "$invokes_envs" ]; then
      cat > "$svc_dir/configmap.yaml" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${svc}-config
data:
  NODE_ENV: "production"
  GCP_PROJECT_ID: "tesserix"
$(echo -ne "$invokes_envs")
EOF
      # Add configmap to resources
      if ! grep -q "configmap.yaml" "$svc_dir/kustomization.yaml" 2>/dev/null; then
        sed -i '' "s|^resources:|resources:\n  - configmap.yaml|" "$svc_dir/kustomization.yaml" 2>/dev/null || true
      fi
    fi
  fi

  # --- ExternalSecret ---
  local secrets
  secrets=$(yq -r ".services.\"$svc\".secrets[]" "$SERVICES_YAML" 2>/dev/null || true)
  if [ -n "$secrets" ]; then
    cat > "$svc_dir/external-secret.yaml" <<EOF
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: ${svc}-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: gcp-secret-manager
    kind: ClusterSecretStore
  target:
    name: ${svc}-secrets
    creationPolicy: Owner
  data:
EOF
    while IFS= read -r secret; do
      [ -z "$secret" ] && continue
      local env_key
      case "$secret" in
        *-db-password|*_db-password) env_key="DB_PASSWORD" ;;
        openfga-preshared-key) env_key="OPENFGA_API_KEY" ;;
        openfga-marketplace-store-id) env_key="OPENFGA_MARKETPLACE_STORE_ID" ;;
        openfga-platform-store-id) env_key="OPENFGA_PLATFORM_STORE_ID" ;;
        sendgrid-api-key) env_key="SENDGRID_API_KEY" ;;
        stripe-secret-key) env_key="STRIPE_SECRET_KEY" ;;
        stripe-webhook-secret) env_key="STRIPE_WEBHOOK_SECRET" ;;
        growthbook-api-key) env_key="GROWTHBOOK_API_KEY" ;;
        shared-internal-service-key) env_key="INTERNAL_SERVICE_KEY" ;;
        cloudflare-api-token) env_key="CLOUDFLARE_API_TOKEN" ;;
        verification-encryption-key) env_key="ENCRYPTION_KEY" ;;
        auth-bff-cookie-encryption-key) env_key="COOKIE_ENCRYPTION_KEY" ;;
        auth-bff-csrf-secret) env_key="CSRF_SECRET" ;;
        platform-client-secret) env_key="PLATFORM_CLIENT_SECRET" ;;
        mp-admin-client-secret) env_key="MP_ADMIN_CLIENT_SECRET" ;;
        mp-storefront-client-secret) env_key="MP_STOREFRONT_CLIENT_SECRET" ;;
        marketplace-admin-csrf-secret) env_key="CSRF_SECRET" ;;
        *) env_key=$(echo "$secret" | tr '[:lower:]-' '[:upper:]_') ;;
      esac
      cat >> "$svc_dir/external-secret.yaml" <<EOF
    - secretKey: $env_key
      remoteRef:
        key: $secret
        version: latest
EOF
    done <<< "$secrets"
  fi

  echo "  Generated: $ns/$svc (base: $base)"
}

# --- Main ---
echo "Generating service overlays from services.yaml..."
echo "Cloud SQL Private IP: $CLOUD_SQL_PRIVATE_IP"
echo ""

# Clean existing overlays
for dir in "$APPS_DIR"/{platform,shared,marketplace,stateless}; do
  [ -d "$dir" ] && rm -rf "$dir"/*
done

# Process all services
for svc in $(yq -r '.services | keys[]' "$SERVICES_YAML"); do
  generate_service "$svc"
done

echo ""
echo "Done. Generated overlays in $APPS_DIR"
echo "Run 'kustomize build k8s/apps/<ns>/<svc>' to validate."
