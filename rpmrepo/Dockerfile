###########################################################################################
# 📦 AUTOMATED RPM REPOSITORY & WEB SERVER (ALMALINUX 9)
# 
# WHAT IS THIS?
# This container acts as a "Digital Warehouse" (RPM Repository). It hosts the 
# certificate packages created by your Certbot container and serves them over 
# a secure HTTPS connection using the Apache Web Server.
#
# 📋 HOW IT WORKS:
# 1. THE WATCHMAN: Uses 'inotify' to monitor the /rpms folder. When a new RPM 
#    is added, it automatically runs 'createrepo_c' to update the index so 
#    clients can see the new package immediately.
#
# 2. THE SAFETY NET: Apache requires SSL to start. This container creates a 
#    "Fallback" certificate at build-time so the server starts even if your 
#    real Let's Encrypt certs haven't been issued yet.
#
# 3. AUTOMATIC SSL SETUP: On startup, the container injects your domain (FQDN) 
#    into the Apache config and links the best available certificates.
#
# 🔧 CONFIGURATION (.env file):
# This container relies on your project's root '.env' file:
# - REPO_FQDN: Must match your domain (e.g., repo.mydatacenter.io). 
# - CA_NAME: The friendly name seen in the client's 'trust list'.
#
# ⚠️ IMPORTANT: If you change REPO_FQDN, you must update BOTH the .env file 
#    and certificates.csv, then restart the containers.
#
# 🚀 HOW TO USE THIS:
# - MOUNT /rpms: Link this to your Certbot container's output folder.
# - CREDENTIALS: Place your DNS .ini files in /etc/letsencrypt/secrets/ 
#   and ensure they are 'chmod 600'.
#
# 🛠️ CLIENT-SIDE USAGE:
# Once the client has your '.repo' file installed, they can run:
# 'sudo dnf install repo-mydatacenter-io-pki-repo'
# This will install the certs to /etc/pki/tls/ and update the system trust.
#
# ⚠️ SECURITY NOTE:
# Runs as ROOT to manage Apache services, monitor filesystem events, 
# and handle system-level certificate permissions.
###########################################################################################

FROM almalinux:9

LABEL org.opencontainers.image.maintainer="DevOp <devop@example.com>"

# 1. INSTALLATION: Combined all packages into one layer
RUN dnf install -y epel-release --setopt=install_weak_deps=False && \
    dnf install -y --nodocs \
        httpd mod_ssl createrepo_c openssl curl-minimal \
        tree gettext inotify-tools rpmdevtools rpmlint && \
    dnf clean all && rm -rf /var/cache/dnf

# 2. DIRECTORY STRUCTURE & SECURITY
# Combined directory creation, fallback cert generation, and config cleanup
RUN mkdir -p /var/www/html/repo/rpms \
             /etc/pki/tls/certs \
             /etc/pki/tls/private \
             /etc/letsencrypt/live && \
    # Generate Fallback Cert
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/fallback.key \
        -out /etc/pki/tls/certs/fallback.crt \
        -subj "/CN=localhost" && \
    # Link localhost certs
    ln -sf /etc/pki/tls/certs/fallback.crt /etc/pki/tls/certs/localhost.crt && \
    ln -sf /etc/pki/tls/private/fallback.key /etc/pki/tls/private/localhost.key && \
    # Cleanup default Apache noise
    rm -f /etc/httpd/conf.d/ssl.conf /etc/httpd/conf.d/welcome.conf && \
    # Append necessary global directives
    echo -e "Listen 443\nServerName localhost" >> /etc/httpd/conf/httpd.conf

# 3. REPOSITORY SEEDING
RUN createrepo_c /var/www/html/repo/

# 4. CONFIGURATION & ENTRYPOINT
# Consolidating COPY and verification
COPY files/repo_with_auth.conf.template /etc/httpd/conf.d/repo.conf.template
COPY files/rpmrepo-entrypoint.sh /entrypoint.sh
COPY files/generate_mtls_client_ca.sh /generate_mtls_client_ca.sh

RUN chmod +x /entrypoint.sh /generate_mtls_client_ca.sh && \
    # Verify SSL module and basic config syntax
    httpd -M | grep -q ssl_module && \
    # Note: This might warn about missing template variables, which is fine
    apachectl configtest

# 5. RUNTIME SETTINGS
EXPOSE 443/tcp
STOPSIGNAL SIGQUIT

ENTRYPOINT ["/entrypoint.sh"]
CMD ["-D", "FOREGROUND"]
