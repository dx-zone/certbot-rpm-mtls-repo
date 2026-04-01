#!/bin/bash
# test-api.sh - Comprehensive Testing Suite for Certbot Manager API
# Usage: ./test-api.sh [health|list|add|delete|invalid-path|invalid-method]

# --- Configuration ---
PKI_DIR="/opt/certbot/secrets/rpmrepo-secrets/pki_mtls_material"
API_HOST="repo.example.com"
API_PORT="8443"
BASE_URL="https://${API_HOST}:${API_PORT}"

# --- Colors for Output ---
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Check if mTLS keys exist before starting
if [[ ! -f "${PKI_DIR}/client-identity.key" ]]; then
    echo -e "${RED}Error: mTLS client keys not found in ${PKI_DIR}${NC}"
    exit 1
fi

run_curl() {
    local METHOD=$1
    local PATH=$2
    local DATA=$3
    
    # HARDCODE the path here to bypass $PATH issues
    local CURL_BIN="/usr/bin/curl"

    echo -e "${GREEN}==> Testing $METHOD $PATH${NC}"
    
    "$CURL_BIN" -i -s -X "$METHOD" \
      --cacert "${PKI_DIR}/ca.crt" \
      --cert "${PKI_DIR}/client-identity.crt" \
      --key "${PKI_DIR}/client-identity.key" \
      -H "Content-Type: application/json" \
      ${DATA:+-d "$DATA"} \
      "${BASE_URL}${PATH}"
    
    echo -e "\n--------------------------------------------------\n"
}
# --- Test Selection Logic ---
case "$1" in
    "health")
        run_curl "GET" "/healthcheck" "| jq ."
        ;;
    "list")
        run_curl "GET" "/certs" "| jq ."
        ;;
    "add")
        # Example JSON payload for creating a certificate entry
        PAYLOAD='{"fqdn":"test.example.com", "dns_provider":"cloudflare", "email":"admin@example.com"}'
        run_curl "POST" "/certs" "$PAYLOAD" "| jq ."
        ;;
    "delete")
        # Testing deletion via query parameter
        run_curl "DELETE" "/certs?fqdn=test.example.com" "| jq ."
        ;;
    "invalid-path")
        run_curl "GET" "/this-path-does-not-exist" "| jq ."
        ;;
    "invalid-method")
        # Testing a method the route doesn't support
        run_curl "PATCH" "/healthcheck" "| jq ."
        ;;
    "reload")
        run_curl "POST" "/reload"
        ;;
    *)
        echo "Usage: $0 {health|list|add|delete|reload|invalid-path|invalid-method}"
        echo "Example: $0 reload"
        exit 1
    ;;
esac