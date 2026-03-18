#!/usr/bin/env bash
# =============================================================================
# Clear stale onboarding data from tenants_db
# Usage: ./clear-onboarding.sh [slug ...]
#   No args  → clears ALL onboarding sessions, tenants, and slug reservations
#   With args → clears only the specified slugs/business names
# =============================================================================
set -euo pipefail

PROJECT="tesserix"
REGION="asia-south1"
SQL_INSTANCE="tesserix:${REGION}:tesserix-main"
PROXY_PORT=15432
PSQL="/opt/homebrew/opt/postgresql/bin/psql"
DB_NAME="tenants_db"
DB_USER="tenants_user"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Ensure cloud-sql-proxy is running
# ---------------------------------------------------------------------------
ensure_proxy() {
  if lsof -i :${PROXY_PORT} &>/dev/null; then
    log "Cloud SQL proxy already running on port ${PROXY_PORT}"
    return
  fi
  log "Starting cloud-sql-proxy on port ${PROXY_PORT}..."
  cloud-sql-proxy "${SQL_INSTANCE}" --port=${PROXY_PORT} &
  PROXY_PID=$!
  sleep 3
  if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    err "Failed to start cloud-sql-proxy"
    exit 1
  fi
  log "Proxy started (pid ${PROXY_PID})"
  trap "kill ${PROXY_PID} 2>/dev/null || true" EXIT
}

# ---------------------------------------------------------------------------
# Get DB password
# ---------------------------------------------------------------------------
get_password() {
  gcloud secrets versions access latest --secret=tenants-db-password --project="${PROJECT}"
}

# ---------------------------------------------------------------------------
# Run SQL
# ---------------------------------------------------------------------------
run_sql() {
  PGPASSWORD="${DB_PASS}" "${PSQL}" -h 127.0.0.1 -p "${PROXY_PORT}" -U "${DB_USER}" -d "${DB_NAME}" "$@"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
ensure_proxy
DB_PASS=$(get_password)

echo ""
if [[ $# -eq 0 ]]; then
  log "Clearing ALL onboarding data..."
  echo ""

  # Show what will be deleted
  run_sql -c "SELECT slug, status, created_at FROM tenants ORDER BY created_at;"
  run_sql -c "SELECT id, status, created_at FROM onboarding_sessions ORDER BY created_at;"
  run_sql -c "SELECT slug, status FROM tenant_slug_reservations ORDER BY created_at;"
  echo ""

  read -rp "Delete all the above? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi

  run_sql <<'SQL'
BEGIN;
DELETE FROM application_configurations;
DELETE FROM business_addresses;
DELETE FROM business_informations;
DELETE FROM contact_informations;
DELETE FROM onboarding_tasks;
DELETE FROM onboarding_notifications;
DELETE FROM verification_tokens;
DELETE FROM tenant_slug_reservations;
DELETE FROM domain_reservations;
DELETE FROM tenant_credentials;
DELETE FROM user_tenant_memberships;
DELETE FROM deactivated_memberships;
DELETE FROM password_reset_tokens;
DELETE FROM passkey_credentials;
DELETE FROM tenant_auth_policies;
DELETE FROM tenant_auth_audit_log;
DELETE FROM tenant_activity_log;
DELETE FROM task_execution_logs;
DELETE FROM webhook_events;
DELETE FROM payment_informations;
DELETE FROM payment_information;
DELETE FROM verification_records;
DELETE FROM onboarding_sessions;
DELETE FROM tenants;
COMMIT;
SQL

else
  SLUGS=("$@")
  log "Clearing slugs: ${SLUGS[*]}"

  # Build comma-separated quoted list for SQL IN clause
  SQL_IN=$(printf "'%s'," "${SLUGS[@]}")
  SQL_IN="${SQL_IN%,}"  # trim trailing comma

  run_sql <<SQL
BEGIN;
-- Collect session IDs first, then delete children before parents
CREATE TEMP TABLE _sessions AS
  SELECT onboarding_session_id AS id FROM business_informations WHERE business_name IN (${SQL_IN});

DELETE FROM application_configurations WHERE onboarding_session_id IN (SELECT id FROM _sessions);
DELETE FROM business_addresses WHERE onboarding_session_id IN (SELECT id FROM _sessions);
DELETE FROM contact_informations WHERE onboarding_session_id IN (SELECT id FROM _sessions);
DELETE FROM onboarding_tasks WHERE onboarding_session_id IN (SELECT id FROM _sessions);
DELETE FROM verification_tokens WHERE session_id IN (SELECT id FROM _sessions);
DELETE FROM onboarding_notifications WHERE onboarding_session_id IN (SELECT id FROM _sessions);
DELETE FROM business_informations WHERE business_name IN (${SQL_IN});
DELETE FROM onboarding_sessions WHERE id IN (SELECT id FROM _sessions);
DELETE FROM tenant_slug_reservations WHERE slug IN (${SQL_IN});
DELETE FROM tenants WHERE slug IN (${SQL_IN});

DROP TABLE _sessions;
COMMIT;
SQL
fi

echo ""
log "Done. Remaining counts:"
run_sql -c "SELECT 'tenants' as tbl, count(*) FROM tenants UNION ALL SELECT 'sessions', count(*) FROM onboarding_sessions UNION ALL SELECT 'slug_reservations', count(*) FROM tenant_slug_reservations UNION ALL SELECT 'business_info', count(*) FROM business_informations;"
