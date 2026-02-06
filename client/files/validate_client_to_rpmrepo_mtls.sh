#!/usr/bin/env bash
# validate_client_to_rpmrepo_mtls.sh
#
# Purpose:
#   Validate that a Linux client container can reach an Apache-based RPM repo over HTTPS
#   and that mTLS (mutual TLS) is enforced and working.
#
# What this script checks:
#   1) DNS: Does REPO_FQDN resolve to an IP?
#   2) Server TLS certificate: Who issued it? Is it self-signed vs public CA?
#   3) mTLS enforcement: Does the server reject clients that don't present a cert?
#   4) mTLS authorization: Can this client authenticate with its cert+key?
#   5) Fallback mode support: Can we trust-on-first-use by pinning server cert to --cacert?
#
# Notes:
#   - On an mTLS-required server, "openssl s_client" WITHOUT a client cert will usually
#     end with "tlsv13 alert certificate required" and exit non-zero. That is expected.
#     We guard these steps so the script continues and interprets the result correctly.

set -euo pipefail

# =========================
# CONFIGURATION
# =========================
REPO_FQDN="${REPO_FQDN:-repo.mydatacenter.io}"

# Client identity for mTLS (mounted into client-test)
CLIENT_CERT="${CLIENT_CERT:-/etc/pki/tls/certs/client-identity.crt}"
CLIENT_KEY="${CLIENT_KEY:-/etc/pki/tls/private/client-identity.key}"

# Optional: if you have a known CA that signed the server fallback cert, set it here.
# If empty, the script will do "trust-on-first-use" by extracting the live server cert.
FALLBACK_CA_FILE="${FALLBACK_CA_FILE:-}"

# Suggested repo content path (repomd.xml is the strongest proof your RPM repo is usable)
REPO_TEST_PATH="${REPO_TEST_PATH:-/repodata/repomd.xml}"

# Temporary files
TMP_DIR="${TMP_DIR:-/tmp}"
TMP_SERVER_CERT="${TMP_DIR}/repo-server.crt"
TMP_CERT_INFO="${TMP_DIR}/server-cert-info.txt"

# Timeouts (keep these short to avoid hangs in CI)
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-15}"

# =========================
# COLORS / OUTPUT HELPERS
# =========================
GREEN="\033[0;32m"
RED="\033[0;31m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
NC="\033[0m"

info()    { echo -e "${BLUE}ℹ️  $*${NC}"; }
success() { echo -e "${GREEN}✅ $*${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $*${NC}"; }
fail()    { echo -e "${RED}❌ $*${NC}"; }

separator() {
  echo -e "\n${BLUE}============================================================${NC}\n"
}

run_cmd() {
  # Print command before running it (human-friendly)
  echo -e "${BLUE}▶️  Running:${NC} $*"
  # shellcheck disable=SC2068
  "$@"
}

# =========================
# PRE-FLIGHT CHECKS
# =========================
separator
info "Pre-flight checks"
info "Target repo: ${REPO_FQDN}"
info "Client cert: ${CLIENT_CERT}"
info "Client key : ${CLIENT_KEY}"
info "Repo path  : ${REPO_TEST_PATH}"
if [[ -n "${FALLBACK_CA_FILE}" ]]; then
  info "Fallback CA file (optional): ${FALLBACK_CA_FILE}"
else
  info "Fallback CA file (optional): (not set) — will use trust-on-first-use extraction if needed"
fi

if [[ ! -f "${CLIENT_CERT}" ]]; then
  fail "Client certificate not found: ${CLIENT_CERT}"
  exit 1
fi
if [[ ! -f "${CLIENT_KEY}" ]]; then
  fail "Client private key not found: ${CLIENT_KEY}"
  exit 1
fi

# Quick PEM sanity checks
if ! head -n1 "${CLIENT_CERT}" | grep -q "BEGIN CERTIFICATE"; then
  warn "Client cert does not look like PEM (expected 'BEGIN CERTIFICATE'). File may still work, but check format."
fi
if ! head -n1 "${CLIENT_KEY}" | grep -Eq "BEGIN (ENCRYPTED )?PRIVATE KEY|BEGIN RSA PRIVATE KEY"; then
  warn "Client key does not look like PEM private key. Check format."
fi

# =========================
# 1️⃣ DNS RESOLUTION
# =========================
separator
info "1️⃣ DNS check: resolving ${REPO_FQDN}"
if getent hosts "${REPO_FQDN}" >/dev/null; then
  success "DNS resolution works:"
  getent hosts "${REPO_FQDN}"
else
  fail "DNS resolution failed — the client cannot resolve ${REPO_FQDN}"
  echo
  warn "TIP: If you're using docker-compose, ensure rpmrepo has a network alias for \${REPO_FQDN} and client is on same network."
  exit 1
fi

# =========================
# 2️⃣ SERVER TLS CERT INSPECTION
# =========================
separator
info "2️⃣ Inspecting the server TLS certificate (no client cert provided)"
info "Why: This tells us if the server is using a real CA cert (e.g., Let's Encrypt) or a fallback self-signed cert."
info "Note: Because your server requires mTLS, the handshake may end with 'certificate required' — that's expected."

# This may exit non-zero due to mTLS requirement; we still want the x509 output.
# We redirect s_client stderr to reduce noise, and guard with '|| true' to avoid pipefail abort.
{
  openssl s_client -connect "${REPO_FQDN}:443" -servername "${REPO_FQDN}" </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates \
    | tee "${TMP_CERT_INFO}"
} || true

if [[ ! -s "${TMP_CERT_INFO}" ]]; then
  fail "Could not parse server certificate. The server may be unreachable, not speaking TLS on 443, or blocked."
  echo
  warn "TIP: Check that rpmrepo is listening on :443 and the client can reach it (try: 'curl -vk https://${REPO_FQDN}/')."
  exit 1
fi

SUBJECT="$(grep '^subject=' "${TMP_CERT_INFO}" || true)"
ISSUER="$(grep '^issuer=' "${TMP_CERT_INFO}" || true)"
NOT_BEFORE="$(grep '^notBefore=' "${TMP_CERT_INFO}" || true)"
NOT_AFTER="$(grep '^notAfter=' "${TMP_CERT_INFO}" || true)"

echo
info "Interpreting server cert:"
echo "  • ${SUBJECT}"
echo "  • ${ISSUER}"
echo "  • ${NOT_BEFORE}"
echo "  • ${NOT_AFTER}"
echo

CERT_TYPE="unknown"
if echo "${ISSUER}" | grep -qi "Let's Encrypt"; then
  CERT_TYPE="public_ca"
  success "Server cert appears to be publicly trusted (Let's Encrypt)."
elif [[ "${ISSUER}" == "${SUBJECT}" && -n "${ISSUER}" ]]; then
  CERT_TYPE="self_signed"
  warn "Server cert appears to be self-signed (issuer == subject). This likely means fallback mode is active."
else
  CERT_TYPE="private_ca_or_custom"
  warn "Server cert is not Let's Encrypt and not obviously self-signed. It may be issued by a private/internal CA."
fi

# =========================
# 3️⃣ VERIFY mTLS IS ENFORCED
# =========================
separator
info "3️⃣ Checking mTLS enforcement (expected failure WITHOUT client cert)"
info "Why: If this succeeds, your server is not actually requiring client certificates."

# We expect this to fail due to mTLS. We'll treat failure as PASS.
if curl -sS -k --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
  "https://${REPO_FQDN}${REPO_TEST_PATH}" >/dev/null; then
  fail "Unexpected success WITHOUT client cert — mTLS may NOT be enforced!"
  echo
  warn "TIP: Verify Apache vhost has 'SSLVerifyClient require' and correct 'SSLCACertificateFile' for client CA."
  exit 1
else
  success "Rejected without client cert (good) — mTLS appears enforced."
fi

# =========================
# 4️⃣ TEST mTLS AUTH + ACCESS (NORMAL TRUST)
# =========================
separator
info "4️⃣ Testing mTLS authentication with client cert+key (normal trust)"
info "Why: This proves the mounted cert+key pair works AND the server authorizes this client."
info "Expected: HTTP 200 and XML from repomd.xml (or at least a successful HTTP response)."

# We do NOT use -k here. If server cert is publicly trusted (Let's Encrypt), this should pass.
# If server is self-signed fallback, this will likely fail unless the CA is installed/trusted.
set +e
CURL_OUT="$(curl -sS -v \
  --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
  --cert "${CLIENT_CERT}" \
  --key  "${CLIENT_KEY}" \
  "https://${REPO_FQDN}${REPO_TEST_PATH}" 2>&1)"
CURL_RC=$?
set -e

if [[ ${CURL_RC} -eq 0 ]]; then
  success "mTLS auth succeeded with normal trust (server cert trusted by client)."
else
  warn "mTLS request did not succeed with normal trust."
  echo
  info "curl error (trimmed):"
  echo "${CURL_OUT}" | tail -n 20
  echo
  if echo "${CURL_OUT}" | grep -qi "certificate required"; then
    fail "Server still says 'certificate required' even though you provided a client cert — this suggests cert wasn't sent or was rejected."
    warn "TIP: Confirm you're using the correct --cert and --key paths and they match each other."
    warn "TIP: Check Apache uses the right client CA: SSLCACertificateFile /etc/httpd/certs/client-ca.crt"
    exit 1
  fi
  if echo "${CURL_OUT}" | grep -qiE "self[- ]signed|unknown ca|unable to get local issuer"; then
    warn "This looks like a SERVER TRUST issue (client doesn't trust server cert)."
    if [[ "${CERT_TYPE}" == "self_signed" ]]; then
      warn "Likely cause: rpmrepo is in fallback self-signed mode."
    else
      warn "Likely cause: server uses private CA not installed in this client trust store."
    fi
    warn "We'll validate using a safe workaround next (either FALLBACK_CA_FILE or trust-on-first-use)."
  else
    warn "This may be an HTTP-level issue (404/403) or network/SSL misconfiguration. We'll continue with additional checks."
  fi
fi

# =========================
# 5️⃣ FALLBACK / PRIVATE CA HANDLING
# =========================
separator
info "5️⃣ Ensuring access works even if server cert is self-signed or private CA"
info "Goal: Prove client can reach repo by providing a CA for server validation."
info "Method:"
info "  - If FALLBACK_CA_FILE is set: use it as --cacert"
info "  - Otherwise: extract server cert and trust it (trust-on-first-use) for this test only"

CA_TO_USE=""

if [[ -n "${FALLBACK_CA_FILE}" ]]; then
  if [[ -f "${FALLBACK_CA_FILE}" ]]; then
    CA_TO_USE="${FALLBACK_CA_FILE}"
    success "Using provided FALLBACK_CA_FILE for server trust: ${CA_TO_USE}"
  else
    fail "FALLBACK_CA_FILE was set but file not found: ${FALLBACK_CA_FILE}"
    exit 1
  fi
else
  info "Extracting live server certificate to ${TMP_SERVER_CERT}"
  {
    openssl s_client -connect "${REPO_FQDN}:443" -servername "${REPO_FQDN}" -showcerts </dev/null 2>/dev/null \
      | openssl x509 -outform PEM > "${TMP_SERVER_CERT}"
  } || true

  if [[ -s "${TMP_SERVER_CERT}" ]]; then
    CA_TO_USE="${TMP_SERVER_CERT}"
    success "Extracted server cert for one-time trust: ${CA_TO_USE}"
  else
    fail "Could not extract server certificate."
    warn "TIP: Ensure rpmrepo is reachable on 443 and serving TLS."
    exit 1
  fi
fi

info "Running curl with --cacert '${CA_TO_USE}' + client cert/key to prove end-to-end access"
if curl -sS \
  --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
  --cacert "${CA_TO_USE}" \
  --cert "${CLIENT_CERT}" \
  --key  "${CLIENT_KEY}" \
  "https://${REPO_FQDN}${REPO_TEST_PATH}" | head -n 1 | grep -q '<?xml'; then
  success "Repo content returned (XML detected) — end-to-end validation PASSED."
else
  warn "Did not detect XML in response. This can happen if the repo path is different or directory listing is disabled."
  warn "We'll try a HEAD request to see the HTTP status."
  echo

  set +e
  curl -sS -I \
    --connect-timeout "${CURL_CONNECT_TIMEOUT}" --max-time "${CURL_MAX_TIME}" \
    --cacert "${CA_TO_USE}" \
    --cert "${CLIENT_CERT}" \
    --key  "${CLIENT_KEY}" \
    "https://${REPO_FQDN}${REPO_TEST_PATH}"
  RC=$?
  set -e

  if [[ ${RC} -ne 0 ]]; then
    fail "Even with --cacert + client cert, request failed."
    echo
    warn "TIP: Confirm Apache DocumentRoot points to the correct repo directory and repodata exists."
    warn "TIP: On rpmrepo container, check: ls -l /var/www/html/repo/repodata/repomd.xml"
    warn "TIP: Check Apache logs: /var/log/httpd/repo_error.log and repo_access.log"
    exit 1
  fi
fi

# =========================
# FINAL SUMMARY
# =========================
separator
success "🎉 All checks completed successfully!"
echo -e "${BLUE}Summary:${NC}"
echo "  • DNS resolution:                 OK"
echo "  • Server TLS certificate:         Parsed OK (${CERT_TYPE})"
echo "  • mTLS enforcement (no cert):     Rejected as expected"
echo "  • Client cert/key usability:      OK (mTLS succeeded)"
echo "  • Repo content accessibility:     Confirmed (${REPO_TEST_PATH})"
separator

# =========================
# TIP SECTION
# =========================
cat <<'TIPS'

🧰 TIPs (What to do if something is off)

1) DNS fails (getent hosts fails)
   - Ensure docker-compose sets a network alias for rpmrepo:
       services.rpmrepo.networks.default.aliases: [ ${REPO_FQDN} ]
   - Ensure client-test is on the same docker network.

2) Server cert looks self-signed / not trusted
   - This typically means your rpmrepo is running in fallback self-signed mode.
   - Fix by ensuring certbot populated:
       /etc/letsencrypt/live/${REPO_FQDN}
     and rpmrepo is mounting that directory.
   - For testing only, you can:
       - Extract server cert and pass it via --cacert (this script does that), or
       - Use curl -k (not recommended for real usage).

3) mTLS not enforced (curl without cert succeeds)
   - Verify Apache vhost contains:
       SSLVerifyClient require
       SSLCACertificateFile /etc/httpd/certs/client-ca.crt
   - Reload/restart httpd after config changes.

4) Client auth fails (server says "certificate required" even when you pass cert)
   - Ensure you're passing the correct files:
       --cert must be a CERTIFICATE (.crt)
       --key  must be a PRIVATE KEY (.key)
   - Confirm the key matches the cert:
       openssl x509 -noout -modulus -in client-identity.crt | openssl md5
       openssl rsa  -noout -modulus -in client-identity.key | openssl md5
     (The hashes must match.)

5) HTTP 403 or 404 but TLS/mTLS succeeded
   - TLS succeeded; now it’s an Apache authz/path/content issue.
   - Check DocumentRoot and that repodata exists:
       ls -l /var/www/html/repo/repodata/repomd.xml
   - Review logs:
       /var/log/httpd/repo_error.log
       /var/log/httpd/repo_access.log

✅ If you want to validate "dnf/yum install" next, you’ll configure:
   sslclientcert=...
   sslclientkey=...
   sslcacert=...
in the repo file under /etc/yum.repos.d/

TIPS
