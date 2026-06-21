#!/bin/bash

# Source directory where the .omod files are located (relative path)
SOURCE_DIR="./modules"

# Docker volume name
DOCKER_VOLUME="ssemr_openmrs-data"

# Check if the source directory exists
if [ ! -d "$SOURCE_DIR" ]; then
  echo "Source directory does not exist: $SOURCE_DIR"
  exit 1
fi

# Copy all .omod files from the source directory to the Docker volume
echo "Copying .omod files from $SOURCE_DIR to Docker volume $DOCKER_VOLUME..."
sudo docker run --rm -v "$DOCKER_VOLUME:/data" -v "$(pwd)/$SOURCE_DIR:/host" busybox sh -c "cp /host/*.omod /data/modules/"

# Verify if the copy was successful
if [ $? -eq 0 ]; then
  echo "Files copied successfully."
else
  echo "An error occurred while copying the files."
  exit 1
fi

# Restart the Docker container
DOCKER_SERVICE="backend"
echo "Restarting Docker service: $DOCKER_SERVICE..."
sudo docker compose restart $DOCKER_SERVICE

# Verify if the restart was successful
if [ $? -eq 0 ]; then
  echo "Docker service restarted successfully."
else
  echo "An error occurred while restarting the Docker service."
  exit 1
fi