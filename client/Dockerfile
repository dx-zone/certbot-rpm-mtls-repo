###########################################################################################
# 🐧 ALMALINUX 9 — RPM REPOSITORY & mTLS TEST CLIENT
#
# DESCRIPTION
# -----------
# Containerized AlmaLinux 9 client used to validate connectivity, package
# installation, and mutual TLS (mTLS) authentication against the RPM repository.
#
# PURPOSE
# -------
#   - Simulate a Linux client consuming the certificate RPM repository.
#   - Validate HTTPS and mTLS connectivity.
#   - Test DNF repository configuration and package installation.
#   - Inspect installed certificates and trust anchors.
#   - Provide a reproducible troubleshooting environment.
#
# REPOSITORY CONFIGURATION
# ------------------------
# AlmaLinux's default mirrorlist may select slow or unreachable mirrors.
#
# To improve build reliability, this image uses the official AlmaLinux HTTPS
# repositories instead of dynamically selected mirrors.
#
# Configured repositories:
#   - BaseOS
#   - AppStream
#   - Extras
#   - CRB
#
# SECURITY
# --------
#   - Uses the official AlmaLinux repository definitions and GPG verification.
#   - Does not embed private keys or mTLS credentials in the image.
#   - Runtime certificates and credentials should be provided through mounts.
#
# IMPORTANT
# ---------
# This image is intended for testing and validation, not as a production
# application container.
#
###########################################################################################


# =============================================================================
# 1. BASE IMAGE
# =============================================================================

FROM almalinux:9


# =============================================================================
# 2. ALMALINUX REPOSITORY CONFIGURATION
# =============================================================================
#
# Disable automatic mirror selection and enable the official HTTPS endpoints.
#
# This is the AlmaLinux 9 equivalent of the fix applied to the Certbot image.
#
# Fail the build if the expected repository files or HTTPS URLs are missing.
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
# 3. INSTALL TESTING UTILITIES
# =============================================================================
#
# curl-minimal       HTTPS and mTLS connectivity testing
# ca-certificates    CA trust verification
# dnf-plugins-core   DNF repository configuration and management
# file               File identification
# tree               Directory inspection
# gettext            Environment-variable substitution tools
#
# Reduce image size by cleaning DNF metadata.
# =============================================================================

RUN set -eu; \
    dnf install -y \
        --setopt=install_weak_deps=False \
        --nodocs \
        curl-minimal \
        ca-certificates \
        dnf-plugins-core \
        file \
        tree \
        gettext; \
    dnf clean all; \
    rm -rf /var/cache/dnf


# =============================================================================
# 4. PREPARE CERTIFICATE DIRECTORY STRUCTURE
# =============================================================================
#
# These paths match the expected certificate locations used by the
# Docker Compose bind mounts and generated certificate RPM packages.
# =============================================================================

RUN mkdir -p \
    /etc/pki/tls/certs \
    /etc/pki/tls/private \
    /etc/pki/ca-trust/source/anchors


# =============================================================================
# 5. COPY CLIENT CONFIGURATION AND SCRIPTS
# =============================================================================
#
# Copy the existing client repository configuration, mTLS validation script,
# and container entrypoint to their final locations.
#
# COPY is preferable to ADD because no archive extraction or remote URL
# handling is required.
# =============================================================================

COPY files/etc_yum.repos.d_cert.repo \
     /etc/yum.repos.d/cert.repo

COPY files/validate_client_to_rpmrepo_mtls.sh \
     /validate_client_to_rpmrepo_mtls.sh

COPY files/client-entrypoint.sh \
     /client-entrypoint.sh


# =============================================================================
# 6. SCRIPT PERMISSIONS AND COMMAND ALIAS
# =============================================================================
#
# Preserve the original executable permissions and validate shell syntax.
#
# The validate-mtls symlink provides a convenient command for testing
# repository connectivity inside the running container.
# =============================================================================

RUN set -eu; \
    chmod 755 \
        /client-entrypoint.sh \
        /validate_client_to_rpmrepo_mtls.sh; \
    ln -sf \
        /validate_client_to_rpmrepo_mtls.sh \
        /usr/local/bin/validate-mtls; \
    /bin/sh -n /client-entrypoint.sh; \
    /bin/sh -n /validate_client_to_rpmrepo_mtls.sh


# =============================================================================
# 7. ENTRYPOINT
# =============================================================================
#
# Preserve the existing client initialization workflow.
# =============================================================================

ENTRYPOINT ["/client-entrypoint.sh"]