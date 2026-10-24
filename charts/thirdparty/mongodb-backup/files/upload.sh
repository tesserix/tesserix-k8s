set -euo pipefail
BACKUP_DIR=${BACKUP_DIR:-/backups}
[ -s "$BACKUP_DIR/dump-complete" ]
shopt -s nullglob
archives=("$BACKUP_DIR"/*.archive.gz)
[ "${#archives[@]}" -gt 0 ]
for archive in "${archives[@]}"; do
  gsutil -q cp "$archive" "gs://$GCS_BUCKET/$GCS_PREFIX/$(basename "$archive")"
done
echo "Backup upload completed: ${#archives[@]} archive(s)"
