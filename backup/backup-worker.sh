#!/usr/bin/env bash
#
# SSEMR backup service.
#
# Settings live in OpenMRS global properties (ssemr.backup.*), edited from System Administration >
# Backups. This loop reads them every POLL_SECONDS and:
#   - backs up at the configured times, or straight away when "Back up now" is pressed;
#   - keeps the newest N copies in /backups (bind-mounted from the host);
#   - sends each copy to the receiving server with scp, using the service's own SSH key;
#   - records runs, local files and its own health in the ssemr_backup database for the dashboard.
#
# The service logs in to MariaDB as root (from the compose environment, as the db service does), so
# no database password is configured or stored anywhere else. The remote server is reached with a key
# generated on first start; its public key is shown on the dashboard.
#
# Settings are only read here; anything this script writes goes to ssemr_backup tables. OpenMRS
# caches global properties, so a value written into global_property behind its back would not be
# seen by the dashboard. The one exception is the first-start import of the old .env values, which
# only inserts properties that do not exist yet.

set -u

DB_HOST="${DB_HOST:-db}"
ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-}"
OPENMRS_DB="${OPENMRS_DB_NAME:-openmrs}"
OPENMRS_USER="${OPENMRS_DB_USER:-openmrs}"
POLL_SECONDS="${POLL_SECONDS:-30}"
BACKUP_DIR=/backups
SSH_DIR=/ssh
KEY="$SSH_DIR/id_ed25519"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
HEARTBEAT=/tmp/backup-worker.heartbeat
VERSION="1.0.0"
# A scheduled time missed while the service was down is still honoured within this window.
CATCH_UP_SECONDS=21600

log() { echo "[backup $(date -u +%FT%TZ)] $*"; }

sql() { MYSQL_PWD="$ROOT_PASSWORD" mariadb --host="$DB_HOST" --user=root --batch --skip-column-names "$@"; }

# Escapes a value for use inside a single-quoted SQL string.
q() {
  local value="${1//\\/\\\\}"
  printf '%s' "${value//\'/\\\'}"
}

declare -A CFG

# ---------------------------------------------------------------- validation (mirrors the module)

valid_facility()  { [[ "$1" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; }
valid_times()     { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9](,([01][0-9]|2[0-3]):[0-5][0-9])*$ ]]; }
valid_host()      { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_user()      { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,31}$ ]]; }
valid_directory() { [[ "$1" =~ ^[A-Za-z0-9._/-]{1,255}$ && "$1" != *..* ]]; }
valid_port()      { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_count()     { [[ "$1" =~ ^[0-9]{1,3}$ ]] && (( $1 >= 1 && $1 <= 365 )); }
valid_timezone()  { [[ "$1" =~ ^[A-Za-z0-9_+/-]{1,64}$ && -f "/usr/share/zoneinfo/$1" ]]; }

# ---------------------------------------------------------------- start-up

wait_for_database() {
  local attempt
  for attempt in $(seq 1 60); do
    sql --execute "SELECT 1" >/dev/null 2>&1 && return 0
    sleep 5
  done
  log "ERROR: cannot log in to $DB_HOST as root; check MYSQL_ROOT_PASSWORD in .env"
  return 1
}

prepare_database() {
  local hosts host grants=""
  hosts=$(sql --execute "SELECT Host FROM mysql.user WHERE User = '$(q "$OPENMRS_USER")'")
  for host in $hosts; do
    grants="$grants GRANT SELECT ON ssemr_backup.* TO '$(q "$OPENMRS_USER")'@'$(q "$host")';"
  done
  sql --execute "
    CREATE DATABASE IF NOT EXISTS ssemr_backup CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE TABLE IF NOT EXISTS ssemr_backup.backup_run (
      id INT AUTO_INCREMENT PRIMARY KEY,
      trigger_type VARCHAR(16) NOT NULL,
      started_at DATETIME NOT NULL,
      finished_at DATETIME,
      status VARCHAR(16) NOT NULL,
      file_name VARCHAR(255),
      size_bytes BIGINT,
      upload_status VARCHAR(16),
      message VARCHAR(2000),
      INDEX idx_started (started_at)
    ) CHARSET = utf8mb4;
    CREATE TABLE IF NOT EXISTS ssemr_backup.backup_file (
      file_name VARCHAR(255) PRIMARY KEY,
      size_bytes BIGINT NOT NULL,
      modified_at DATETIME NOT NULL
    ) CHARSET = utf8mb4;
    CREATE TABLE IF NOT EXISTS ssemr_backup.worker (
      id TINYINT PRIMARY KEY,
      version VARCHAR(32),
      started_at DATETIME,
      heartbeat_at DATETIME,
      public_key VARCHAR(1000),
      free_bytes BIGINT,
      total_bytes BIGINT,
      timezone VARCHAR(64),
      last_run_request BIGINT NOT NULL DEFAULT 0,
      last_test_request BIGINT NOT NULL DEFAULT 0,
      last_scheduled_slot BIGINT NOT NULL DEFAULT 0,
      last_test_at DATETIME,
      last_test_ok TINYINT(1),
      last_test_message VARCHAR(2000),
      last_error VARCHAR(2000)
    ) CHARSET = utf8mb4;
    INSERT IGNORE INTO ssemr_backup.worker (id, last_scheduled_slot) VALUES (1, UNIX_TIMESTAMP());
    UPDATE ssemr_backup.worker SET version = '$VERSION', started_at = NOW() WHERE id = 1;
    $grants
    FLUSH PRIVILEGES;"
}

ensure_key() {
  mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"
  if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "ssemr-backup@${FACILITY_NAME:-facility}" -f "$KEY"
    log "Generated the backup SSH key; add its public key (shown on the dashboard) to the receiving server"
  fi
  touch "$KNOWN_HOSTS"
  sql --execute "UPDATE ssemr_backup.worker SET public_key = '$(q "$(cat "$KEY.pub")")' WHERE id = 1"
}

# One-off: bring the old .env settings into the database so existing servers carry on unchanged.
import_env_settings() {
  local name value rows=""
  declare -A legacy=(
    [facilityName]="${FACILITY_NAME:-}"
    [remoteHost]="${REMOTE_HOST:-}"
    [remoteUser]="${REMOTE_USER:-}"
    [remoteDirectory]="${REMOTE_DIR:-}"
  )
  for name in "${!legacy[@]}"; do
    value="${legacy[$name]}"
    [ -n "$value" ] || continue
    rows="$rows INSERT IGNORE INTO \`$OPENMRS_DB\`.global_property (property, property_value, description, uuid)
      VALUES ('ssemr.backup.$name', '$(q "$value")', 'Imported from .env by the backup service', UUID());"
  done
  if [ -n "${FACILITY_NAME:-}" ]; then
    rows="$rows INSERT IGNORE INTO \`$OPENMRS_DB\`.global_property (property, property_value, description, uuid)
      VALUES ('ssemr.backup.enabled', 'true', 'Imported from .env by the backup service', UUID());"
  fi
  if [ -n "${REMOTE_HOST:-}" ]; then
    rows="$rows INSERT IGNORE INTO \`$OPENMRS_DB\`.global_property (property, property_value, description, uuid)
      VALUES ('ssemr.backup.remoteEnabled', 'true', 'Imported from .env by the backup service', UUID());"
  fi
  [ -n "$rows" ] || return 0
  local before after
  before=$(sql --execute "SELECT COUNT(*) FROM \`$OPENMRS_DB\`.global_property WHERE property LIKE 'ssemr.backup.%'")
  sql --execute "$rows" || return 0
  after=$(sql --execute "SELECT COUNT(*) FROM \`$OPENMRS_DB\`.global_property WHERE property LIKE 'ssemr.backup.%'")
  (( after > before )) && log "Imported $((after - before)) setting(s) from .env; manage them from the dashboard from now on"
  return 0
}

# ---------------------------------------------------------------- settings

load_config() {
  local name value
  CFG=(
    [enabled]="false" [facilityName]="" [times]="02:00" [timezone]="Africa/Juba"
    [retentionCount]="7" [compress]="true" [remoteEnabled]="false" [remoteHost]=""
    [remotePort]="22" [remoteUser]="" [remoteDirectory]="" [runRequestedAt]="0" [testRequestedAt]="0"
  )
  while IFS=$'\t' read -r name value; do
    name="${name#ssemr.backup.}"
    [ -n "${value}" ] && [ "$value" != "NULL" ] && CFG[$name]="$value"
  done < <(sql --execute "SELECT property, property_value FROM \`$OPENMRS_DB\`.global_property
                          WHERE property LIKE 'ssemr.backup.%'" 2>/dev/null)
}

worker_value() { sql --execute "SELECT $1 FROM ssemr_backup.worker WHERE id = 1"; }

# ---------------------------------------------------------------- remote

ssh_options() {
  printf '%s\n' -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$KNOWN_HOSTS"
}

remote_settings_ok() {
  valid_host "${CFG[remoteHost]}" && valid_user "${CFG[remoteUser]}" \
    && valid_directory "${CFG[remoteDirectory]}" && valid_port "${CFG[remotePort]}"
}

test_connection() {
  local requested="$1" ok=0 message
  if ! remote_settings_ok; then
    message="The remote host, user, port or directory is missing or not valid."
  else
    mapfile -t opts < <(ssh_options)
    if message=$(timeout 60 ssh "${opts[@]}" -p "${CFG[remotePort]}" "${CFG[remoteUser]}@${CFG[remoteHost]}" \
        "mkdir -p '${CFG[remoteDirectory]}' && test -w '${CFG[remoteDirectory]}' && echo writable" 2>&1) \
        && [[ "$message" == *writable* ]]; then
      ok=1
      message="Connected as ${CFG[remoteUser]}@${CFG[remoteHost]}; ${CFG[remoteDirectory]} is writable."
    fi
  fi
  sql --execute "UPDATE ssemr_backup.worker SET last_test_request = $requested, last_test_at = NOW(),
                 last_test_ok = $ok, last_test_message = '$(q "${message:0:1900}")' WHERE id = 1"
  log "Connection test: ${message}"
}

upload() {
  local file="$1"
  mapfile -t opts < <(ssh_options)
  timeout 60 ssh "${opts[@]}" -p "${CFG[remotePort]}" "${CFG[remoteUser]}@${CFG[remoteHost]}" \
    "mkdir -p '${CFG[remoteDirectory]}'" 2>&1 \
    && timeout 7200 scp -q "${opts[@]}" -P "${CFG[remotePort]}" "$BACKUP_DIR/$file" \
      "${CFG[remoteUser]}@${CFG[remoteHost]}:${CFG[remoteDirectory]}/" 2>&1
}

# ---------------------------------------------------------------- backup

record_files() {
  local rows="" name size modified
  while IFS=$'\t' read -r name size modified; do
    [ -n "$name" ] || continue
    rows="$rows('$(q "$name")', $size, FROM_UNIXTIME($modified)),"
  done < <(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) \
             -printf '%f\t%s\t%T@\n' 2>/dev/null | sed 's/\.[0-9]*$//')
  local disk
  disk=$(df -P -B1 "$BACKUP_DIR" | awk 'NR==2 {print $4" "$2}')
  sql --execute "DELETE FROM ssemr_backup.backup_file;
    ${rows:+INSERT INTO ssemr_backup.backup_file (file_name, size_bytes, modified_at) VALUES ${rows%,};}
    UPDATE ssemr_backup.worker SET heartbeat_at = NOW(), free_bytes = ${disk%% *}, total_bytes = ${disk##* },
      timezone = '$(q "${CFG[timezone]}")' WHERE id = 1;"
}

prune() {
  local keep="$1" pattern="$2"
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$pattern" -printf '%T@ %f\n' | sort -rn \
    | tail -n +"$((keep + 1))" | cut -d' ' -f2- | while read -r old; do
      rm -f -- "$BACKUP_DIR/$old" && log "Removed old backup $old"
    done
  sql --execute "DELETE FROM ssemr_backup.backup_run WHERE id <= (SELECT id FROM
                   (SELECT id FROM ssemr_backup.backup_run ORDER BY id DESC LIMIT 1 OFFSET 200) t)"
}

# Newer mariadb-dump clients start with "/*!999999\- enable the sandbox mode */", which the
# MariaDB 10.8 client in the database container (used by restore.sh) rejects. It carries no data.
without_sandbox_line() { sed -e '1{/enable the sandbox mode/d;}'; }

run_backup() {
  local trigger="$1" facility="${CFG[facilityName]}" run_id stamp file tmp size status="FAILED" upload_status="SKIPPED" message=""
  run_id=$(sql --execute "INSERT INTO ssemr_backup.backup_run (trigger_type, started_at, status)
                          VALUES ('$trigger', NOW(), 'RUNNING'); SELECT LAST_INSERT_ID();")
  if ! valid_facility "$facility"; then
    message="Set the facility name on the dashboard before backing up."
  else
    stamp=$(TZ="${CFG[timezone]}" date +%d%m%Y_%H%M%S)
    file="${facility}_DATA_BACKUP_${stamp}.sql"
    [ "${CFG[compress]}" = "true" ] && file="$file.gz"
    tmp="$BACKUP_DIR/.${file}.partial"
    log "Backing up $OPENMRS_DB to $file ($trigger)"
    local dump_error
    dump_error=$(mktemp)
    if [ "${CFG[compress]}" = "true" ]; then
      MYSQL_PWD="$ROOT_PASSWORD" mariadb-dump --host="$DB_HOST" --user=root --single-transaction --quick \
        --routines --triggers --hex-blob "$OPENMRS_DB" 2>"$dump_error" | without_sandbox_line | gzip -6 > "$tmp"
      local codes=("${PIPESTATUS[@]}")
      [ "${codes[0]}" -eq 0 ] && [ "${codes[1]}" -eq 0 ] && [ "${codes[2]}" -eq 0 ] && gzip -t "$tmp" 2>>"$dump_error" \
        && zcat "$tmp" | tail -n 1 | grep -q 'Dump completed' && mv "$tmp" "$BACKUP_DIR/$file"
    else
      MYSQL_PWD="$ROOT_PASSWORD" mariadb-dump --host="$DB_HOST" --user=root --single-transaction --quick \
        --routines --triggers --hex-blob "$OPENMRS_DB" 2>"$dump_error" | without_sandbox_line > "$tmp" \
        && [ "${PIPESTATUS[0]}" -eq 0 ] && tail -n 1 "$tmp" | grep -q 'Dump completed' && mv "$tmp" "$BACKUP_DIR/$file"
    fi
    if [ -f "$BACKUP_DIR/$file" ]; then
      status="SUCCESS"
      size=$(stat -c %s "$BACKUP_DIR/$file")
      message="Saved $file"
      if [ "${CFG[remoteEnabled]}" = "true" ]; then
        if ! remote_settings_ok; then
          upload_status="FAILED"
          message="$message; not sent: the remote settings are incomplete."
        elif output=$(upload "$file"); then
          upload_status="SUCCESS"
          message="$message and sent to ${CFG[remoteHost]}."
        else
          upload_status="FAILED"
          message="$message; sending to ${CFG[remoteHost]} failed: ${output:0:800}"
        fi
      fi
    else
      rm -f "$tmp"
      message="The database dump failed: $(head -c 1200 "$dump_error")"
    fi
    rm -f "$dump_error"
    valid_count "${CFG[retentionCount]}" && prune "${CFG[retentionCount]}" "${facility}_DATA_BACKUP_*.sql*"
  fi
  sql --execute "UPDATE ssemr_backup.backup_run SET finished_at = NOW(), status = '$status',
                 file_name = $( [ -n "${file:-}" ] && [ "$status" = SUCCESS ] && echo "'$(q "$file")'" || echo NULL ),
                 size_bytes = ${size:-NULL}, upload_status = '$upload_status', message = '$(q "${message:0:1990}")'
                 WHERE id = $run_id"
  log "Run $run_id: $status, upload $upload_status. $message"
}

# Epoch seconds of the most recent configured time that has passed, or 0.
latest_due_slot() {
  local now slot best=0 time
  now=$(date +%s)
  for time in ${CFG[times]//,/ }; do
    for day in today yesterday; do
      slot=$(TZ="${CFG[timezone]}" date -d "$day $time" +%s 2>/dev/null) || continue
      (( slot <= now && slot > best )) && best=$slot
    done
  done
  echo "$best"
}

# ---------------------------------------------------------------- main loop

main() {
  log "SSEMR backup service $VERSION starting"
  wait_for_database || exit 1
  prepare_database || exit 1
  import_env_settings
  ensure_key
  while true; do
    load_config
    valid_timezone "${CFG[timezone]}" || CFG[timezone]="Africa/Juba"
    touch "$HEARTBEAT"
    record_files 2>/dev/null || log "Could not record the backup files"

    local requested last
    requested="${CFG[testRequestedAt]}"
    last=$(worker_value last_test_request)
    if [[ "$requested" =~ ^[0-9]+$ ]] && (( requested > last )); then
      test_connection "$requested"
    fi

    requested="${CFG[runRequestedAt]}"
    last=$(worker_value last_run_request)
    if [[ "$requested" =~ ^[0-9]+$ ]] && (( requested > last )); then
      sql --execute "UPDATE ssemr_backup.worker SET last_run_request = $requested WHERE id = 1"
      run_backup MANUAL
      record_files 2>/dev/null
    elif [ "${CFG[enabled]}" = "true" ] && valid_times "${CFG[times]}"; then
      local slot last_slot
      slot=$(latest_due_slot)
      last_slot=$(worker_value last_scheduled_slot)
      if (( slot > last_slot && $(date +%s) - slot <= CATCH_UP_SECONDS )); then
        sql --execute "UPDATE ssemr_backup.worker SET last_scheduled_slot = $slot WHERE id = 1"
        run_backup SCHEDULED
        record_files 2>/dev/null
      fi
    fi
    sleep "$POLL_SECONDS"
  done
}

main
