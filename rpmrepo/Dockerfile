###########################################################################################
# 📦 AUTOMATED RPM REPOSITORY & WEB SERVER (ALMALINUX 9)
#
# WHAT IS THIS?
# This container acts as a "Digital Warehouse" (RPM Repository). It hosts the
# certificate packages created by your Certbot container and serves them over
# a secure HTTPS connection using the Apache Web Server.
#
# 📋 HOW IT WORKS:
# 1. THE WATCHMAN:
#    Uses 'inotify' to monitor the /rpms folder. When a new RPM is added,
#    it automatically runs 'createrepo_c' to update the index so clients
#    can see the new package immediately.
#
# 2. THE SAFETY NET:
#    Apache requires SSL to start. This container creates a fallback
#    self-signed certificate at build-time so the server can start even
#    if the real Let's Encrypt certificates haven't been issued yet.
#
# 3. AUTOMATIC SSL SETUP:
#    On startup, the container injects your domain (FQDN) into the Apache
#    configuration and links the best available certificates.
#
# 🌐 REPOSITORY CONNECTIVITY:
#    Uses AlmaLinux's official HTTPS repository endpoints instead of
#    dynamically selected mirrors.
#
#    Configured repositories:
#      - BaseOS
#      - AppStream
#      - Extras
#      - CRB
#
#    This helps prevent Docker builds from failing because of slow,
#    unreachable, or unreliable package mirrors.
#
#    EPEL is installed separately through the epel-release package.
#
# 🔧 CONFIGURATION (.env file):
# This container relies on your project's root '.env' file:
#
#    REPO_FQDN:
#        Must match your repository domain (e.g., repo.example.com).
#
#    CA_NAME:
#        The friendly name displayed in the client's trust list.
#
# ⚠️ IMPORTANT:
# If REPO_FQDN changes, update both the .env file and certificates.csv,
# then restart the affected containers.
#
# 🚀 HOW TO USE THIS:
#    - MOUNT /rpms:
#      Link this directory to the Certbot container's RPM output folder.
#
#    - CREDENTIALS:
#      Place DNS .ini files in /etc/letsencrypt/secrets/ and ensure
#      they have restrictive permissions (chmod 600).
#
# 🛠️ CLIENT-SIDE USAGE:
# Once the client has the appropriate .repo file installed:
#
#    sudo dnf install repo-example-com-pki-repo
#
# This installs certificates into their configured system locations,
# including /etc/pki/tls/, and updates system trust as defined by
# the generated RPM package.
#
# ⚠️ SECURITY NOTES:
#    - The container runs as root to manage Apache, filesystem events,
#      and system-level certificate permissions.
#
#    - Fallback certificates are self-signed and should not be trusted
#      as production certificates.
#
#    - Private keys must be protected during packaging and distribution.
#
###########################################################################################


# =============================================================================
# 1. BASE IMAGE
# =============================================================================

FROM almalinux:9


# =============================================================================
# 2. IMAGE METADATA
# =============================================================================

LABEL org.opencontainers.image.maintainer="DevOp <devop@example.com>"


# =============================================================================
# 3. ALMALINUX REPOSITORY CONFIGURATION
# =============================================================================
#
# PROBLEM:
# AlmaLinux's default mirrorlist may return mirrors that are slow,
# unreachable, or affected by intermittent network/DNS issues.
#
# SOLUTION:
# Disable mirrorlist selection and activate the official AlmaLinux
# HTTPS repository endpoints.
#
# REPOSITORIES:
#   BaseOS     - Core operating system packages
#   AppStream  - Applications and supporting libraries
#   Extras     - Additional distribution packages
#   CRB        - CodeReady Builder dependencies
#
# IMPLEMENTATION:
#   - POSIX /bin/sh compatible.
#   - Validates expected repository configuration files.
#   - Disables mirrorlist entries.
#   - Enables existing official HTTPS baseurl entries.
#   - Fails the image build if configuration is unsuccessful.
#
# NOTE:
# This configuration is designed for the AlmaLinux 9 repository files
# provided by the selected base image.
# =============================================================================

RUN set -eu; \
    for repo in \
        /etc/yum.repos.d/almalinux-baseos.repo \
        /etc/yum.repos.d/almalinux-appstream.repo \
        /etc/yum.repos.d/almalinux-extras.repo \
        /etc/yum.repos.d/almalinux-crb.repo; do \
        test -f "$repo" || { \
            echo "ERROR: Missing repository configuration: $repo"; \
            exit 1; \
        }; \
        sed -i \
            -e 's|^[[:space:]]*mirrorlist=|#mirrorlist=|' \
            -e 's|^[[:space:]]*#[[:space:]]*baseurl=https://repo.almalinux.org/|baseurl=https://repo.almalinux.org/|' \
            "$repo"; \
        grep -q '^baseurl=https://repo.almalinux.org/' "$repo" || { \
            echo "ERROR: Official repository URL not enabled: $repo"; \
            exit 1; \
        }; \
    done


# =============================================================================
# 4. PACKAGE INSTALLATION
# =============================================================================
#
# Install EPEL first, followed by Apache, RPM repository utilities,
# and supporting tools.
#
# Package installation is separated into two DNF operations because
# EPEL must be available before installing EPEL-provided packages.
#
# Clean package metadata afterward to reduce image size.
# =============================================================================

RUN dnf install -y epel-release --setopt=install_weak_deps=False && \
    dnf install -y --nodocs \
        httpd \
        mod_ssl \
        createrepo_c \
        openssl \
        curl-minimal \
        tree \
        gettext \
        inotify-tools \
        rpmdevtools \
        rpmlint && \
    dnf clean all && \
    rm -rf /var/cache/dnf


# =============================================================================
# 5. DIRECTORY STRUCTURE & SECURITY
# =============================================================================
#
# Create repository and TLS directories.
#
# Generate a fallback self-signed certificate for Apache.
#
# Remove conflicting default Apache configuration files.
#
# Configure Apache to listen on port 443.
# =============================================================================

RUN mkdir -p \
        /var/www/html/repo/rpms \
        /etc/pki/tls/certs \
        /etc/pki/tls/private \
        /etc/letsencrypt/live && \
    \
    # Generate fallback certificate
    openssl req \
        -x509 \
        -nodes \
        -days 365 \
        -newkey rsa:2048 \
        -keyout /etc/pki/tls/private/fallback.key \
        -out /etc/pki/tls/certs/fallback.crt \
        -subj "/CN=localhost" && \
    \
    # Link fallback certificates to standard localhost certificate paths
    ln -sf \
        /etc/pki/tls/certs/fallback.crt \
        /etc/pki/tls/certs/localhost.crt && \
    \
    ln -sf \
        /etc/pki/tls/private/fallback.key \
        /etc/pki/tls/private/localhost.key && \
    \
    # Remove default Apache configurations that conflict with this service
    rm -f \
        /etc/httpd/conf.d/ssl.conf \
        /etc/httpd/conf.d/welcome.conf && \
    \
    # Configure global Apache directives
    printf 'Listen 443\nServerName localhost\n' \
        >> /etc/httpd/conf/httpd.conf


# =============================================================================
# 6. INITIAL RPM REPOSITORY METADATA
# =============================================================================
#
# Generate initial repository metadata.
# The runtime entrypoint is responsible for refreshing metadata when
# new RPM packages become available.
# =============================================================================

RUN createrepo_c /var/www/html/repo/


# =============================================================================
# 7. APACHE CONFIGURATION & ENTRYPOINT
# =============================================================================
#
# Copy:
#   - Apache HTTPS/mTLS configuration template
#   - RPM repository startup script
#   - mTLS client CA generation script
#
# Make the runtime scripts executable.
#
# Validate the Apache SSL module and configuration during the build.
# =============================================================================

COPY files/repo_with_auth.conf.template \
     /etc/httpd/conf.d/repo.conf.template

COPY files/rpmrepo-entrypoint.sh \
     /entrypoint.sh

COPY files/generate_mtls_client_ca.sh \
     /generate_mtls_client_ca.sh

RUN chmod +x \
        /entrypoint.sh \
        /generate_mtls_client_ca.sh && \
    \
    # Verify that the Apache SSL module is available
    httpd -M | grep -q ssl_module && \
    \
    # Validate Apache configuration syntax
    apachectl configtest


# =============================================================================
# 8. RUNTIME SETTINGS
# =============================================================================

# Apache HTTPS
EXPOSE 443/tcp

# Request graceful Apache shutdown
STOPSIGNAL SIGQUIT


# =============================================================================
# 9. ENTRYPOINT
# =============================================================================
#
# The entrypoint initializes the repository service and prepares
# runtime certificate configuration.
# =============================================================================

ENTRYPOINT ["/entrypoint.sh"]


# =============================================================================
# 10. DEFAULT COMMAND
# =============================================================================
#
# Run Apache in the foreground so Docker can manage the service lifecycle.
# =============================================================================

CMD ["-D", "FOREGROUND"]