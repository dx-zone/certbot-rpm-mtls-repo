#!/usr/bin/env bash
# run-api-server.sh
#
# Starts the certificate manager API with:
# - HTTPS enabled
# - mTLS client validation enabled
# - optional IP allow/deny list support
#
# Expected configuration comes from .env

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------------------------
log() {
  printf "\n🔹 %s\n" "$1"
}

info() {
  printf "ℹ️  %s\n" "$1"
}

success() {
  printf "✅ %s\n" "$1"
}

warn() {
  printf "⚠️  %s\n" "$1"
}

error() {
  printf "❌ %s\n" "$1" >&2
}

divider() {
  printf '%s\n' "------------------------------------------------------------"
}

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
require_file() {
  local file="$1"
  local label="$2"

  if [[ ! -f "$file" ]]; then
    error "$label not found: $file"
    exit 1
  fi
}

require_non_empty_var() {
  local var_name="$1"
  if [[ -z "${!var_name:-}" ]]; then
    error "Required environment variable is missing or empty: $var_name"
    exit 1
  fi
}

ensure_parent_dir() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
}

add_line_if_missing() {
  local value="$1"
  local file="$2"

  touch "$file"

  if ! grep -Fxq "$value" "$file"; then
    printf '%s\n' "$value" >> "$file"
    success "Added allowed client CN: $value"
  else
    info "Allowed client CN already present: $value"
  fi
}

# ------------------------------------------------------------------------------
# Load environment
# ------------------------------------------------------------------------------
log "Loading configuration"

if [[ ! -f .env ]]; then
  error ".env file not found in the current directory"
  info "Create .env before starting the API server"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

success "Environment loaded from .env"

# ------------------------------------------------------------------------------
# Validate required configuration
# ------------------------------------------------------------------------------
log "Validating required settings"

required_vars=(
  REPO_FQDN
  CLIENT_NAME
  API_MTLS_CLIENTS_FILE
  API_MTLS_IPS_FILE
  API_MTLS_CA_FILE
  API_TLS_CERT_FILE
  API_TLS_KEY_FILE
  API_CERT_CSV
  API_CERT_MANAGER
)

for var in "${required_vars[@]}"; do
  require_non_empty_var "$var"
done

success "All required environment variables are present"

# ------------------------------------------------------------------------------
# Prepare runtime files
# ------------------------------------------------------------------------------
log "Preparing mTLS allowlist files"

ensure_parent_dir "$API_MTLS_CLIENTS_FILE"
ensure_parent_dir "$API_MTLS_IPS_FILE"

touch "$API_MTLS_CLIENTS_FILE"
touch "$API_MTLS_IPS_FILE"

success "Allowlist files are ready"

# Keep the client CN list persistent and avoid duplicates
add_line_if_missing "$CLIENT_NAME" "$API_MTLS_CLIENTS_FILE"

if [[ ! -s "$API_MTLS_IPS_FILE" ]]; then
  warn "IP restriction file exists but is currently empty: $API_MTLS_IPS_FILE"
  info "mTLS CN validation will still apply"
fi

# ------------------------------------------------------------------------------
# Validate runtime dependencies
# ------------------------------------------------------------------------------
log "Checking certificate and data files"

require_file "$API_MTLS_CA_FILE" "mTLS CA file"
require_file "$API_TLS_CERT_FILE" "API TLS certificate"
require_file "$API_TLS_KEY_FILE" "API TLS private key"
require_file "./cert-manager-api" "API binary"

if [[ ! -f "$API_CERT_CSV" ]]; then
  warn "Certificate CSV not found yet: $API_CERT_CSV"
  info "The API may still start if it can create or tolerate this file later"
else
  success "Certificate CSV found"
fi

success "Critical runtime files look good"

# ------------------------------------------------------------------------------
# Startup summary
# ------------------------------------------------------------------------------
log "API startup summary"
printf "🌐 Repo FQDN:           %s\n" "$REPO_FQDN"
printf "👤 Allowed client CN:   %s\n" "$CLIENT_NAME"
printf "📄 CN allowlist file:   %s\n" "$API_MTLS_CLIENTS_FILE"
printf "🌍 IP rules file:       %s\n" "$API_MTLS_IPS_FILE"
printf "🛡️  mTLS CA file:        %s\n" "$API_MTLS_CA_FILE"
printf "🔐 TLS cert file:       %s\n" "$API_TLS_CERT_FILE"
printf "🔑 TLS key file:        %s\n" "$API_TLS_KEY_FILE"
printf "📊 Cert CSV:            %s\n" "$API_CERT_CSV"
printf "🛠️  Cert manager:        %s\n" "$API_CERT_MANAGER"

divider
warn "This API currently reuses mTLS-related material from the broader repo PKI layout"
info "That may be intentional for now, but separate identities would be cleaner and safer long-term"

# ------------------------------------------------------------------------------
# Launch
# ------------------------------------------------------------------------------
log "Starting cert-manager-api"

exec ./cert-manager-api \
  -listen ":8000" \
  -tls-cert "$API_TLS_CERT_FILE" \
  -tls-key "$API_TLS_KEY_FILE" \
  -mtls-client-ca "$API_MTLS_CA_FILE" \
  -mtls-allowed-cns "$API_MTLS_CLIENTS_FILE" \
  -ip-list "$API_MTLS_IPS_FILE" \
  -cert-csv "$API_CERT_CSV" \
  -cert-manager "$API_CERT_MANAGER"