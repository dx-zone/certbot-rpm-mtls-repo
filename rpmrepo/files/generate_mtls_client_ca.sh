#!/bin/bash
################################################################################
# 🔐 INTERNAL PKI & mTLS BOOTSTRAPPER (CONTAINER EXECUTION)
# ------------------------------------------------------------------------------
# PURPOSE:
#   Executed inside the rpmrepo container to manage the Internal CA.
#   Satisfies the paths required by 'repo_with_auth.conf.template'.
#
# WHY:
#   Standard SSL (HTTPS) only proves the Server is who they say they are.
#   mTLS proves the CLIENT is also authorized, creating a private, secure
#   distribution channel for sensitive PKI material.
#
#   The Apache configuration expects these mTLS materials to be in place
#   so they can be loaded when the final config is generated from the
#   'repo_with_auth.conf.template' via envsubst.
################################################################################

# --- 0. Variable Coalescing ---
CA_NAME="${CA_NAME:-Internal-Client-Auth-CA}"
CLIENT_NAME="${CLIENT_NAME:-test-client-identity}"
REPO_DOMAIN="${REPO_FQDN:?❌ ERROR: REPO_FQDN environment variable is required}"
DAYS_VALID=3650

# --- 1. Container Path Mapping ---
CERT_DIR="/etc/httpd/certs"
OUTPUT_DIR="$CERT_DIR"
APACHE_CA_DEST="$CERT_DIR/client-ca.crt"

# Colors & Formatting
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    printf "\n${CYAN}%s${NC}\n" "──────────────────────────────────────────────────────────"
    printf "${BOLD} %s${NC}\n" "$1"
    printf "${CYAN}%s${NC}\n" "──────────────────────────────────────────────────────────"
}

# 🛠️ Step 2: Initialize Workspace
mkdir -p "$OUTPUT_DIR"
print_header "🚀 INITIALIZING CONTAINER PKI"
printf "🌐 Target Repository Domain: ${YELLOW}%s${NC}\n" "$REPO_DOMAIN"
printf "👤 Default Client Identity:  ${YELLOW}%s${NC}\n" "$CLIENT_NAME"

# 🛡️ Step 3: Root CA Management
print_header "🛡️  STEP 1: ROOT CA MANAGEMENT"
if [ ! -f "$OUTPUT_DIR/ca.key" ]; then
    printf "🔑 ${BOLD}Generating 4096-bit RSA Private Key for CA...${NC}\n"
    openssl genrsa -out "$OUTPUT_DIR/ca.key" 4096

    printf "📜 ${BOLD}Generating Self-Signed CA Certificate...${NC}\n"
    openssl req -x509 -new -nodes -key "$OUTPUT_DIR/ca.key" -sha256 -days "$DAYS_VALID" \
        -out "$OUTPUT_DIR/ca.crt" \
        -subj "/C=US/ST=Infrastructure/O=My Private Certificate/CN=$CA_NAME"
    printf "${GREEN}✅ SUCCESS: Root CA created.${NC}\n"
else
    printf "${YELLOW}♻️  CA EXISTS: Reusing existing Root CA key/cert.${NC}\n"
fi

# 📡 Step 4: Apache Configuration Sync
# FIX: Handle Docker's tendency to create directories where files should be
if [ -d "$APACHE_CA_DEST" ]; then
    echo "🧹 Removing invalid directory at $APACHE_CA_DEST"
    rm -rf "$APACHE_CA_DEST"
fi

# Step 5: Copy CA to the location Apache expects for mTLS verification
cp "$OUTPUT_DIR/ca.crt" "$APACHE_CA_DEST"
printf "📡 ${BOLD}SYNC:${NC} CA public cert copied to ${CYAN}%s${NC}\n" "$APACHE_CA_DEST"

# 👤 Step 6: Client Identity Generation
print_header "👤 STEP 2: CLIENT IDENTITY GENERATION"
if [ ! -f "$OUTPUT_DIR/$CLIENT_NAME.crt" ]; then
    printf "🔑 ${BOLD}Generating 2048-bit Private Key for client...${NC}\n"
    openssl genrsa -out "$OUTPUT_DIR/$CLIENT_NAME.key" 2048

    printf "📝 ${BOLD}Creating Certificate Signing Request (CSR)...${NC}\n"
    openssl req -new -key "$OUTPUT_DIR/$CLIENT_NAME.key" \
        -out "$OUTPUT_DIR/$CLIENT_NAME.csr" \
        -subj "/CN=$CLIENT_NAME"

    printf "✍️  ${BOLD}Signing Client Cert with Root CA...${NC}\n"
    openssl x509 -req -in "$OUTPUT_DIR/$CLIENT_NAME.csr" \
        -CA "$OUTPUT_DIR/ca.crt" -CAkey "$OUTPUT_DIR/ca.key" \
        -CAcreateserial -out "$OUTPUT_DIR/$CLIENT_NAME.crt" \
        -days 365 -sha256 \
        -extfile <(printf "extendedKeyUsage = clientAuth")
    printf "${GREEN}✅ SUCCESS: Client Identity signed and ready.${NC}\n"
else
    printf "${YELLOW}⏭️  SKIP: Certificate for '$CLIENT_NAME' already exists.${NC}\n"
fi

# 🏁 Step 7: Distribution & Usage Guide
print_header "🏁 PKI BOOTSTRAP COMPLETE"

printf "${BOLD}📂 EXPORTING MATERIAL${NC}\n"
printf "%s\n" "----------------------------------------------------------"
printf "${CYAN}The following files must be copy to your Linux client\n"
printf "to authorize file access retrieval from this server:${NC}\n\n"
printf "📄 SOURCE: ${YELLOW}${OUTPUT_DIR}/${CLIENT_NAME}.crt${NC}\n"
printf "📄 SOURCE: ${YELLOW}${OUTPUT_DIR}/${CLIENT_NAME}.key${NC}\n"
printf "%s\n" "----------------------------------------------------------"

print_header "📋 CLIENT DNF/YUM REPOSITORY CONFIGURATION"
printf "Create ${YELLOW}/etc/yum.repos.d/rpmrepo.repo${NC} on the Linux client:\n\n"

cat <<EOF
[${CA_NAME}]
name=My Private Certificate Secure Repository (mTLS)
baseurl=https://$REPO_DOMAIN/rpms/
enabled=1
sslverify=1
sslclientcert=/etc/pki/tls/certs/${CLIENT_NAME}.crt
sslclientkey=/etc/pki/tls/private/${CLIENT_NAME}.key
metadata_expire=60
EOF

printf "\n${CYAN}%s${NC}\n" "──────────────────────────────────────────────────────────"
printf "🚀 ${BOLD}Internal PKI setup finished. Returning to entrypoint...${NC}\n"