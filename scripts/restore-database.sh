#!/bin/bash
# =============================================================================
# PostgreSQL Database Restore Script
# =============================================================================
# This script creates a Kubernetes Job to restore a specific database from
# a GCS backup file.
#
# Usage:
#   ./restore-database.sh <environment> <postgres-instance> <database-name> [timestamp]
#
# Examples:
#   # Restore tenants_db from marketplace PostgreSQL in devtest (latest backup)
#   ./restore-database.sh devtest marketplace tenants_db
#
#   # Restore with specific timestamp
#   ./restore-database.sh devtest marketplace tenants_db 2026-02-05T02-02-07Z
#
#   # Restore tenants_db from global PostgreSQL in prod
#   ./restore-database.sh prod global tenants_db
#
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validate arguments
if [ $# -lt 3 ]; then
    echo -e "${RED}Usage: $0 <environment> <postgres-instance> <database-name> [timestamp]${NC}"
    echo ""
    echo "Arguments:"
    echo "  environment       devtest or prod"
    echo "  postgres-instance global or marketplace"
    echo "  database-name     Name of the database to restore (e.g., tenants_db)"
    echo "  timestamp         Optional: specific backup timestamp (e.g., 2026-02-05T02-02-07Z)"
    echo ""
    echo "Examples:"
    echo "  $0 devtest marketplace tenants_db"
    echo "  $0 prod global tenants_db 2026-02-05T00-00-04Z"
    exit 1
fi

ENVIRONMENT="$1"
PG_INSTANCE="$2"
DATABASE="$3"
TIMESTAMP="${4:-}"

# Validate environment
if [[ ! "$ENVIRONMENT" =~ ^(devtest|prod)$ ]]; then
    echo -e "${RED}Error: Environment must be 'devtest' or 'prod'${NC}"
    exit 1
fi

# Validate postgres instance
if [[ ! "$PG_INSTANCE" =~ ^(global|marketplace)$ ]]; then
    echo -e "${RED}Error: PostgreSQL instance must be 'global' or 'marketplace'${NC}"
    exit 1
fi

# Configuration
GCS_BUCKET="tesseract-database-backups"
GCS_PREFIX="${ENVIRONMENT}/postgresql-${PG_INSTANCE}"
PG_HOST="postgresql.postgresql-${PG_INSTANCE}.svc.cluster.local"
PG_SECRET="postgresql-${PG_INSTANCE}-password"
NAMESPACE="db-backup-and-restore"
IMAGE="ghcr.io/tesserix/global-services/db-backup-tools:latest"
SA_NAME="postgres-backup"

echo -e "${GREEN}========================================"
echo "PostgreSQL Database Restore"
echo "========================================${NC}"
echo "Environment:    $ENVIRONMENT"
echo "PostgreSQL:     $PG_INSTANCE ($PG_HOST)"
echo "Database:       $DATABASE"
echo "GCS Prefix:     gs://$GCS_BUCKET/$GCS_PREFIX/"
echo ""

# List available backups if no timestamp provided
if [ -z "$TIMESTAMP" ]; then
    echo -e "${YELLOW}Available backups for ${DATABASE}:${NC}"
    BACKUPS=$(gsutil ls -l "gs://${GCS_BUCKET}/${GCS_PREFIX}/${DATABASE}-*.dump" 2>/dev/null | tail -10 || echo "")

    if [ -z "$BACKUPS" ]; then
        echo -e "${RED}No backups found for database: ${DATABASE}${NC}"
        echo "Available databases:"
        gsutil ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/" 2>/dev/null | sed 's/.*\///' | sed 's/-[0-9T-]*Z\.dump//' | sort -u | head -20
        exit 1
    fi

    echo "$BACKUPS"
    echo ""

    # Get latest backup
    LATEST_BACKUP=$(gsutil ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/${DATABASE}-*.dump" 2>/dev/null | sort | tail -1)
    BACKUP_FILE=$(basename "$LATEST_BACKUP")

    echo -e "${GREEN}Using latest backup: ${BACKUP_FILE}${NC}"
else
    BACKUP_FILE="${DATABASE}-${TIMESTAMP}.dump"
    echo -e "${GREEN}Using specified backup: ${BACKUP_FILE}${NC}"

    # Verify backup exists
    if ! gsutil ls "gs://${GCS_BUCKET}/${GCS_PREFIX}/${BACKUP_FILE}" &>/dev/null; then
        echo -e "${RED}Error: Backup file not found: gs://${GCS_BUCKET}/${GCS_PREFIX}/${BACKUP_FILE}${NC}"
        exit 1
    fi
fi

GCS_PATH="${GCS_PREFIX}/${BACKUP_FILE}"
JOB_NAME="restore-${DATABASE}-$(date +%s)"

echo ""
echo -e "${YELLOW}WARNING: This will overwrite data in database '${DATABASE}'!${NC}"
read -p "Continue? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo -e "${GREEN}Creating restore job: ${JOB_NAME}${NC}"

# Create the restore job
cat <<EOF | kubectl apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: postgresql-restore
    app.kubernetes.io/component: restore
    app.kubernetes.io/database: ${DATABASE}
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 7200
  template:
    metadata:
      labels:
        app.kubernetes.io/name: postgresql-restore
        app.kubernetes.io/component: restore
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      serviceAccountName: ${SA_NAME}
      restartPolicy: Never
      imagePullSecrets:
        - name: ghcr-secret
      containers:
        - name: restore
          image: ${IMAGE}
          imagePullPolicy: Always
          env:
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${PG_SECRET}
                  key: postgresql-password
            - name: PGSSLMODE
              value: "require"
          command:
            - /bin/bash
            - -c
            - |
              set -eo pipefail

              GCS_PATH="gs://${GCS_BUCKET}/${GCS_PATH}"
              LOCAL_FILE="/tmp/${BACKUP_FILE}"
              TARGET_DB="${DATABASE}"
              PG_HOST="${PG_HOST}"

              echo "========================================"
              echo "PostgreSQL Restore Job"
              echo "========================================"
              echo "Target Database: \${TARGET_DB}"
              echo "Backup File: \${GCS_PATH}"
              echo "========================================"

              # Download backup
              echo "Downloading backup..."
              gsutil cp \${GCS_PATH} \${LOCAL_FILE}
              echo "Downloaded: \$(du -h \${LOCAL_FILE} | cut -f1)"

              # Check if database exists
              DB_EXISTS=\$(PGPASSWORD="\${POSTGRES_PASSWORD}" psql \\
                --host=\${PG_HOST} --port=5432 --username=postgres --dbname=postgres \\
                -Atc "SELECT 1 FROM pg_database WHERE datname = '\${TARGET_DB}'" 2>/dev/null || echo "")

              if [ "\${DB_EXISTS}" != "1" ]; then
                echo "Creating database \${TARGET_DB}..."
                PGPASSWORD="\${POSTGRES_PASSWORD}" psql \\
                  --host=\${PG_HOST} --port=5432 --username=postgres --dbname=postgres \\
                  -c "CREATE DATABASE \"\${TARGET_DB}\""
              fi

              # Restore
              echo "Restoring to \${TARGET_DB}..."
              PGPASSWORD="\${POSTGRES_PASSWORD}" pg_restore \\
                --host=\${PG_HOST} --port=5432 --username=postgres \\
                --dbname=\${TARGET_DB} \\
                --clean --if-exists --jobs=4 \\
                \${LOCAL_FILE} 2>&1 || true

              # Verify
              TABLE_COUNT=\$(PGPASSWORD="\${POSTGRES_PASSWORD}" psql \\
                --host=\${PG_HOST} --port=5432 --username=postgres --dbname=\${TARGET_DB} \\
                -Atc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" 2>/dev/null)
              echo "Tables restored: \${TABLE_COUNT}"

              rm -f \${LOCAL_FILE}
              echo "========================================"
              echo "Restore completed!"
              echo "========================================"
          resources:
            requests:
              memory: 256Mi
            limits:
              memory: 1Gi
          volumeMounts:
            - name: tmp
              mountPath: /tmp
      volumes:
        - name: tmp
          emptyDir:
            sizeLimit: 10Gi
EOF

echo ""
echo -e "${GREEN}Job created. Waiting for completion...${NC}"
echo "You can follow logs with: kubectl logs -f job/${JOB_NAME} -n ${NAMESPACE}"
echo ""

# Wait for job and show logs
kubectl wait --for=condition=complete job/${JOB_NAME} -n ${NAMESPACE} --timeout=3600s &
WAIT_PID=$!

# Stream logs
sleep 3
kubectl logs -f job/${JOB_NAME} -n ${NAMESPACE} 2>/dev/null || true

# Wait for completion
wait $WAIT_PID 2>/dev/null || true

# Check job status
JOB_STATUS=$(kubectl get job ${JOB_NAME} -n ${NAMESPACE} -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "0")

if [ "$JOB_STATUS" = "1" ]; then
    echo ""
    echo -e "${GREEN}========================================"
    echo "Restore completed successfully!"
    echo "========================================${NC}"
else
    echo ""
    echo -e "${RED}========================================"
    echo "Restore may have failed. Check logs:"
    echo "kubectl logs job/${JOB_NAME} -n ${NAMESPACE}"
    echo "========================================${NC}"
    exit 1
fi
