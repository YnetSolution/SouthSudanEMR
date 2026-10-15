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

# The backups folder is private to the containers (group 0, mode 2770), so when this user cannot
# read it, files are listed and read through the backup service's container instead.
FROM_CONTAINER=""
if [ $# -ge 1 ]; then
  BACKUP="$1"
else
  BACKUP=$(ls -t $(for d in "${BACKUP_DIRS[@]}"; do printf '%s/*.sql %s/*.sql.gz ' "$d" "$d"; done) 2>/dev/null | head -n 1 || true)
fi

if [ -z "${BACKUP:-}" ] || [ ! -r "$BACKUP" ]; then
  NAME=$(basename "${BACKUP:-}")
  if [ -z "$NAME" ] || [ "$NAME" = "." ]; then
    NAME=$($COMPOSE exec -T backup sh -c 'ls -t /backups | grep -E "_DATA_BACKUP_[0-9]{8}_[0-9]{6}[.]sql([.]gz)?$" | head -n 1' 2>/dev/null || true)
  fi
  if [ -n "$NAME" ] && $COMPOSE exec -T backup test -f "/backups/$NAME" 2>/dev/null; then
    BACKUP="$NAME"
    FROM_CONTAINER="yes"
  else
    echo "No backup found (looked in: ${BACKUP_DIRS[*]} and the backup service)."
    exit 1
  fi
fi

# Writes the backup's SQL to stdout, wherever it is read from.
read_backup() {
  if [ -n "$FROM_CONTAINER" ]; then
    $COMPOSE exec -T backup cat "/backups/$BACKUP"
  else
    cat "$BACKUP"
  fi
}

echo "This will REPLACE the '$DB_NAME' database with: $BACKUP"
read -r -p "Type RESTORE to continue: " answer
[ "$answer" = "RESTORE" ] || { echo "Cancelled."; exit 1; }

echo "Stopping OpenMRS while the database is restored..."
$COMPOSE stop backend

echo "Restoring..."
if [[ "$BACKUP" == *.gz ]]; then
  read_backup | gzip -dc | $COMPOSE exec -T db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '$DB_NAME'"
else
  read_backup | $COMPOSE exec -T db sh -c "mysql -uroot -p\"\$MYSQL_ROOT_PASSWORD\" '$DB_NAME'"
fi

echo "Starting OpenMRS..."
$COMPOSE start backend

echo "Database restored from $(basename "$BACKUP")."
