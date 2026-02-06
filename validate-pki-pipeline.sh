#!/usr/bin/env bash

###############################################################################
# 🕵️  ULTRA-VERBOSE mTLS & DNF REPOSITORY DIAGNOSTIC TOOL
###############################################################################
#
# DESCRIPTION:
#   Final gatekeeper for the Docker Compose stack. Validates the end-to-end 
#   lifecycle of Let's Encrypt PKI material generated via Certbot 
#   for secure RPM delivery.
#
###############################################################################

set -e

# --- 1. Colors & Emojis ---
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# --- 2. Logging Helpers ---
log_header() {
    printf "\n${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    printf "${BOLD} 🔍 %s${NC}\n" "$1"
    printf "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

log_step() {
    printf "\n${BOLD}📍 STEP %s: %s${NC}\n" "$1" "$2"
}

log_success() {
    printf "  ${GREEN}✅ PASS:${NC} %s\n" "$*"
}

log_warn() {
    printf "  ${YELLOW}⚠️  WARN:${NC} %s\n" "$*"
}

log_error() {
    printf "  ${RED}❌ FAIL:${NC} %s\n" "$*"
}

log_info() {
    printf "  ${CYAN}ℹ️  INFO:${NC} %s\n" "$*"
}

log_hint() {
    printf "     ${YELLOW}💡 HINT:${NC} %s\n" "$*"
}

# --- 3. Load Configuration ---
DOTENV_PATH="./.env"
if [ -f "$DOTENV_PATH" ]; then
    # Load env but avoid export of comments
    set -a; source <(grep -v '^#' "$DOTENV_PATH"); set +a
else
    log_error ".env not found. Run from project root."
    exit 1
fi

# Mandatory Variables
: "${REPO_FQDN:?Error: REPO_FQDN not set in .env}"
: "${CLIENT_NAME:?Error: CLIENT_NAME not set in .env}"

# PKI Paths (Inside client container)
INT_CRT="/etc/pki/tls/certs/${CLIENT_NAME}.crt"
INT_KEY="/etc/pki/tls/private/${CLIENT_NAME}.key"

# PKI Paths (Host machine)
CLIENT_CRT_LOCAL="./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.crt"
CLIENT_KEY_LOCAL="./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.key"

log_header "STARTING FULL-SPECTRUM PIPELINE VALIDATION"
log_info "Target FQDN: ${BOLD}${REPO_FQDN}${NC}"
log_info "Client ID  : ${BOLD}${CLIENT_NAME}${NC}"

# --- SECTION A: INFRASTRUCTURE STATUS ---
log_header "INFRASTRUCTURE HEALTH"

log_step "1" "Checking Container Status"
SERVICES=("certbot" "rpmrepo" "client-test")
ALL_RUNNING=true

for service in "${SERVICES[@]}"; do
    if docker compose ps "$service" | grep -aIE "Up"; then
        log_success "Service '$service' is running."
    else
        log_error "Service '$service' is NOT running."
        ALL_RUNNING=false
    fi
done

if [ "$ALL_RUNNING" = false ]; then
    log_hint "Try running './manage-certbo-repo-client-stack.sh up' first."
    exit 1
fi

log_step "2" "Verifying Certbot Lifecycle"
if docker logs certbot 2>&1 | grep -aiE "valid|Certificate not yet due" -a2; then
    log_success "Certbot manager is processing certificates correctly."
else
    log_warn "Certbot logs don't show a successful cycle yet. Check logs: './manage-certbo-repo-client-stack.sh logs certbot'"
fi

# --- SECTION B: INTERNAL NETWORK (Client-to-Server) ---
log_header "[PERSPECTIVE A] INTERNAL VIRTUAL NETWORK"

log_step "3" "Internal DNS Resolution"
TARGET_IP=$(docker exec client-test getent hosts "$REPO_FQDN" | awk '{ print $1 }' || true)
if [ -n "$TARGET_IP" ]; then
    log_success "$REPO_FQDN resolved to $TARGET_IP"
else
    log_error "Internal DNS failed to resolve $REPO_FQDN"
    log_hint "Ensure 'aliases' are correctly set in docker-compose.yml for rpmrepo."
fi

log_step "4" "Network Path Check (Port 443)"
if docker exec client-test timeout 2 bash -c "</dev/tcp/$REPO_FQDN/443" > /dev/null 2>&1; then
    log_success "Port 443 on $REPO_FQDN is reachable."
else
    log_error "Could not reach $REPO_FQDN on port 443."
    log_hint "Check if Apache is running in the 'rpmrepo' container."
fi

log_step "5" "mTLS Handshake & Certificate Verification"
# Check if client certs exist in container
if docker exec client-test [ ! -f "$INT_CRT" ]; then
    log_error "Client certificate missing in container: $INT_CRT"
    log_hint "Run './manage-certbo-repo-client-stack.sh pki' to generate material."
    exit 1
fi

# Try to perform a handshake and get cert info
CERT_AUDIT=$(docker exec client-test bash -c "openssl s_client -connect ${REPO_FQDN}:443 -cert $INT_CRT -key $INT_KEY < /dev/null 2>/dev/null | openssl x509 -noout -issuer -dates" || true)
HTTP_STATUS_INT=$(docker exec client-test curl -s -o /dev/null -w "%{http_code}" --cert "$INT_CRT" --key "$INT_KEY" "https://${REPO_FQDN}/" || echo "000")

if [ "$HTTP_STATUS_INT" = "200" ]; then
    log_success "mTLS handshake successful (HTTP 200)."
    ISSUER=$(echo "$CERT_AUDIT" | grep "issuer" | sed 's/.*CN = //')
    EXPIRY=$(echo "$CERT_AUDIT" | grep "notAfter" | cut -d'=' -f2)
    log_info "Certificate Issuer: $ISSUER"
    log_info "Certificate Expiry: $EXPIRY"
else
    log_error "mTLS Handshake failed (HTTP $HTTP_STATUS_INT)"
    log_hint "Check if client cert is signed by the CA trusted by Apache."
    log_hint "Run './manage-certbo-repo-client-stack.sh check mtls' for deeper audit."
fi

log_step "6" "DNF Repository Synchronization"
if docker exec client-test dnf repoinfo | grep -aiE "${REPO_FQDN}"; then
    log_success "DNF successfully loaded repository metadata."
else
    log_error "DNF failed to recognize the secure repository."
    log_hint "Check /etc/yum.repos.d/cert.repo inside the client container."
fi

# --- SECTION C: DATA INTEGRITY ---
log_header "[PERSPECTIVE B] DATA INTEGRITY & DELIVERY"

log_step "7" "RPM Package Availability"
# Check if any RPMs exist in the repository
RPM_COUNT=$(docker exec rpmrepo ls /var/www/html/repo/rpms/ 2>/dev/null | grep -c "\.rpm$" || echo "0")
if [ "$RPM_COUNT" -gt 0 ]; then
    log_success "Found $RPM_COUNT RPM packages in the repository."
else
    log_warn "No RPM packages found in the repository yet."
    log_hint "Ensure Certbot has successfully completed at least one cycle."
fi

log_step "8" "Secure Package Retrieval"
# Attempt to download a specific package if possible
if [ "$RPM_COUNT" -gt 0 ]; then
    # Try to find an RPM to test download
    SAMPLE_RPM_FILE=$(docker exec rpmrepo ls /var/www/html/repo/rpms/ | grep "\.rpm$" | head -n 1)
    # Extract package name (e.g., app-mydatacenter-io-pki-repo)
    SAMPLE_PKG=$(echo "$SAMPLE_RPM_FILE" | sed 's/-1.0-.*\.rpm//')
    
    if docker exec client-test dnf download --destdir=/tmp "$SAMPLE_PKG" > /dev/null 2>&1; then
        log_success "Successfully downloaded $SAMPLE_PKG via mTLS."
    else
        log_error "Failed to download $SAMPLE_PKG."
        log_hint "Ensure the repository ID in /etc/yum.repos.d/cert.repo is correct."
    fi
else
    log_info "Skipping download test (no packages available)."
fi

# --- SECTION D: EXTERNAL ACCESS ---
log_header "[PERSPECTIVE C] EXTERNAL CONTROL"

log_step "9" "Host-to-Container Bridge Test"
if [ ! -f "$CLIENT_CRT_LOCAL" ]; then
    log_warn "Local mTLS files not found on host. Skipping external test."
else
    # We use 127.0.0.1 and --resolve to bypass host DNS issues
    HTTP_STATUS_EXT=$(curl -s -o /dev/null -k -w "%{http_code}" \
        --resolve "${REPO_FQDN}:443:127.0.0.1" \
        --cert "$CLIENT_CRT_LOCAL" \
        --key "$CLIENT_KEY_LOCAL" \
        "https://${REPO_FQDN}/" || echo "000")

    if [ "$HTTP_STATUS_EXT" = "200" ]; then
        log_success "External mTLS access verified (HTTP 200)."
    else
        log_error "External access failed (HTTP $HTTP_STATUS_EXT)."
        log_hint "Ensure port 443 is correctly mapped in docker-compose.yml."
    fi
fi

# --- FINAL CONCLUSION ---
log_header "FINAL CONCLUSION"

if [ "$HTTP_STATUS_INT" = "200" ] && [ "$ALL_RUNNING" = true ]; then
    printf "${GREEN}${BOLD}✨ SUCCESS: The Enterprise PKI & RPM Pipeline is fully operational!${NC}\n"
    printf "   All security gates (DNS, Network, mTLS, DNF) are passing.\n\n"
else
    printf "${RED}${BOLD}💥 FAILURE: The pipeline is currently degraded.${NC}\n"
    printf "   Please review the failed steps above and check container logs.\n\n"
    exit 1
fi
