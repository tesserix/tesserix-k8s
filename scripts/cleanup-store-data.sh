#!/bin/bash
#
# Cleanup Script for Tesserix Store Data
#
# This script removes all data associated with a specific store (tenant) from:
# - tesseract_hub database (marketplace PostgreSQL)
# - staff_db database (marketplace PostgreSQL)
# - Keycloak user attributes (customer IDP)
#
# Usage: ./cleanup-store-data.sh <store-slug>
# Example: ./cleanup-store-data.sh demo-store
#
# WARNING: This script permanently deletes data. Use with caution!
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default namespaces
POSTGRES_NS="${POSTGRES_NS:-postgresql-marketplace}"
POSTGRES_POD="${POSTGRES_POD:-postgresql-0}"

# Databases
HUB_DB="tesseract_hub"
STAFF_DB="staff_db"
VENDORS_DB="vendors_db"

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Error: Store slug is required${NC}"
    echo "Usage: $0 <store-slug>"
    echo "Example: $0 demo-store"
    exit 1
fi

STORE_SLUG="$1"

echo -e "${YELLOW}=== Tesserix Store Data Cleanup ===${NC}"
echo "Store Slug: $STORE_SLUG"
echo ""

# Confirm with user
read -p "Are you sure you want to delete all data for store '$STORE_SLUG'? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo -e "${YELLOW}Step 1: Getting tenant information...${NC}"

# Get tenant ID
TENANT_ID=$(kubectl exec -n $POSTGRES_NS $POSTGRES_POD -c postgresql -- \
    psql -U postgres -d $HUB_DB -t -c \
    "SELECT id FROM tenants WHERE slug = '$STORE_SLUG';" 2>/dev/null | tr -d ' \n')

if [ -z "$TENANT_ID" ]; then
    echo -e "${YELLOW}No tenant found with slug '$STORE_SLUG'. Checking for partial data...${NC}"
else
    echo "Found tenant ID: $TENANT_ID"
fi

echo ""
echo -e "${YELLOW}Step 2: Cleaning up tesseract_hub database...${NC}"

kubectl exec -n $POSTGRES_NS $POSTGRES_POD -c postgresql -- psql -U postgres -d $HUB_DB << EOSQL
BEGIN;

-- Step 1: Get tenant and session IDs for this slug
DO \$\$
DECLARE
    v_tenant_id UUID;
    v_session_ids UUID[];
BEGIN
    -- Get tenant ID if exists
    SELECT id INTO v_tenant_id FROM tenants WHERE slug = '$STORE_SLUG';

    -- Get all session IDs associated with this slug (from reservations or tenants)
    SELECT ARRAY_AGG(DISTINCT session_id) INTO v_session_ids
    FROM tenant_slug_reservations WHERE slug = '$STORE_SLUG' AND session_id IS NOT NULL;

    -- Also get sessions linked to this tenant
    IF v_tenant_id IS NOT NULL THEN
        SELECT ARRAY_AGG(id) || COALESCE(v_session_ids, ARRAY[]::UUID[]) INTO v_session_ids
        FROM onboarding_sessions WHERE tenant_id = v_tenant_id;
    END IF;

    RAISE NOTICE 'Cleaning up slug: $STORE_SLUG';
    RAISE NOTICE 'Tenant ID: %', COALESCE(v_tenant_id::text, 'None');
    RAISE NOTICE 'Session IDs: %', COALESCE(v_session_ids::text, 'None');

    -- Clean up onboarding data by session IDs
    IF v_session_ids IS NOT NULL AND array_length(v_session_ids, 1) > 0 THEN
        DELETE FROM verification_records WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM verification_codes WHERE session_id = ANY(v_session_ids);
        DELETE FROM onboarding_tasks WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM application_configurations WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM business_addresses WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM contact_informations WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM business_informations WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM payment_informations WHERE onboarding_session_id = ANY(v_session_ids);
        DELETE FROM onboarding_sessions WHERE id = ANY(v_session_ids);
        RAISE NOTICE 'Cleaned up % onboarding session(s)', array_length(v_session_ids, 1);
    END IF;

    -- Clean up tenant data
    IF v_tenant_id IS NOT NULL THEN
        DELETE FROM user_tenant_memberships WHERE tenant_id = v_tenant_id;
        DELETE FROM deactivated_memberships WHERE tenant_id = v_tenant_id;
        DELETE FROM tenant_credentials WHERE tenant_id = v_tenant_id;
        DELETE FROM tenant_auth_policies WHERE tenant_id = v_tenant_id;
        DELETE FROM tenant_host_records WHERE tenant_id::uuid = v_tenant_id;
        DELETE FROM tenant_activity_log WHERE tenant_id = v_tenant_id::text;
        DELETE FROM provisioning_activity_logs WHERE tenant_id = v_tenant_id;
        DELETE FROM tenants WHERE id = v_tenant_id;
        RAISE NOTICE 'Tenant % deleted successfully', v_tenant_id;
    ELSE
        RAISE NOTICE 'No tenant found with slug $STORE_SLUG';
    END IF;
END \$\$;

-- Step 2: Delete slug reservations regardless of tenant existence
-- This catches orphaned reservations from failed onboarding attempts
DELETE FROM tenant_slug_reservations WHERE slug = '$STORE_SLUG';
DELETE FROM reserved_slugs WHERE slug = '$STORE_SLUG';

COMMIT;

SELECT 'tesseract_hub cleanup completed' as result;
EOSQL

if [ $? -ne 0 ]; then
    echo -e "${RED}Error cleaning up tesseract_hub database${NC}"
else
    echo -e "${GREEN}tesseract_hub cleanup completed${NC}"
fi

echo ""
echo -e "${YELLOW}Step 3: Cleaning up staff_db database...${NC}"

if [ -n "$TENANT_ID" ]; then
    kubectl exec -n $POSTGRES_NS $POSTGRES_POD -c postgresql -- psql -U postgres -d $STAFF_DB << EOSQL
BEGIN;

-- Delete staff role assignments
DELETE FROM staff_role_assignments WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff sessions
DELETE FROM staff_sessions WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff login audit
DELETE FROM staff_login_audit WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff documents
DELETE FROM staff_documents WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff emergency contacts
DELETE FROM staff_emergency_contacts WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff invitations
DELETE FROM staff_invitations WHERE tenant_id = '$TENANT_ID';

-- Delete staff password history
DELETE FROM staff_password_history WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff oauth providers
DELETE FROM staff_oauth_providers WHERE staff_id IN
    (SELECT id FROM staff WHERE tenant_id = '$TENANT_ID');

-- Delete staff RBAC audit log
DELETE FROM staff_rbac_audit_log WHERE tenant_id = '$TENANT_ID';

-- Delete tenant-specific roles (keep system roles)
DELETE FROM staff_roles WHERE tenant_id = '$TENANT_ID' AND is_system_role = false;

-- Delete departments and teams
DELETE FROM teams WHERE tenant_id = '$TENANT_ID';
DELETE FROM departments WHERE tenant_id = '$TENANT_ID';

-- Finally, delete staff members
DELETE FROM staff WHERE tenant_id = '$TENANT_ID';

COMMIT;

SELECT 'staff_db cleanup completed' as result;
EOSQL

    if [ $? -ne 0 ]; then
        echo -e "${RED}Error cleaning up staff_db database${NC}"
    else
        echo -e "${GREEN}staff_db cleanup completed${NC}"
    fi
else
    echo "Skipping staff_db cleanup (no tenant ID)"
fi

echo ""
echo -e "${YELLOW}Step 4: Cleaning up vendors_db database...${NC}"

if [ -n "$TENANT_ID" ]; then
    kubectl exec -n $POSTGRES_NS $POSTGRES_POD -c postgresql -- psql -U postgres -d $VENDORS_DB << EOSQL
BEGIN;

-- Delete vendor-related data
DELETE FROM vendors WHERE tenant_id = '$TENANT_ID';

COMMIT;

SELECT 'vendors_db cleanup completed' as result;
EOSQL

    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}vendors_db cleanup skipped or failed (may not have data)${NC}"
    else
        echo -e "${GREEN}vendors_db cleanup completed${NC}"
    fi
else
    echo "Skipping vendors_db cleanup (no tenant ID)"
fi

echo ""
echo -e "${GREEN}=== Cleanup Complete ===${NC}"
echo ""
echo "Summary:"
echo "- Store slug: $STORE_SLUG"
if [ -n "$TENANT_ID" ]; then
    echo "- Tenant ID: $TENANT_ID"
fi
echo "- Databases cleaned: tesseract_hub, staff_db, vendors_db"
echo ""
echo -e "${YELLOW}Note: Keycloak user data should be cleaned up separately if needed.${NC}"
echo "The user can re-register with the same email after cleanup."
