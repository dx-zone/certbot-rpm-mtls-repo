#!/usr/bin/env bash

################################################################################
# Script Name:  swagger-ui-up.sh
# Author:       Daniel Cruz
# Description:  Deploys a transient Swagger UI container to serve the local 
#               OpenAPI specification for the Certbot Manager API.
# Version:      1.0.0
# Usage:        ./swagger-ui-up.sh
################################################################################

# --- Configuration ---
CONTAINER_NAME="swaggerui"
HOST_PORT=80
TARGET_PORT=8080
SPEC_PATH="/app/api/openapi.json"

# --- UI Formatting ---
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- Execution ---
printf "${BLUE}${BOLD}==>${NC} Refreshing Documentation Service...\n"
printf "    Mapping: %s -> http://localhost:%s\n" "${SPEC_PATH}" "${HOST_PORT}"

# Stop existing instance if running
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    docker stop "${CONTAINER_NAME}" >/dev/null 2>&1
fi

# Launch the Swagger UI container
# --rm: Clean up the container when stopped
# -v:   Bind mount current directory to /app for spec access
docker run --rm \
  --name "${CONTAINER_NAME}" \
  -p "${HOST_PORT}:${TARGET_PORT}" \
  -e "SWAGGER_JSON=${SPEC_PATH}" \
  -v "$(pwd):/app" \
  swaggerapi/swagger-ui
