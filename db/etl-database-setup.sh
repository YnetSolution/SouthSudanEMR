#!/usr/bin/env bash
#
# Gives the OpenMRS database user what the MAMBA ETL needs, so nobody has to log in to a server
# to create the analysis database or grant privileges by hand.
#
# Run by the one-shot "db-setup" service in docker-compose.yml on every "docker compose up",
# after the database is healthy and before OpenMRS starts. Every statement is safe to repeat.
#
# What it does, as the MariaDB root user:
#   - creates the analysis database (ETL_DATABASE, default ssemr_etl) as utf8mb4, or converts the
#     default character set of an existing one;
#   - grants the OpenMRS user ALL on every database whose name ends in "_etl", so a database
#     renamed from the ETL dashboard is covered as long as it keeps that suffix;
#   - grants SELECT on performance_schema, which the ETL scheduler reads to clear stuck runs;
#   - turns the event scheduler on, which runs the scheduled ETL.
#
# A failure is reported loudly but does not stop OpenMRS from starting: the ETL dashboard then
# shows the permission error, while the EMR itself stays available.

set -u

DB_HOST="${DB_HOST:-db}"
ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
OPENMRS_USER="${OPENMRS_DB_USER:-openmrs}"
ETL_DATABASE="${ETL_DATABASE:-ssemr_etl}"
ETL_DATABASE_PATTERN="${ETL_DATABASE_PATTERN:-%\\_etl}"

log() { echo "[etl-database-setup] $*"; }

if ! [[ "$ETL_DATABASE" =~ ^[A-Za-z0-9_]{1,64}$ && "$OPENMRS_USER" =~ ^[A-Za-z0-9_.-]{1,80}$ ]]; then
  log "ERROR: unusable ETL_DATABASE or OPENMRS_DB_USER; nothing changed."
  exit 0
fi

client=$(command -v mariadb || command -v mysql)
sql() { MYSQL_PWD="$ROOT_PASSWORD" "$client" --host="$DB_HOST" --user=root --batch --skip-column-names "$@"; }

for attempt in $(seq 1 30); do
  if sql --execute "SELECT 1" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 30 ]; then
    log "ERROR: could not log in to $DB_HOST as root; ETL privileges were NOT applied."
    exit 0
  fi
  sleep 2
done

# MYSQL_USER creates the user as 'openmrs'@'%', but cover any other host it was created for.
hosts=$(sql --execute "SELECT Host FROM mysql.user WHERE User = '$OPENMRS_USER'")
if [ -z "$hosts" ]; then
  log "ERROR: database user '$OPENMRS_USER' does not exist; ETL privileges were NOT applied."
  exit 0
fi

statements="
CREATE DATABASE IF NOT EXISTS \`$ETL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
ALTER DATABASE \`$ETL_DATABASE\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
SET GLOBAL event_scheduler = ON;"
for host in $hosts; do
  statements="$statements
GRANT ALL PRIVILEGES ON \`$ETL_DATABASE_PATTERN\`.* TO '$OPENMRS_USER'@'$host';
GRANT SELECT ON performance_schema.* TO '$OPENMRS_USER'@'$host';"
done
statements="$statements
FLUSH PRIVILEGES;"

if output=$(sql --execute "$statements" 2>&1); then
  log "Analysis database '$ETL_DATABASE' is ready; '$OPENMRS_USER' can use databases matching '$ETL_DATABASE_PATTERN'."
else
  log "ERROR: ETL privileges were NOT fully applied: $output"
fi
exit 0
