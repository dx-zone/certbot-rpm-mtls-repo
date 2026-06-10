###########################################################################################
# 🛠️ AUTOMATED CERTBOT DNS-01 MANAGER (ALMALINUX)
#
# WHAT IS THIS?
# This container is a "Certificate Factory." It talks to Let's Encrypt to get
# SSL certificates for your domains and then automatically packages them into
# an RPM file so they can be installed on other Linux servers like any other software.
#
# 📋 HOW TO USE THIS:
#
# 1. SETUP THE LIST (certificates.csv):
#    Create a simple text file named 'certificates.csv'. Each line should look like this:
#    fqdn,dns_provider,email
#    repo.example.com,cloudflare,admin@example.com
#
# 2. PROVIDE THE KEYS (.ini files):
#    If you use 'cloudflare' in the list above, you MUST provide a file named
#    'cloudflare.ini' containing your API keys.
#    Place this in your mounted /etc/letsencrypt/secrets/ folder.
#
# 3. SET PERMISSIONS (Crucial!):
#    Certbot is picky about security. On your host machine, run:
#    chown root:root /etc/letsencrypt/secrets/*.ini
#    chmod 600 /etc/letsencrypt/secrets/*.ini
#
# ⚙️ HOW IT WORKS (The Pipeline):
#    - [The Manager]: 'certbot_manager.py' reads your CSV and requests the certs.
#    - [The Packer]: Once the cert is issued, 'cert2rpm.sh' is triggered automatically.
#    - [The RPM]: A .rpm file is built containing the cert and its private key.
#    - [The Hand-off]: The RPM is moved to /rpms/ for distribution to Linux clients.
#
# 📦 DISTRIBUTION:
#    This container saves certificates in /etc/letsencrypt/live/ for local use.
#    However, it also drops a finished RPM into the /rpms/ directory.
#    If you run a 'repo' container alongside this one, it will detect the new RPM
#    and allow your clients to 'dnf install' it.
#
#    When a client installs the RPM, the files land in these standard locations:
#    - Public Cert:  /etc/pki/tls/certs/
#    - Private Key:  /etc/pki/tls/private/
#    - Trust Anchor: /etc/pki/ca-trust/source/anchors/ (Enables OS-wide trust)
#
# ⚠️ SECURITY NOTE:
#    The container runs as ROOT. This is required to build RPMs and manage
#    system-level security folders and permissions.
###########################################################################################

# 1. BASE IMAGE
FROM almalinux:latest

# 2. METADATA
LABEL org.opencontainers.image.maintainer="DevOps <devops@example.com>"

# 3. INSTALLATION:
RUN dnf install -y epel-release --setopt=install_weak_deps=False && \
    dnf install -y certbot \
                   python3-certbot-dns-cloudflare \
                   python3-certbot-dns-rfc2136 \
                   rpm-build \
                   rpmdevtools \
                   tree \
                   openssl && \
    dnf clean all && rm -rf /var/cache/dnf

# 4. DIRECTORIES: Create necessary paths for Certbot and RPM builds
RUN mkdir -p /etc/letsencrypt/secrets \
             /var/log/letsencrypt \
             /var/lib/letsencrypt \
             /usr/local/bin/certbot-scripts \
             /usr/local/share/certbot-defaults \
             /rpms && \
    chmod 755 /rpms

# 5. VOLUMES: Documents runtime persistence paths.
# In docker compose, these paths are provided by explicit bind mounts.
VOLUME ["/etc/letsencrypt", "/rpms"]

# 6. FILES:
# Copy the default CSV outside /etc/letsencrypt so it is NOT hidden by the
# /etc/letsencrypt bind mount at runtime.
COPY files/certificates.csv /usr/local/share/certbot-defaults/certificates.csv

# Copy runtime scripts.
COPY files/certbot_manager.py files/cert2rpm.sh files/README files/entrypoint.sh /usr/local/bin/certbot-scripts/

# 7. PERMISSIONS: Ensure runtime scripts are executable.
RUN chmod +x \
    /usr/local/bin/certbot-scripts/certbot_manager.py \
    /usr/local/bin/certbot-scripts/cert2rpm.sh \
    /usr/local/bin/certbot-scripts/entrypoint.sh

# 8. RUNTIME: Set environment and user context
ENV PYTHONUNBUFFERED=1

# Using root for issuance/RPM building (required for certbot & rpmbuild directory access)
USER root

# 9. ENTRYPOINT
# The wrapper seeds /etc/letsencrypt/certificates.csv only if missing,
# then hands off to certbot_manager.py.
ENTRYPOINT ["/usr/local/bin/certbot-scripts/entrypoint.sh"]

# CMD provides the default arguments (overridable)
CMD ["--csv", "/etc/letsencrypt/certificates.csv", "--frequency", "60", "--hook", "/usr/local/bin/certbot-scripts/cert2rpm.sh"]
