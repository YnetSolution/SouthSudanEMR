#!/bin/bash
#
# Restores the OpenMRS database from a backup made by the backup service (or by the old backup
# scripts). Run from the project folder on the server:
#
#   ./restore.sh                 restore the newest backup
#   ./restore.sh <file>          restore a specific .sql or .sql.gz file
#
# Backups are looked for in BACKUP_HOST_DIR (default ./backups, where the backup service writes) and
# then in ~/Data_Backup, where the old scripts wrote. The database's own root login is used, so no
# credentials need to be configured. This REPLACES the current data, so OpenMRS is stopped first.

set -euo pipefail

BACKUP_DIRS=("${BACKUP_HOST_DIR:-./backups}" "$HOME/Data_Backup")
DB_NAME="${OPENMRS_DB_NAME:-openmrs}"

if docker compose version >/dev/null 2>&1; then COMPOSE="docker compose"; else COMPOSE="docker-compose"; fi

if [ $# -ge 1 ]; then
  BACKUP="$1"
else
  BACKUP=$(ls -t $(for d in "${BACKUP_DIRS[@]}"; do printf '%s/*.sql %s/*.sql.gz ' "$d" "$d"; done) 2>/dev/null | head -n 1 || true)
fi

if [ -z "${BACKUP:-}" ] || [ ! -f "$BACKUP" ]; then
  echo "No backup found (looked in: ${BACKUP_DIRS[*]})."
  exit 1
fi

echo "This will REPLACE the '$DB_NAME' database with: $BACKUP"
read -r -p "Type RESTORE to continue: " answer
[ "$answer" = "RESTORE" ] || { echo "Cancelled."; exit 1; }

echo "Stopping OpenMRS while the database is restored..."
$COMPOSE stop backend

echo "Restoring..."
if [[ "$BACKUP" == *.gz ]]; then
  gzip -dc "$BACKUP" | $COMPOSE exec -T db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '$DB_NAME'"
else
  $COMPOSE exec -T db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '$DB_NAME'" < "$BACKUP"
fi

echo "Starting OpenMRS..."
$COMPOSE start backend

echo "Database restored from $(basename "$BACKUP")."
