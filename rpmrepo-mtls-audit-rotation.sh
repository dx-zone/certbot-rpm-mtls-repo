#!/bin/bash

################################################################################
# 🛡️  RPM REPOSITORY mTLS LIFECYCLE & VALIDATION TOOL
#
# 📝 DESCRIPTION:
# This script automates the complete rotation and validation of Mutual TLS (mTLS)
# material for the 'rpmrepo' service. It regenerates the internal Root CA and
# client certificates, synchronizes them with the Apache web server, and
# performs an end-to-end cryptographic handshake to ensure service availability.
#
# 🚀 WHY IT MATTERS:
# 1. SECURITY: Ensures that only clients with valid, non-expired certificates
#    can access or download RPM packages, preventing unauthorized repo access.
# 2. INTEGRITY: Prevents "Handshake Failed" errors by ensuring Apache's memory
#    buffer and the filesystem certificates are perfectly synchronized via
#    graceful reloads.
# 3. AUTOMATION: Eliminates manual chmod/chown errors and pathing mistakes
#    that typically lead to Curl Exit Code 56 or 58.
#
# 🛠️  HOW TO USE:
# 1. Ensure '.env' contains REPO_FQDN and CLIENT_NAME.
# 2. Run the script: ./generate_new_mtls_material_rpmrepo.sh
# 3. If successful, use the generated 'secrets/' material for client authentication.
################################################################################

# --- 🎨 Styling & Emojis ---
TICK="✅"
CROSS="❌"
GEAR="⚙️"
LOCK="🔒"
LOOK="🔍"
FILE="📄"
TREE="🌳"
TIME_STAMP=$(date "+%Y-%m-%d %H:%M:%S")

B_BLUE='\033[1;34m'
B_GREEN='\033[1;32m'
B_RED='\033[1;31m'
B_YELLOW='\033[1;33m'
B_CYAN='\033[1;36m'
NC='\033[0m'

# --- 📝 Logging Functions ---
log_stage()   { printf "\n${B_BLUE}[%-10s] ${GEAR}  STAGE: %s${NC}\n" "$(date "+%T")" "$1"; }
log_success() { printf "${B_GREEN}[%-10s] ${TICK}  PASS:  %s${NC}\n" "$(date "+%T")" "$1"; }
log_fail()    { printf "${B_RED}[%-10s] ${CROSS}  FAIL:  %s${NC}\n" "$(date "+%T")" "$1"; exit 1; }
log_info()    { printf "[%-10s] ${LOCK}  INFO:  %s\n" "$(date "+%T")" "$1"; }

clear
printf "${B_YELLOW}================================================================${NC}\n"
printf "🛡️  RPM REPO mTLS LIFECYCLE & CONFIGURATION AUDIT\n"
printf "Init: %s\n" "$TIME_STAMP"
printf "${B_YELLOW}================================================================${NC}\n"

# --- 📂 1. Environment Injection ---
ENV_FILE="./.env"
if [ -f "$ENV_FILE" ]; then
    log_stage "Loading Environment Configuration"
    set -a
    source <(grep -v -E '^[[:space:]]*(#|$)' "$ENV_FILE")
    set +a
    log_success "Environment variables injected from $ENV_FILE"
else
    log_fail "Critical Error: .env file missing at $ENV_FILE"
fi

# Mandatory Variable Check
: "${CLIENT_NAME:?Error: CLIENT_NAME must be defined in .env}"
: "${REPO_FQDN:?Error: REPO_FQDN must be defined in .env}"

# Construct Absolute Paths
PROJECT_ROOT=$(pwd)
PKI_DIR="${PROJECT_ROOT}/secrets/rpmrepo-secrets/pki_mtls_material"
TEST_CERT="${PKI_DIR}/${CLIENT_NAME}.crt"
TEST_KEY="${PKI_DIR}/${CLIENT_NAME}.key"

# --- 🐳 2. Remote PKI Regeneration ---
log_stage "Executing Remote PKI Rotation"
if ! docker ps --format '{{.Names}}' | grep -q "^rpmrepo$"; then
    log_fail "Container 'rpmrepo' is not running."
fi

docker exec -it rpmrepo bash -c "
    set -e
    printf \"${B_CYAN}${GEAR}  Regenerating mTLS material for: ${CLIENT_NAME}${NC}\n\"
    rm -rf /etc/httpd/certs/*
    ./generate_mtls_client_ca.sh > /dev/null 2>&1

    printf \"\n${B_CYAN}${TREE}  GENERATED PKI MATERIAL (STRUCTURE):${NC}\n\"
    printf \"${B_CYAN}----------------------------------------------------------------${NC}\n\"
    ls -lah /etc/httpd/certs/
    printf \"${B_CYAN}----------------------------------------------------------------${NC}\n\"

    printf \"\n${B_GREEN}${LOOK}  Syntax Check:${NC} \"
    /usr/sbin/httpd -t
" || log_fail "Internal container execution failed."

# --- ♻️ 3. Force Apache Reload ---
log_stage "Applying Configuration Changes"
log_info "Triggering graceful restart to load new CA material..."

if docker exec rpmrepo /usr/sbin/httpd -k graceful; then
    log_success "Apache reload signaled successfully."
    sleep 2
else
    log_fail "Failed to reload Apache configuration."
fi

# --- 🔍 4. Dynamic Handshake Validation ---
log_stage "End-to-End mTLS & Web Access Audit"

log_info "Verifying Identity : ${CLIENT_NAME}"
log_info "Target Endpoint   : https://localhost/rpms/"

# Fix local permissions proactively
if [ ! -r "$TEST_KEY" ]; then
    log_info "Local key permissions restricted. Fixing..."
    sudo chmod 644 "$TEST_KEY" "$TEST_CERT"
fi

# Execute mTLS handshake test
HTTP_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" \
    --retry 3 --retry-delay 2 \
    --cert "$TEST_CERT" \
    --key "$TEST_KEY" \
    https://localhost/rpms/)

CURL_RESULT=$?

# --- 🏆 5. Final Assessment ---
printf "\n"
if [[ "$HTTP_STATUS" =~ ^(200|301|302)$ ]]; then
    log_success "mTLS Authenticated Session established (HTTP $HTTP_STATUS)."
    log_info "The repository is serving content correctly."
elif [ "$CURL_RESULT" -eq 56 ]; then
    log_fail "mTLS Alert: Server rejected certificate (Code 56). Check Apache SSLCACertificateFile."
elif [ "$CURL_RESULT" -eq 58 ]; then
    log_fail "Curl Error 58: Local key/cert unreadable. Check project-level permissions."
else
    log_fail "Audit Failed. HTTP: $HTTP_STATUS | Curl Error: $CURL_RESULT"
fi

printf "${B_GREEN}================================================================${NC}\n"
printf "${TICK}  ${B_GREEN}DEPLOYMENT READY: %s SECURED via mTLS${NC}\n" "${REPO_FQDN}"
printf "${B_GREEN}================================================================${NC}\n"
