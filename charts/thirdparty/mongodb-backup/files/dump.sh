set -euo pipefail
BACKUP_DIR=${BACKUP_DIR:-/backups}
mkdir -p "$BACKUP_DIR"
AUTH_ARGS=()
if [ "$AUTH_ENABLED" = true ]; then
  : "${MONGO_PASSWORD:?MongoDB password is required}"
  AUTH_ARGS+=(--username="$MONGO_USER" --password="$MONGO_PASSWORD" --authenticationDatabase="$MONGO_AUTH_DB")
fi
mongosh --host "$MONGO_HOST" --port "$MONGO_PORT" "${AUTH_ARGS[@]}" --quiet --eval '
const excluded = JSON.parse(process.env.EXCLUDED_DATABASES);
const names = process.env.ALL_DATABASES === "true"
  ? db.adminCommand({listDatabases: 1, nameOnly: true}).databases.map(x => x.name)
  : JSON.parse(process.env.DATABASES);
for (const name of names.filter(x => !excluded.includes(x))) print(name);
' > "$BACKUP_DIR/databases.txt"
TIMESTAMP=$(date -u +%Y-%m-%dT%H-%M-%SZ)
count=0
while IFS= read -r database; do
  [ -n "$database" ] || continue
  mongodump --host "$MONGO_HOST" --port "$MONGO_PORT" "${AUTH_ARGS[@]}" \
    --db="$database" --archive="$BACKUP_DIR/$database-$TIMESTAMP.archive.gz" --gzip
  count=$((count + 1))
done < "$BACKUP_DIR/databases.txt"
[ "$count" -gt 0 ] || { echo "No databases were backed up" >&2; exit 1; }
printf '%s\n' "$count" > "$BACKUP_DIR/dump-complete"
echo "MongoDB dump completed: $count database(s)"
