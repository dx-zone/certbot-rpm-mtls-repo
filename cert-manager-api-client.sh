#!/usr/bin/env bash
################################################################################
# 🔐 cert-manager-api-client.sh
# ------------------------------------------------------------------------------
# Purpose:
#   Friendly mTLS-aware client for testing and interacting with the
#   cert-manager API.
#
# What this script does:
#   - Loads endpoint and client identity settings from .env as defaults only
#   - Preserves pre-exported runtime overrides from a wrapper or caller
#   - Uses a client certificate and private key for mTLS authentication
#   - Uses the system trust store by default for server TLS validation
#   - Optionally uses a dedicated server CA bundle when API_SERVER_CA_FILE is set
#
# Trust model:
#   - API_MTLS_CA_FILE is used to locate the client certificate/key material
#   - API_SERVER_CA_FILE, when set, is used to verify the API server certificate
#   - If API_SERVER_CA_FILE is unset, curl uses the operating system CA trust
#
# Precedence model:
#   1. Already-exported environment variables (for example from GPG wrapper)
#   2. .env values
#   3. Built-in defaults
#
# Notes:
#   - This script is designed for both public-TLS and internal/private-TLS API
#     endpoints.
#   - In environments where the API server uses a public certificate
#     (for example Let's Encrypt), leave API_SERVER_CA_FILE unset.
################################################################################

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

###############################################################################
# Output helpers
###############################################################################
log() {
  printf "\n🔹 %s\n" "$1"
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

###############################################################################
# Usage
###############################################################################
usage() {
  cat <<'USAGE_EOF'
Usage: ./cert-manager-api-client.sh {health|list|add|delete|reload|invalid-path|invalid-method|all} [options]

Commands:
  health          Check API health
  list            List all certificates
  add             Add a certificate (requires --fqdn, --dns, and --email)
  delete          Delete a certificate (requires --fqdn)
  reload          Trigger cert-manager reload
  invalid-path    Test request to an invalid path
  invalid-method  Test request with an invalid HTTP method
  all             Run all tests in sequence using default test values

Options:
  --fqdn VALUE            Domain/FQDN to add or delete
  --dns VALUE             DNS provider (alias of --dns-provider)
  --dns-provider VALUE    DNS provider
  --email VALUE           Contact email for certificate registration

Environment:
  REPO_FQDN               API server hostname
  API_PORT                API server port (default: 8000)
  API_MTLS_CA_FILE        API mTLS CA file path; also used to derive client cert/key
  API_MTLS_CLIENT_NAME    Client CN used to derive client cert/key filenames
  API_SERVER_CA_FILE      Optional CA bundle for verifying the API server cert
  CURL_BIN                Optional curl binary path override

Examples:
  ./cert-manager-api-client.sh health
  ./cert-manager-api-client.sh list
  ./cert-manager-api-client.sh add --fqdn test.com --dns cloudflare --email admin@test.com
  ./cert-manager-api-client.sh delete --fqdn test.com
  ./cert-manager-api-client.sh reload
  ./cert-manager-api-client.sh all
USAGE_EOF
}

###############################################################################
# Validation helpers
###############################################################################
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

is_valid_fqdn() {
  local fqdn="$1"

  [[ -n "$fqdn" ]] || return 1
  [[ ${#fqdn} -le 253 ]] || return 1
  [[ "$fqdn" != *" "* ]] || return 1
  [[ "$fqdn" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

is_valid_email() {
  local email="$1"

  [[ -n "$email" ]] || return 1
  [[ "$email" != *" "* ]] || return 1
  [[ "$email" =~ ^[[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}$ ]]
}

is_valid_dns_provider() {
  local provider="$1"

  [[ -n "$provider" ]] || return 1
  [[ "$provider" =~ ^[A-Za-z0-9._-]+$ ]]
}

###############################################################################
# .env loading
###############################################################################
strip_wrapping_quotes() {
  local value="$1"

  if [[ "$value" =~ ^\".*\"$ ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" =~ ^\'.*\'$ ]]; then
    value="${value:1:${#value}-2}"
  fi

  printf '%s' "$value"
}

load_env_defaults() {
  local env_file="$1"

  log "Loading environment defaults from $env_file"

  if [[ ! -f "$env_file" ]]; then
    error "Missing required configuration file: $env_file"
    printf "\n"

    printf "📁 Expected location:\n"
    printf "   %s\n\n" "$(realpath -m "$env_file" 2>/dev/null || echo "$env_file")"

    printf "📌 Required variables (minimum):\n"
    printf "   REPO_FQDN=your-api-domain.com\n"
    printf "   API_MTLS_CA_FILE=/path/to/mtls/ca.crt\n\n"

    printf "📌 Common optional variables:\n"
    printf "   API_MTLS_CLIENT_NAME=cert-manager-automation-client\n"
    printf "   API_PORT=8000\n"
    printf "   API_SERVER_CA_FILE=/path/to/server-ca-bundle.crt\n\n"

    printf "🧪 Used by 'all' test flow:\n"
    printf "   FQDN_CSV_ENTRY=test.example.com\n"
    printf "   DNS_PROVIDER=cloudflare\n"
    printf "   EMAIL=admin@example.com\n\n"

    printf "💡 Quick fix:\n"
    if [[ -f "$(dirname "$env_file")/.env.example" ]]; then
      printf "   cp .env.example %s\n\n" "$env_file"
    else
      printf "   Create the file manually with the variables above\n\n"
    fi

    printf "⚠️  Note:\n"
    printf "   This script depends on .env for API endpoint defaults and local fallback configuration.\n"
    printf "   Wrapper/runtime exported variables take precedence when present.\n\n"

    exit 1
  fi

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    [[ -z "$raw_line" ]] && continue
    [[ "$raw_line" =~ ^[[:space:]]*# ]] && continue
    [[ "$raw_line" != *=* ]] && continue

    local key="${raw_line%%=*}"
    local value="${raw_line#*=}"

    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="$(strip_wrapping_quotes "$value")"

    [[ -n "$key" ]] || continue

    # Preserve values already exported by wrapper/caller.
    if [[ -z "${!key+x}" ]]; then
      export "$key=$value"
    fi
  done < "$env_file"

  success "Loaded configuration defaults from $env_file"
}

###############################################################################
# JSON helpers
###############################################################################
json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

build_add_payload() {
  local fqdn_escaped dns_escaped email_escaped
  fqdn_escaped="$(json_escape "$1")"
  dns_escaped="$(json_escape "$2")"
  email_escaped="$(json_escape "$3")"

  printf '{"fqdn":"%s","dns_provider":"%s","email":"%s"}' \
    "$fqdn_escaped" "$dns_escaped" "$email_escaped"
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

###############################################################################
# Argument parsing
###############################################################################
validate_add_args() {
  [[ -n "$FQDN" ]] || { error "--fqdn is required for 'add'"; exit 1; }
  [[ -n "$DNS_PROVIDER" ]] || { error "--dns or --dns-provider is required for 'add'"; exit 1; }
  [[ -n "$EMAIL" ]] || { error "--email is required for 'add'"; exit 1; }

  is_valid_fqdn "$FQDN" || { error "Invalid domain/FQDN for --fqdn: $FQDN"; exit 1; }
  is_valid_dns_provider "$DNS_PROVIDER" || { error "Invalid DNS provider for --dns/--dns-provider: $DNS_PROVIDER"; exit 1; }
  is_valid_email "$EMAIL" || { error "Invalid contact email for --email: $EMAIL"; exit 1; }
}

validate_delete_args() {
  [[ -n "$FQDN" ]] || { error "--fqdn is required for 'delete'"; exit 1; }
  is_valid_fqdn "$FQDN" || { error "Invalid domain/FQDN for --fqdn: $FQDN"; exit 1; }
}

parse_args() {
  COMMAND="${1:-}"
  shift || true

  FQDN=""
  DNS_PROVIDER=""
  EMAIL=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --fqdn)
        [[ $# -ge 2 ]] || { error "Missing value for --fqdn"; exit 1; }
        FQDN="$2"
        shift 2
        ;;
      --dns|--dns-provider)
        [[ $# -ge 2 ]] || { error "Missing value for $1"; exit 1; }
        DNS_PROVIDER="$2"
        shift 2
        ;;
      --email)
        [[ $# -ge 2 ]] || { error "Missing value for --email"; exit 1; }
        EMAIL="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  case "$COMMAND" in
    add)
      validate_add_args
      ;;
    delete)
      validate_delete_args
      ;;
    health|list|reload|invalid-path|invalid-method|all)
      :
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

###############################################################################
# Request execution
###############################################################################
run_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  log "Testing ${method} ${endpoint}"
  printf "🌐 URL: %s%s\n" "$BASE_URL" "$endpoint"
  printf "🛡️  API mTLS client: %s\n" "$API_MTLS_CLIENT_NAME_EFFECTIVE"
  printf "📄 API mTLS CA file: %s\n" "$CA_CERT"
  printf "📄 Client cert: %s\n" "$CLIENT_CERT"
  printf "🔑 Client key: %s\n" "$CLIENT_KEY"
  if [[ -n "$SERVER_CA_CERT" ]]; then
    printf "🌐 Server CA bundle: %s\n" "$SERVER_CA_CERT"
  else
    printf "🌐 Server CA bundle: system trust store\n"
  fi

  if [[ -n "$data" ]]; then
    printf "📦 Payload: %s\n" "$data"
  fi

  divider

  local -a curl_args
  curl_args=(
    --silent
    --show-error
    --include
    --request "$method"
    --cert "$CLIENT_CERT"
    --key "$CLIENT_KEY"
    --header "Content-Type: application/json"
  )

  if [[ -n "$SERVER_CA_CERT" ]]; then
    curl_args+=( --cacert "$SERVER_CA_CERT" )
  fi

  if [[ -n "$data" ]]; then
    curl_args+=( --data "$data" )
  fi

  local response
  response="$(
    "$CURL_BIN" "${curl_args[@]}" "${BASE_URL}${endpoint}"
  )"

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

main() {
  local payload

  case "$COMMAND" in
    health)
      run_request "GET" "/healthcheck"
      ;;
    list)
      run_request "GET" "/certs"
      ;;
    add)
      payload="$(build_add_payload "$FQDN" "$DNS_PROVIDER" "$EMAIL")"
      run_request "POST" "/certs" "$payload"
      ;;
    delete)
      run_request "DELETE" "/certs?fqdn=${FQDN}"
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
      payload="$(build_add_payload "$TEST_FQDN" "$TEST_DNS_PROVIDER" "$TEST_EMAIL")"
      run_request "GET" "/healthcheck"
      run_request "GET" "/certs"
      run_request "POST" "/certs" "$payload"
      run_request "GET" "/certs"
      run_request "DELETE" "/certs?fqdn=${TEST_FQDN}"
      run_request "GET" "/certs"
      run_request "POST" "/reload"
      ;;
  esac
}

###############################################################################
# Bootstrap
###############################################################################
load_env_defaults "$ENV_FILE"

# Built-in defaults layered after wrapper/caller env and .env defaults
API_PORT="${API_PORT:-8000}"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"
API_MTLS_CLIENT_NAME="${API_MTLS_CLIENT_NAME:-}"
API_SERVER_CA_FILE="${API_SERVER_CA_FILE:-}"

API_MTLS_CLIENT_NAME_EFFECTIVE="${API_MTLS_CLIENT_NAME:-${RPMREPO_MTLS_CLIENT_NAME:-${CLIENT_NAME:-cert-manager-automation-client}}}"

require_non_empty_var "REPO_FQDN"
require_non_empty_var "API_MTLS_CA_FILE"

CA_CERT="${API_MTLS_CA_FILE}"
CLIENT_CERT="$(dirname "$CA_CERT")/${API_MTLS_CLIENT_NAME_EFFECTIVE}.crt"
CLIENT_KEY="$(dirname "$CA_CERT")/${API_MTLS_CLIENT_NAME_EFFECTIVE}.key"
SERVER_CA_CERT="${API_SERVER_CA_FILE:-}"
BASE_URL="https://${REPO_FQDN}:${API_PORT}"

TEST_FQDN="${FQDN_CSV_ENTRY:-test.example.com}"
TEST_DNS_PROVIDER="${DNS_PROVIDER:-cloudflare}"
TEST_EMAIL="${EMAIL:-admin@example.com}"

log "Validating test configuration"

required_vars=(
  REPO_FQDN
  API_MTLS_CA_FILE
)

for var in "${required_vars[@]}"; do
  require_non_empty_var "$var"
done

require_file "$CA_CERT" "API mTLS CA certificate"
require_file "$CLIENT_CERT" "Client certificate"
require_file "$CLIENT_KEY" "Client private key"
require_file "$CURL_BIN" "curl binary"

if [[ -n "$SERVER_CA_CERT" ]]; then
  require_file "$SERVER_CA_CERT" "Server CA bundle"
fi

is_valid_fqdn "$REPO_FQDN" || { error "Invalid REPO_FQDN in environment: $REPO_FQDN"; exit 1; }
is_valid_fqdn "$TEST_FQDN" || { error "Invalid default test FQDN for 'all': $TEST_FQDN"; exit 1; }
is_valid_dns_provider "$TEST_DNS_PROVIDER" || { error "Invalid default test DNS provider for 'all': $TEST_DNS_PROVIDER"; exit 1; }
is_valid_email "$TEST_EMAIL" || { error "Invalid default test email for 'all': $TEST_EMAIL"; exit 1; }

if command -v jq >/dev/null 2>&1; then
  success "jq detected — JSON responses will be prettified"
else
  warn "jq not found — falling back to raw output"
fi

success "Test prerequisites look good"

log "API target summary"
printf "🌐 Repo FQDN:      %s\n" "$REPO_FQDN"
printf "🔌 API port:       %s\n" "$API_PORT"
printf "🔗 Base URL:       %s\n" "$BASE_URL"
printf "👤 API client CN:  %s\n" "$API_MTLS_CLIENT_NAME_EFFECTIVE"
printf "📄 API mTLS CA:    %s\n" "$CA_CERT"
printf "📄 Client cert:    %s\n" "$CLIENT_CERT"
printf "🔑 Client key:     %s\n" "$CLIENT_KEY"
if [[ -n "$SERVER_CA_CERT" ]]; then
  printf "🌐 Server CA:      %s\n" "$SERVER_CA_CERT"
else
  printf "🌐 Server CA:      system trust store\n"
fi
printf "🧪 Test FQDN:      %s\n" "$TEST_FQDN"
printf "🧪 Test DNS:       %s\n" "$TEST_DNS_PROVIDER"
printf "🧪 Test email:     %s\n" "$TEST_EMAIL"

divider

parse_args "$@"
main