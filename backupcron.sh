#!/bin/bash

# Define the path to the .env file
ENV_FILE="/opt/ssemr/.env"

# Check if the .env file exists and source it
if [ -f $ENV_FILE ]; then
  export $(cat $ENV_FILE | xargs)
else
  echo ".env file not found." | tee -a /opt/ssemr/backup.log
  exit 1
fi

# Variables
BACKUP_DIR="/opt"
DATE=$(date +%d%m%Y_%H%M%S)
BACKUP_FILE="${FACILITY_NAME}_DATA_BACKUP_${DATE}.sql"
LOCAL_DIR="$HOME/Data_Backup"
REMOTE_USER="${REMOTE_USER}"  # Username on the receiving server
REMOTE_HOST="${REMOTE_HOST}"  # Public IP of the receiving server
REMOTE_DIR="${REMOTE_DIR}"  # Destination directory on the receiving server

# Log environment variables for debugging
env >> /opt/ssemr/cron_env.log

# Check Docker container status and log the output
DOCKER_PS_OUTPUT=$(/usr/bin/docker ps -a)
echo "$DOCKER_PS_OUTPUT" | tee -a /opt/ssemr/backup.log

if ! echo "$DOCKER_PS_OUTPUT" | grep -q $DB_CONTAINER; then
  echo "Docker container $DB_CONTAINER not found." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Docker container $DB_CONTAINER is running." | tee -a /opt/ssemr/backup.log
fi

# Create backup inside Docker container and log the output
BACKUP_CMD="mysqldump -u $DB_USER -p$DB_PASS $DB_NAME > $BACKUP_DIR/$BACKUP_FILE"
echo "Running backup command: $BACKUP_CMD" | tee -a /opt/ssemr/backup.log
/usr/bin/docker exec $DB_CONTAINER bash -c "$BACKUP_CMD" 2>&1 | tee -a /opt/ssemr/backup.log
if [ $? -ne 0 ]; then
  echo "Failed to create backup inside Docker container." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Backup created inside Docker container." | tee -a /opt/ssemr/backup.log
fi

# Create local backup directory if it doesn't exist
if [ ! -d "$LOCAL_DIR" ]; then
  mkdir -p "$LOCAL_DIR"
  if [ $? -ne 0 ]; then
    echo "Failed to create local directory $LOCAL_DIR." | tee -a /opt/ssemr/backup.log
    exit 1
  else
    echo "Local directory $LOCAL_DIR created." | tee -a /opt/ssemr/backup.log
  fi
fi

# Identify the latest backup file with the correct naming pattern
LATEST_BACKUP=$(/usr/bin/docker exec $DB_CONTAINER ls -t $BACKUP_DIR | grep -E "^${FACILITY_NAME}_DATA_BACKUP_[0-9]{8}_[0-9]{6}\.sql$" | head -n 1)

# Check if the latest backup file was identified correctly
if [ -z "$LATEST_BACKUP" ]; then
  echo "No backup file found matching the pattern." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Latest backup file identified: $LATEST_BACKUP" | tee -a /opt/ssemr/backup.log
fi

# Copy the latest backup file to the local directory
/usr/bin/docker cp "$DB_CONTAINER:$BACKUP_DIR/$LATEST_BACKUP" "$LOCAL_DIR/"
if [ $? -ne 0 ]; then
  echo "Failed to copy backup file to local directory $LOCAL_DIR." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Backup file copied to local directory $LOCAL_DIR." | tee -a /opt/ssemr/backup.log
fi

# Delete the backup file from the container
/usr/bin/docker exec $DB_CONTAINER rm "$BACKUP_DIR/$LATEST_BACKUP"
if [ $? -ne 0 ]; then
  echo "Failed to delete backup file from Docker container $DB_CONTAINER." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Backup file deleted from Docker container $DB_CONTAINER." | tee -a /opt/ssemr/backup.log
fi

# Send the backup file to the receiving server
scp "$LOCAL_DIR/$LATEST_BACKUP" $REMOTE_USER@$REMOTE_HOST:$REMOTE_DIR
if [ $? -ne 0 ]; then
  echo "Failed to send backup file to the receiving server." | tee -a /opt/ssemr/backup.log
  exit 1
else
  echo "Backup file sent to the receiving server." | tee -a /opt/ssemr/backup.log
fi

echo "Backup completed: $LATEST_BACKUP and file copied to $LOCAL_DIR and sent to $REMOTE_HOST successfully." | tee -a /opt/ssemr/backup.log
exit 0
