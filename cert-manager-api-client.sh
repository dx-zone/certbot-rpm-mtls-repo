#!/usr/bin/env bash
# cert-manager-api-client.sh
#
# Friendly mTLS test runner for the cert-manager API.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

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

Examples:
  ./cert-manager-api-client.sh health
  ./cert-manager-api-client.sh list
  ./cert-manager-api-client.sh add --fqdn test.com --dns cloudflare --email admin@test.com
  ./cert-manager-api-client.sh delete --fqdn test.com
  ./cert-manager-api-client.sh reload
  ./cert-manager-api-client.sh all
USAGE_EOF
}

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

load_env_config() {
  local env_file="$1"

  log "Loading environment from $env_file"

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
    printf "   API_PORT=8000\n\n"

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
    printf "   This script depends on .env for API endpoint and mTLS configuration.\n"
    printf "   Without it, requests cannot be executed.\n\n"

    exit 1
  fi

  # Load environment
  set -a
  # shellcheck disable=SC1091
  source "$env_file"
  set +a

  success "Loaded configuration from $env_file"
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

run_request() {
  local method="$1"
  local endpoint="$2"
  local data="${3:-}"

  log "Testing ${method} ${endpoint}"
  printf "🌐 URL: %s%s\n" "$BASE_URL" "$endpoint"
  printf "🛡️  API mTLS client: %s\n" "$API_MTLS_CLIENT_NAME_EFFECTIVE"
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

main() {
  local payload

  case "$COMMAND" in
    health)
      run_request "GET" "/healthcheck" # This endpoint should be implemented by the API to provide a simple health check. It should return a 200 OK status if the API is healthy, and may include a simple JSON body with status information.
      ;;
    list)
      run_request "GET" "/certs" # This endpoint should return a list of all certificates managed by the API.
      ;;
    add)
      payload="$(build_add_payload "$FQDN" "$DNS_PROVIDER" "$EMAIL")"
      run_request "POST" "/certs" "$payload" # This endpoint should create a new certificate with the provided FQDN, DNS provider, and email.
      ;;
    delete)
      run_request "DELETE" "/certs?fqdn=${FQDN}" # This endpoint should delete the certificate associated with the provided FQDN.
      ;;
    reload)
      run_request "POST" "/reload" # This endpoint should reload the API configuration or certificates.
      ;;
    invalid-path)
      run_request "GET" "/this-path-does-not-exist" # This endpoint should return a 404 Not Found status.

      ;;
    invalid-method)
      run_request "PATCH" "/healthcheck" # This endpoint should return a 405 Method Not Allowed status.
      ;;
    # Run through a sequence of tests to demonstrate the API functionality. It will use the default test values.
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

#----------------------------------------------------------------------------
# Load environment configuration and validate prerequisites
# This section will load the .env file, set up variables, and perform
# validation checks to ensure that all required configuration is present and
# valid before running any tests.
# This includes checking for required environment variables, verifying that
# necessary files (like certificates) exist, and validating the format of
# critical values like FQDNs and email addresses.
#----------------------------------------------------------------------------
load_env_config "$ENV_FILE"

API_MTLS_CLIENT_NAME_EFFECTIVE="${API_MTLS_CLIENT_NAME:-${RPMREPO_MTLS_CLIENT_NAME:-${CLIENT_NAME:-cert-manager-automation-client}}}"

API_PORT="${API_PORT:-8000}"
BASE_URL="https://${REPO_FQDN}:${API_PORT}"

CA_CERT="${API_MTLS_CA_FILE}"
CLIENT_CERT="$(dirname "$CA_CERT")/${API_MTLS_CLIENT_NAME_EFFECTIVE}.crt"
CLIENT_KEY="$(dirname "$CA_CERT")/${API_MTLS_CLIENT_NAME_EFFECTIVE}.key"
CURL_BIN="${CURL_BIN:-/usr/bin/curl}"

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

require_file "$CA_CERT" "CA certificate"
require_file "$CLIENT_CERT" "Client certificate"
require_file "$CLIENT_KEY" "Client private key"
require_file "$CURL_BIN" "curl binary"

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
printf "📄 CA file:        %s\n" "$CA_CERT"
printf "📄 Client cert:    %s\n" "$CLIENT_CERT"
printf "🔑 Client key:     %s\n" "$CLIENT_KEY"
printf "🧪 Test FQDN:      %s\n" "$TEST_FQDN"
printf "🧪 Test DNS:       %s\n" "$TEST_DNS_PROVIDER"
printf "🧪 Test email:     %s\n" "$TEST_EMAIL"

divider

parse_args "$@"
main