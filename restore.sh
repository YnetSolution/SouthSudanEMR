#!/bin/bash

# Load environment variables from .env file
if [ -f .env ]; then
  export $(cat .env | xargs)
else
  echo ".env file not found."
  exit 1
fi

# Variables
LOCAL_DIR="$HOME/Data_Backup"
BACKUP_DIR="/opt"

# Find the latest .sql file in the local backup directory
LATEST_BACKUP=$(ls -t "$LOCAL_DIR"/*.sql 2>/dev/null | head -n 1)

# Check if a backup file was found
if [ -z "$LATEST_BACKUP" ]; then
  echo "No SQL backup file found in $LOCAL_DIR."
  exit 1
fi

# Extract the filename from the full path
LATEST_BACKUP_FILE=$(basename "$LATEST_BACKUP")

# Check Docker container status
sudo docker ps -a | grep $DB_CONTAINER > /dev/null
if [ $? -ne 0 ]; then
  echo "Docker container $DB_CONTAINER not found."
  exit 1
fi

# Copy the latest SQL file into the Docker container
sudo docker cp "$LATEST_BACKUP" "$DB_CONTAINER:$BACKUP_DIR/"
if [ $? -ne 0 ]; then
  echo "Failed to copy the SQL file to Docker container."
  exit 1
fi

# Restore the database using the latest SQL file
sudo docker exec -it $DB_CONTAINER bash -c "mysql -u $DB_USER -p$DB_PASS $DB_NAME < $BACKUP_DIR/$LATEST_BACKUP_FILE"
if [ $? -ne 0 ]; then
  echo "Database restoration failed."
  exit 1
fi

# Clean up: remove the SQL file inside the Docker container
sudo docker exec $DB_CONTAINER rm "$BACKUP_DIR/$LATEST_BACKUP_FILE"

echo "Database restored successfully from $LATEST_BACKUP_FILE."
exit 0
