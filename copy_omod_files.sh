#!/bin/bash

# Source directory where the .omod files are located
SOURCE_DIR="./modules"

# Target directory where the files will be copied
TARGET_DIR="/var/lib/docker/volumes/ssemr_openmrs-data/_data/modules"

# Docker service name
DOCKER_SERVICE="backend"

# Check if the source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

# Check if the target directory exists
if [ ! -d "$TARGET_DIR" ]; then
  echo "Target directory does not exist: $TARGET_DIR"
  exit 1
fi

# Copy .omod files from the source directory to the target directory
echo "Copying .omod files from $SOURCE_DIR to $TARGET_DIR..."
cp "$SOURCE_DIR"/*.omod "$TARGET_DIR"

# Verify if the copy was successful
if [ $? -eq 0 ]; then
  echo "Files copied successfully."
else
  echo "An error occurred while copying the files."
  exit 1
fi

# Restart the Docker container
echo "Restarting Docker service: $DOCKER_SERVICE..."
docker compose restart $DOCKER_SERVICE

# Verify if the restart was successful
if [ $? -eq 0 ]; then
  echo "Docker service restarted successfully."
else
  echo "An error occurred while restarting the Docker service."
  exit 1
fi