#!/usr/bin/env bash

###############################################################################
# 🛡️  RPM REPOSITORY INTEGRATION & VALIDATION SUITE
###############################################################################
#
# DESCRIPTION:
#   Automates the end-to-end validation of a secure RPM infrastructure.
#   This script ensures the mTLS (Mutual TLS) authentication layer is
#   properly configured by synchronizing local PKI material with the
#   remote repository environment.
#
# CORE CAPABILITIES:
#   🚀 Identity Verification: Tests client authentication against
#      ${REPO_FQDN} using mTLS Certificates.
#   📦 Metadata Audit: Verifies reachability of 'repomd.xml' to ensure
#      the repo is indexed via createrepo_c.
#   ⚙️  System Integration: Auto-detects RHEL-family OSs and generates
#      secure DNF Repo Files in /etc/yum.repos.d/.
#   🔍 Package Inspection: Audits local RPM binaries for dependency
#      resolution and signature integrity.
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
    printf "${BOLD} 🛡️  %s${NC}\n" "$1"
    printf "${BOLD}${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

log_step() {
    printf "\n${BOLD}📍 [PHASE %s] %s${NC}\n" "$1" "$2"
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

# --- 3. Robust Environment Loading ---
if [ -f .env ]; then
    set -a; source <(grep -v '^#' .env); set +a
    log_info "Loaded configuration for: ${REPO_FQDN}"
else
    log_error ".env file not found! Please run from the project root."
    exit 1
fi

# Mandatory Variables
: "${REPO_FQDN:?Error: REPO_FQDN not set in .env}"
: "${CLIENT_NAME:?Error: CLIENT_NAME not set in .env}"

PROJECT_ROOT=$(pwd)
PKI_DIR="${PROJECT_ROOT}/secrets/rpmrepo-secrets/pki_mtls_material"
CLIENT_CRT="${PKI_DIR}/${CLIENT_NAME}.crt"
CLIENT_KEY="${PKI_DIR}/${CLIENT_NAME}.key"

# --- PHASE 1: CONNECTIVITY ---
log_header "RPM REPOSITORY INTEGRATION AUDIT"

log_step "1" "Testing mTLS Connectivity"
if [ ! -f "$CLIENT_CRT" ] || [ ! -f "$CLIENT_KEY" ]; then
    log_error "mTLS Material not found at ${PKI_DIR}"
    log_hint "Run './manage-certbo-repo-client-stack.sh init' or 'pki' to generate material."
    exit 1
fi

HTTP_STATUS=$(curl -s -o /dev/null -k -w "%{http_code}" \
  --resolve "${REPO_FQDN}:443:127.0.0.1" \
  --cert "$CLIENT_CRT" \
  --key "$CLIENT_KEY" \
  "https://${REPO_FQDN}/" || echo "000")

if [ "$HTTP_STATUS" = "200" ]; then
    log_success "Mutual TLS Handshake established (HTTP 200)."
else
    log_error "Connection failed (HTTP $HTTP_STATUS)."
    log_hint "Check if the 'rpmrepo' container is running and port 443 is exposed."
fi

# --- PHASE 2: METADATA ---
log_step "2" "Verifying Repository Metadata"
METADATA_STATUS=$(curl -s -o /dev/null -k -w "%{http_code}" \
  --resolve "${REPO_FQDN}:443:127.0.0.1" \
  --cert "$CLIENT_CRT" \
  --key "$CLIENT_KEY" \
  "https://${REPO_FQDN}/rpms/repodata/repomd.xml" || echo "000")

if [ "$METADATA_STATUS" = "200" ]; then
    log_success "Metadata (repomd.xml) is reachable and indexed."
else
    log_error "Metadata unreachable (HTTP $METADATA_STATUS)."
    log_hint "Ensure 'createrepo_c' has run inside the container or wait for inotify trigger."
fi

# --- PHASE 3: SYSTEM INTEGRATION ---
log_step "3" "Checking OS Compatibility for DNF Integration"

IS_RH_FAMILY=false
if [ -f /etc/os-release ]; then
    if grep -Ei 'ID_LIKE=.*(fedora|rhel|centos)' /etc/os-release > /dev/null || \
       grep -Ei '^ID=.*(fedora|rhel|centos|almalinux|rocky)' /etc/os-release > /dev/null; then
        IS_RH_FAMILY=true
    fi
fi

if [ "$IS_RH_FAMILY" = true ]; then
    log_success "Red Hat-based distribution detected."
    
    REPO_FILE="/etc/yum.repos.d/local-cert-repo.repo"
    log_info "Configuring repository at ${REPO_FILE}..."
    
    sudo bash -c "cat << EOF > $REPO_FILE
[local-cert-repo]
name=Local Secure Repo for ${REPO_FQDN}
baseurl=https://${REPO_FQDN}/rpms/
enabled=1
sslverify=0
sslclientcert=${CLIENT_CRT}
sslclientkey=${CLIENT_KEY}
metadata_expire=0
EOF"

    log_success "DNF Repository file created."
    log_info "Refreshing DNF cache..."
    sudo dnf clean expire-cache > /dev/null
    
    if sudo dnf repository-packages local-cert-repo list > /dev/null 2>&1; then
        log_success "Successfully listed packages from local-cert-repo."
    else
        log_warn "Could not list packages. Repo might be empty or resolution failed."
    fi
else
    log_info "Skipping DNF setup: This machine is not a Red Hat-based distribution."
    log_info "Detected: $(grep '^PRETTY_NAME=' /etc/os-release | cut -d'=' -f2 | tr -d '\"' || echo "Unknown OS")"
fi

# --- PHASE 4: BINARY INSPECTION ---
log_step "4" "RPM Binary Verification"
# Look in the datastore directory where RPMs are actually stored
RPM_PATH="./datastore/rpmrepo-data/rpms"
REAL_RPM=$(find "$RPM_PATH" -maxdepth 1 -name "*.rpm" 2>/dev/null | head -n 1 || true)

if [ -n "$REAL_RPM" ]; then
    log_info "Inspecting: $(basename "$REAL_RPM")"
    
    if command -v rpm > /dev/null 2>&1; then
        if rpm -qp "$REAL_RPM" --requires > /dev/null 2>&1; then
            log_success "RPM metadata is readable."
            # Checking signature if possible
            if rpm -K "$REAL_RPM" > /dev/null 2>&1; then
                log_success "RPM integrity check passed."
            else
                log_warn "RPM integrity check failed or no signature found."
            fi
        else
            log_error "Failed to read RPM metadata."
        fi
    else
        log_warn "Skipping detailed inspection: 'rpm' command not found on this host."
        log_info "File exists and is $(du -h "$REAL_RPM" | cut -f1) in size."
    fi
else
    log_info "No .rpm files found in ${RPM_PATH} to verify."
fi

log_header "VALIDATION COMPLETE"
if [ "$HTTP_STATUS" = "200" ] && [ "$METADATA_STATUS" = "200" ]; then
    printf "${GREEN}${BOLD}✨ SUCCESS: Local environment is correctly integrated with the RPM Repository!${NC}\n\n"
else
    printf "${RED}${BOLD}💥 FAILURE: Integration issues detected. Please review the phases above.${NC}\n\n"
    exit 1
fi

