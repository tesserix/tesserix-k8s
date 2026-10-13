#!/bin/sh
set -eu
umask 077
export PGDATA=/restore/data
export PGHOST=/restore/socket
export PGUSER=postgres
mkdir -p "$PGHOST"
cleanup() {
  pg_ctl -D "$PGDATA" -m immediate stop >/dev/null 2>&1 || true
  rm -rf /restore/data /restore/socket
}
trap cleanup EXIT
barman-cloud-restore --cloud-provider google-cloud-storage \
  "$BACKUP_DESTINATION" "$BACKUP_SERVER" "$BACKUP_ID" "$PGDATA"
test ! -L "$PGDATA/pg_wal" || rm "$PGDATA/pg_wal"
mkdir -p "$PGDATA/pg_wal"
rm -f "$PGDATA/standby.signal"
: > "$PGDATA/postgresql.auto.conf"
printf 'local all all trust\n' > "$PGDATA/pg_hba.conf"
cat > "$PGDATA/postgresql.conf" <<EOF
listen_addresses = ''
unix_socket_directories = '/restore/socket'
ssl = off
archive_mode = off
logging_collector = off
shared_preload_libraries = ''
shared_buffers = '64MB'
max_connections = 200
max_worker_processes = 32
max_wal_senders = 32
max_prepared_transactions = 100
max_locks_per_transaction = 256
restore_command = 'barman-cloud-wal-restore --cloud-provider google-cloud-storage $BACKUP_DESTINATION $BACKUP_SERVER %f %p'
recovery_target = 'immediate'
recovery_target_action = 'promote'
EOF
touch "$PGDATA/recovery.signal"
pg_ctl -D "$PGDATA" -l /restore/postgres.log -w -t 180 start
psql -X -v ON_ERROR_STOP=1 -d helivanta -At <<'SQL'
DO $$
BEGIN
  IF pg_is_in_recovery() THEN RAISE EXCEPTION 'recovery did not finish'; END IF;
  IF NOT EXISTS (SELECT 1 FROM schema_migrations) THEN RAISE EXCEPTION 'migration ledger missing'; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'hms_app' AND (rolsuper OR rolbypassrls)) THEN
    RAISE EXCEPTION 'serving role bypasses isolation';
  END IF;
END $$;
SELECT 'restore_check_passed';
SQL
pg_ctl -D "$PGDATA" -m fast -w stop
