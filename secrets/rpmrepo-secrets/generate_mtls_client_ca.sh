#!/bin/bash
################################################################################
# 🔐 PKI & mTLS GENERATOR
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

#!/bin/bash

# --- 0. Locate and Load .env ---
ENV_FILE="../../.env"
DEFAULT_FQDN="repo.example.com"

if [ -f "$ENV_FILE" ]; then
    echo "📂 [$(date +%T)] Loading environment variables from $ENV_FILE"
    # set -a: Automatically export all variables defined from here on
    set -a
    # Filter comments/empty lines and source the result
    source <(grep -v -E '^[[:space:]]*(#|$)' "$ENV_FILE")
    set +a
else
    echo "⚠️  [$(date +%T)] .env file not found at $ENV_FILE"
    echo "⚠️  [$(date +%T)] Expecting .env file at $ENV_FILE"
    echo "⚠️  [$(date +%T)] Moving on to default values for repo FQDN, CA name, and client id"
fi

# --- 1. Fallback Logic with User Notification ---
: "${REPO_FQDN:=$DEFAULT_FQDN}"
: "${CA_NAME:="Internal-RPM-Repo-CA"}"
: "${CLIENT_NAME:="test-client-identity"}"

# Check if we are using the hardcoded default for the critical FQDN
if [[ "$REPO_FQDN" == "$DEFAULT_FQDN" ]] && ! grep -q "REPO_FQDN=" "$ENV_FILE" 2>/dev/null; then
    printf "\n\e[33m📢 NOTICE: REPO_FQDN not found in .env. Using default: %s\e[0m\n\n" "$REPO_FQDN"
fi

# --- 2. Verification ---
echo "✅ Active Configuration:"
echo "   - FQDN:   $REPO_FQDN"
echo "   - CA:     $CA_NAME"
echo "   - Client: $CLIENT_NAME"

# --- 3. Variable Coalescing ---
CA_NAME="${CA_NAME:-Internal-Client-Auth-CA}"
CLIENT_NAME="${CLIENT_NAME:-test-client-identity}"
REPO_DOMAIN="${REPO_FQDN:?❌ ERROR: REPO_FQDN environment variable is required}"
DAYS_VALID=3650
CERT_DIR="./pki_mtls_material"

# --- 4. Container Path Mapping ---
OUTPUT_DIR="$CERT_DIR"

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

# 🛠️ Step 5: Initialize Workspace
mkdir -p "$OUTPUT_DIR"
print_header "🚀 INITIALIZING RPMREPO CONTAINER PKI/mTLS"
printf "🌐 Target Repository Domain: ${YELLOW}%s${NC}\n" "$REPO_DOMAIN"
printf "👤 Default Client Identity:  ${YELLOW}%s${NC}\n" "$CLIENT_NAME"

# 🛡️ Step 6: Root CA Management
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

# 👤 Step 7: Client Identity Generation
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

# 🏁 Step 8: Distribution & Usage Guide
print_header "🏁 PKI Mtls CREATION COMPLETE"

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
sslclientcert=/etc/pki/tls/certs/client-identity.crt
sslclientkey=/etc/pki/tls/private/client-identity.key
metadata_expire=60
EOF

printf "\n${CYAN}%s${NC}\n" "──────────────────────────────────────────────────────────"
printf "🚀 ${BOLD}Internal PKI setup finished. Returning to entrypoint...${NC}\n"

# ==============================================================================
# 📚 HUMAN CHEAT SHEET — WHAT THESE FILES ARE & WHO NEEDS THEM
# ==============================================================================
print_header "📚 PKI / mTLS FILE CHEAT SHEET (READ ME)"

cat <<EOF

🔐 OVERVIEW
-----------
This PKI setup enables *mutual TLS (mTLS)* between:
  • The RPM repository server (rpmrepo / Apache)
  • Authorized Linux clients (dnf / curl / automation)

With mTLS:
  - HTTPS proves the SERVER identity
  - mTLS proves the CLIENT identity

Only clients with a valid certificate signed by THIS CA can fetch RPMs.


📁 FILES GENERATED IN: ${OUTPUT_DIR}
------------------------------------------------------------

1️⃣ ca.key
---------
📄 File: ${OUTPUT_DIR}/ca.key
🔐 Type: Root CA PRIVATE KEY
👤 Who needs it: ❌ NO CLIENTS ❌
🏠 Where it lives: rpmrepo / PKI generation system ONLY

🧠 What it does:
- This key signs client certificates
- Anyone who gets this key can mint valid clients

🚨 SECURITY:
- DO NOT distribute
- DO NOT mount into clients
- Treat like a root password

------------------------------------------------------------

2️⃣ ca.crt
---------
📄 File: ${OUTPUT_DIR}/ca.crt
🔐 Type: Root CA CERTIFICATE (public)
👤 Who needs it:
  ✔ rpmrepo (Apache)
  ✔ optionally clients (trust store)

🧠 What it does:
- Apache uses this to VERIFY client certificates
- This file must match the CA that signed client certs

📍 Apache usage example:
  SSLCACertificateFile /etc/httpd/certs/client-ca.crt

💡 Note:
- You may rename or copy this file as client-ca.crt
- Name does not matter — CONTENT does

------------------------------------------------------------

3️⃣ ${CLIENT_NAME}.key
---------
📄 File: ${OUTPUT_DIR}/${CLIENT_NAME}.key
🔐 Type: CLIENT PRIVATE KEY
👤 Who needs it:
  ✔ Linux clients that fetch RPMs

📍 Where it goes on clients:
  /etc/pki/tls/private/${CLIENT_NAME}.key

🧠 What it does:
- Proves the client owns the certificate
- Used during TLS handshake (CERT verify)

🚨 SECURITY:
- Must remain secret
- If leaked, revoke client or rotate CA

------------------------------------------------------------

4️⃣ ${CLIENT_NAME}.crt
---------
📄 File: ${OUTPUT_DIR}/${CLIENT_NAME}.crt
🔐 Type: CLIENT CERTIFICATE
👤 Who needs it:
  ✔ Linux clients that fetch RPMs

📍 Where it goes on clients:
  /etc/pki/tls/certs/${CLIENT_NAME}.crt

🧠 What it does:
- Identifies the client to Apache
- Must be signed by the CA Apache trusts

------------------------------------------------------------

5️⃣ ${CLIENT_NAME}.csr
---------
📄 File: ${OUTPUT_DIR}/${CLIENT_NAME}.csr
🔐 Type: Certificate Signing Request
👤 Who needs it: ❌ nobody after creation

🧠 What it does:
- Temporary file used during cert creation
- Safe to delete after signing

------------------------------------------------------------

📦 CLIENT SIDE SUMMARY
----------------------
To allow a Linux client to fetch RPMs from this repo, it MUST have:

  ✔ ${CLIENT_NAME}.crt  → /etc/pki/tls/certs/
  ✔ ${CLIENT_NAME}.key  → /etc/pki/tls/private/

And the repo config must include:

  sslclientcert=/etc/pki/tls/certs/${CLIENT_NAME}.crt
  sslclientkey=/etc/pki/tls/private/${CLIENT_NAME}.key
  sslverify=1

------------------------------------------------------------

🧠 SERVER SIDE SUMMARY (rpmrepo / Apache)
-----------------------------------------
Apache must trust the CA that signed client certs:

  SSLCACertificateFile /etc/httpd/certs/client-ca.crt
  SSLVerifyClient require

Where client-ca.crt == ca.crt generated by THIS script

------------------------------------------------------------

🧪 TROUBLESHOOTING QUICK HINTS
------------------------------
• curl fails with "certificate required"
  → Client cert/key missing or wrong path

• curl fails with "unknown ca"
  → Apache does not trust the CA that signed client certs

• curl works with -k but not without
  → Client does not trust SERVER cert (not mTLS related)

------------------------------------------------------------

✅ TL;DR
-------
- ca.key     → NEVER LEAVES THE SERVER
- ca.crt     → Apache trusts clients with this
- client.key → Client secret identity
- client.crt → Client public identity

This is a PRIVATE, AUTHENTICATED RPM distribution channel.

EOF

printf "\n${GREEN}📘 Cheat sheet printed successfully. Keep this output for future reference.${NC}\n"

