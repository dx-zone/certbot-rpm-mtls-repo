#!/bin/bash
################################################################################
# IDEMPOTENT APACHE ENTRYPOINT
# Method: Dynamic Variable Injection & SSL Path Selection
# ------------------------------------------------------------------------------
# PURPOSE:
#  Updates /etc/httpd/conf.d/repo.conf to point to either self-signed fallback
#  certs or Let's Encrypt production certs if they are present.
#
# WHY:
#  Ensures the web server always starts even if Certbot hasn't finished its
#  first run, while maintaining strict mTLS requirements for the RPM repo.
################################################################################
set -e

# --- 1. Constants & Path Definitions ---
FALLBACK_CRT="/etc/pki/tls/certs/fallback.crt"
FALLBACK_KEY="/etc/pki/tls/private/fallback.key"
TEMPLATE="/etc/httpd/conf.d/repo.conf.template"
REPO_CONF="/etc/httpd/conf.d/repo.conf"

# --- 2. Environment Validation ---
# FQDN passed to the container by Docker if defined in .env. Required by Apache conf.
if [ -z "${REPO_FQDN}" ]; then
    printf "❌ ERROR: REPO_FQDN environment variable is not set.\n"
    exit 1
fi

# --- 2.5 Internal PKI & mTLS Generation ---
# This ensures that /etc/httpd/certs/client-ca.crt exists before Apache starts.
# Required by Apache conf. to enable Linux client mTLS authentication
if [ -f "/generate_mtls_client_ca.sh" ]; then
    printf "🔐 [%s] Running mTLS/PKI bootstrapper...\n" "$(date +%T)"
    /bin/bash /generate_mtls_client_ca.sh
else
    printf "⚠️  [%s] Warning: /generate_mtls_client_ca.sh not found.\n" "$(date +%T)"
fi

# Certbot must produced a certificate for this repo if defined in the certificates.csv and .env
# else fall back to self-sign SSL certificate
# Define the expected production certs if issued by certbot (shared mapped volume bt Certbot & rpmrepo)
REAL_CRT="/etc/letsencrypt/live/${REPO_FQDN}/fullchain.pem"
REAL_KEY="/etc/letsencrypt/live/${REPO_FQDN}/privkey.pem"

# --- 3. SSL Path Selection & Exporting ---
export REPO_FQDN="${REPO_FQDN}"

# --- 3. SSL Path Selection & Exporting ---
# If Let's Encrypt certificate was found load it, else fallback to self-sign certificate to generate repo.conf.
if [ -f "$REAL_CRT" ] && [ -s "$REAL_CRT" ]; then
    printf "✅ [%s] Production certificate detected for %s\n" "$(date +%T)" "${REPO_FQDN}"
    export SELECTED_CRT="$REAL_CRT"
    export SELECTED_KEY="$REAL_KEY"
else
    # If it's a directory (Docker's mistake), remove it
    [ -d "$REAL_CRT" ] && rm -rf "$REAL_CRT"

    printf "⚠️  [%s] Fallback: Using self-signed SSL certificate for %s\n" "$(date +%T)" "${REPO_FQDN}"
    export SELECTED_CRT="$FALLBACK_CRT"
    export SELECTED_KEY="$FALLBACK_KEY"
    printf "⚠️  [%s] Certificate path: %s\n" "$(date +%T)" "${SELECTED_CRT}"
    printf "⚠️  [%s] Private key path: %s\n" "$(date +%T)" "${SELECTED_KEY}"
fi

# --- 4. Configuration Generation (Idempotent) ---
printf "🛠️  [%s] Generating %s from template (%s)...\n" "$(date +%T)" "${REPO_CONF}" "$TEMPLATE"
printf "📜 [%s] Certificate to load: %s\n" "$(date +%T)" "${SELECTED_CRT}"
printf "🔑 [%s] Private key to load: %s\n" "$(date +%T)" "${SELECTED_KEY}"

# Use template repo.conf.template for variable substitution and generate configuration for repo.conf
printf "\n"
envsubst '${REPO_FQDN} ${SELECTED_CRT} ${SELECTED_KEY}' < "$TEMPLATE" > "$REPO_CONF"

printf "\n📦 New configuration generated!\n\n"
cat ${REPO_CONF}

printf "\n"
# --- 5. Background Watcher (MUST START BEFORE EXEC) ---
# Background loop to update repo metadata whenever a new RPM arrives.
# While the certbot container is responsible for packing PKI material into RPMs,
# this container manages the distribution metadata.
(
  printf "👁️  [%s] Starting inotify watcher on /var/www/html/repo/...\n" "$(date +%T)"
  # 'close_write' is preferred over 'modify' to ensure the file transfer is finished
  while inotifywait -qr -e close_write,delete,move /var/www/html/repo/; do
    printf "📦 [%s] Change detected! Updating repository metadata...\n" "$(date +%T)"

    # Update repository index (TODO: Implement GPG signing: rpmsign --addsign ...)
    createrepo_c --update /var/www/html/repo/

    # Verify configuration before attempting a reload
    if ! /usr/sbin/httpd -t; then
        printf "❌ [%s] ERROR: HTTPD syntax invalid! Reload aborted.\n" "$(date +%T)"
    else
      printf "✅ [%s] HTTPD syntax OK. Reloading service...\n" "$(date +%T)"
      /usr/sbin/httpd -k graceful
    fi
  done
) &

# --- 6. Execution ---
# Execute Apache as PID 1 to handle container signals (SIGTERM/SIGKILL) correctly.
# We pass through any CMD arguments (like -D FOREGROUND) via "$@".
printf "🚀 [%s] Starting Apache web server for %s...\n" "$(date +%T)" "${REPO_FQDN}"
exec /usr/sbin/httpd -D FOREGROUND "$@"