#!/usr/bin/env bash
# test-api.sh
#
# Friendly test runner for the cert-manager API.
#
# Usage:
#   ./test-api.sh health
#   ./test-api.sh list
#   ./test-api.sh add
#   ./test-api.sh delete
#   ./test-api.sh reload
#   ./test-api.sh invalid-path
#   ./test-api.sh invalid-method
#   ./test-api.sh all

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

usage() {
  cat <<'EOF'
Usage: ./test-api.sh {health|list|add|delete|reload|invalid-path|invalid-method|all}

Examples:
  ./test-api.sh health
  ./test-api.sh list
  ./test-api.sh add
  ./test-api.sh delete
  ./test-api.sh reload
  ./test-api.sh all
EOF
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

pretty_print_body() {
  local body="$1"

  if [[ -z "$body" ]]; then
    warn "No response body returned"
    return
  fi

  if command -v jq >/dev/null 2>&1; then
    printf '%s\n' "$body" | jq . 2>/dev/null || printf '%s\n' "$body"
  else
    printf '%s\n' "$body"
  fi
}

run_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  log "Testing ${method} ${endpoint}"
  printf "🌐 URL: %s%s\n" "$BASE_URL" "$endpoint"
  printf "🛡️  mTLS client: %s\n" "$CLIENT_NAME"
  printf "📄 CA: %s\n" "$CA_CERT"
  printf "📄 Client cert: %s\n" "$CLIENT_CERT"
  printf "🔑 Client key: %s\n" "$CLIENT_KEY"

  if [[ -n "$data" ]]; then
    printf "📦 Payload: %s\n" "$data"
  fi

  divider

  local response
  if [[ -n "$data" ]]; then
    response="$(
      "$CURL_BIN" --silent --show-error --include \
        --request "$method" \
        --cacert "$CA_CERT" \
        --cert "$CLIENT_CERT" \
        --key "$CLIENT_KEY" \
        --header "Content-Type: application/json" \
        --data "$data" \
        "${BASE_URL}${endpoint}"
    )"
  else
    response="$(
      "$CURL_BIN" --silent --show-error --include \
        --request "$method" \
        --cacert "$CA_CERT" \
        --cert "$CLIENT_CERT" \
        --key "$CLIENT_KEY" \
        --header "Content-Type: application/json" \
        "${BASE_URL}${endpoint}"
    )"
  fi

  local headers body status_line
  headers="$(printf '%s' "$response" | sed -n '1,/^\r$/p')"
  body="$(printf '%s' "$response" | sed '1,/^\r$/d')"
  status_line="$(printf '%s\n' "$headers" | head -n 1)"

  printf "📨 Status: %s\n" "$status_line"
  printf "\n📋 Response headers\n"
  printf '%s\n' "$headers"

  printf "\n📄 Response body\n"
  pretty_print_body "$body"

  printf "\n"
  divider
}

# ------------------------------------------------------------------------------
# Load configuration
# ------------------------------------------------------------------------------
log "Loading environment"

if [[ ! -f .env ]]; then
  error ".env file not found in the current directory"
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

success "Loaded configuration from .env"

# ------------------------------------------------------------------------------
# Validate required settings
# ------------------------------------------------------------------------------
log "Validating test configuration"

required_vars=(
  REPO_FQDN
  CLIENT_NAME
  API_MTLS_CA_FILE
)

for var in "${required_vars[@]}"; do
  require_non_empty_var "$var"
done

API_PORT="${API_PORT:-8443}"
BASE_URL="https://${REPO_FQDN}:${API_PORT}"

CA_CERT="$API_MTLS_CA_FILE"
CLIENT_CERT="$(dirname "$API_MTLS_CA_FILE")/${CLIENT_NAME}.crt"
CLIENT_KEY="$(dirname "$API_MTLS_CA_FILE")/${CLIENT_NAME}.key"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"

require_file "$CA_CERT" "CA certificate"
require_file "$CLIENT_CERT" "Client certificate"
require_file "$CLIENT_KEY" "Client private key"
require_file "$CURL_BIN" "curl binary"

if command -v jq >/dev/null 2>&1; then
  success "jq detected — JSON responses will be prettified"
else
  warn "jq not found — falling back to raw output"
fi

success "Test prerequisites look good"

log "API target summary"
printf "🌐 Repo FQDN:   %s\n" "$REPO_FQDN"
printf "🔌 API port:    %s\n" "$API_PORT"
printf "🔗 Base URL:    %s\n" "$BASE_URL"
printf "👤 Client CN:   %s\n" "$CLIENT_NAME"

divider

# ------------------------------------------------------------------------------
# Command selection
# ------------------------------------------------------------------------------
case "${1:-}" in
  health)
    run_request "GET" "/healthcheck"
    ;;
  list)
    run_request "GET" "/certs"
    ;;
  add)
    run_request "POST" "/certs" '{"fqdn":"test.example.com","dns_provider":"cloudflare","email":"admin@example.com"}'
    ;;
  delete)
    run_request "DELETE" "/certs?fqdn=test.example.com"
    ;;
  reload)
    run_request "POST" "/reload"
    ;;
  invalid-path)
    run_request "GET" "/this-path-does-not-exist"
    ;;
  invalid-method)
    run_request "PATCH" "/healthcheck"
    ;;
  all)
    run_request "GET" "/healthcheck"
    run_request "GET" "/certs"
    run_request "POST" "/certs" '{"fqdn":"test.example.com","dns_provider":"cloudflare","email":"admin@example.com"}'
    run_request "GET" "/certs"
    run_request "DELETE" "/certs?fqdn=test.example.com"
    run_request "POST" "/reload"
    ;;
  *)
    usage
    exit 1
    ;;
esac