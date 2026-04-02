#!/bin/sh
# 00-envsubst-https-config.sh

set -e

log() {
  printf "\n🔹 %s\n" "$1"
}

success() {
  printf "✅ %s\n" "$1"
}

error() {
  printf "❌ %s\n" "$1" >&2
}

divider() {
  printf "----------------------------------------\n"
}

# 1. Wait for SSL certs
log "Waiting for SSL certificates for: ${REPO_FQDN}"
while [ ! -f /etc/nginx/ssl/fullchain.pem ]; do
  printf "⏳ Still waiting for certificates...\n"
  sleep 5
done
success "Certificates detected"

divider

# 2. Define config paths and variables for envsubst
TARGET_CONF="/etc/nginx/conf.d/default.conf" # This is the default location where Nginx looks for server configs. Ensure this gets removed in the Dockerfile and matches the path used in the Nginx configuration.
TEMPLATE_FILE="/etc/nginx/templates/default.conf.template" # Ensure this matches the path in the Dockerfile COPY command for docker to copy the template into the container after the original default.conf is removed.

log "Preparing Nginx configuration"
printf "📄 Template: %s\n" "$TEMPLATE_FILE"
printf "📍 Target:   %s\n" "$TARGET_CONF"

# Remove existing config
rm -f "$TARGET_CONF"
success "Old config (if any) removed"

divider

# 3. Generate config from template using envsubst
log "Generating configuration from template"
printf "🌐 Domain: %s\n" "$REPO_FQDN"

VARS_TO_SUBSTITUTE='${REPO_FQDN} ${SWAGGER_JSON_URL}'

envsubst "$VARS_TO_SUBSTITUTE" < "$TEMPLATE_FILE" > "$TARGET_CONF"

success "Configuration generated"

divider

# 4. Validate output
log "Validating generated configuration"

if [ ! -f "$TARGET_CONF" ]; then
  error "Config file was NOT created: $TARGET_CONF"
  exit 1
fi

if [ ! -s "$TARGET_CONF" ]; then
  error "Config file is empty: $TARGET_CONF"
  exit 1
fi

success "Config file exists and is not empty"

divider

# 5. Output config (debug)
log "Final generated configuration"
cat "$TARGET_CONF"

divider

success "Nginx HTTPS setup complete. Swagger UI ready 🚀"