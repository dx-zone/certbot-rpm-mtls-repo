###########################################################################################
#🛠️ ENTERPRISE BIND DNS SERVER (ALMALINUX 9)
# WHAT IS THIS?
# This container is a Modular BIND DNS Authority. It is designed to be "State-Aware,"
# allowing a single image to function as either a Primary (Master) or Secondary (Slave)
# server simply by toggling an environment variable.
# 📋 HOW TO USE THIS:
# 1. DEFINE THE ROLE:
# Set the 'DNS_ROLE' environment variable to either 'primary' or 'secondary'.
# Example: -e DNS_ROLE=primary
# 2. CONFIGURATION STRUCTURE:
# The setup uses a modular 'include' tree. All configurations live in /etc/named/
# subdirectories (acl, tsig, general-conf, primary, secondary) for clean management.
# 3. MOUNTING VOLUMES (Optional but Recommended):
# To manage zones from the host, mount your configuration tree:
# -v $(pwd)/files:/etc/named:Z
# ⚙️ HOW IT WORKS (The Switcher):
# - [The Entrypoint]: 'entrypoint.sh' detects the $DNS_ROLE variable.
# - [The Symlink]: It creates a symlink at /etc/named.conf pointing to the
# active manifest (e.g., /etc/named/primary/primary.named.conf).
# - [The Guard]: 'named-checkconf' validates the syntax before the service starts.
# 📦 DISTRIBUTION:
# This container exposes standard DNS ports (53/UDP/TCP).
# Logs are written to /var/log/named/ for easy auditing and persistent monitoring.
# ⚠️ SECURITY NOTE:
# The service runs as the 'named' user. TSIG keys are restricted to 640 permissions
# to prevent unauthorized access to transaction signatures.

###########################################################################################

###############################################################################
# 🛠️ ENTERPRISE BIND DNS SERVER (ALMALINUX 9)
#
# DESCRIPTION:
# This image provides a modular BIND DNS service capable of acting as either
# a Primary (Master) or Secondary (Slave) server. Role switching is handled
# at runtime via symlinks and the DNS_ROLE environment variable.
#
# USAGE:
# docker build -t my-dns-server .
# docker run -d -e DNS_ROLE=primary -p 53:53/udp my-dns-server
###############################################################################

# 1. BASE IMAGE: Using a stable, major-version tag
FROM almalinux:9

# 2. METADATA
LABEL org.opencontainers.image.title="Modular BIND DNS"
LABEL org.opencontainers.image.maintainer="DevOps <devops@mydatacenter.io>"

# 3. INSTALLATION: BIND service and troubleshooting utilities
RUN dnf -y update && \
    dnf -y install bind bind-utils && \
    dnf clean all

# 4. STRUCTURE: Pre-create the directory tree defined in your 'tree' output
RUN mkdir -p /etc/named/acl \
             /etc/named/general-conf \
             /etc/named/primary/zones-conf \
             /etc/named/secondary/zones-conf \
             /etc/named/tsig/keys/dns-update \
             /etc/named/tsig/keys/zone-transfer \
             /etc/named/tsig/keys/zone-update \
             /etc/named/zones-db \
             /var/log/named \
             /var/named/slaves

# 5. CONFIGURATION: Copy your local 'files' directory into the container
# Ensure all your .conf and .key files are inside a local folder named 'files'
COPY . /etc/named/

# 6. PERMISSIONS: Security hardening
# - BIND runs as 'named' user.
# - We grant 'named' ownership of zones-db for Dynamic DNS (.jnl files).
RUN chmod +x /etc/named/entrypoint.sh && \
    chown -R root:named /etc/named /var/named /var/log/named && \
    chmod -R 770 /var/named /var/log/named && \
    chmod 640 /etc/named/tsig/keys/*/*.key

# 7. NETWORKING: Expose standard DNS ports
EXPOSE 53/tcp 53/udp

# 8. VOLUMES: Ensure persistence for zones and logs
VOLUME ["/etc/named", "/var/named", "/var/log/named"]

# 9. EXECUTION: Hand off to the role-switcher script
ENTRYPOINT ["/etc/named/entrypoint.sh"]


###############################################################################
# 🛠️ ENTERPRISE BIND DNS SERVER (ALMALINUX 9)
#
# DESCRIPTION:
# This image provides a modular BIND DNS service capable of acting as either
# a Primary (Master) or Secondary (Slave) server. Role switching is handled
# at runtime via symlinks and the DNS_ROLE environment variable.
#
# USAGE:
# docker build -t my-dns-server .
# docker run -d -e DNS_ROLE=primary -p 53:53/udp my-dns-server
###############################################################################

# 1. BASE IMAGE: Using a stable, major-version tag
FROM almalinux:9

# 2. METADATA
LABEL org.opencontainers.image.title="Modular BIND DNS"
LABEL org.opencontainers.image.maintainer="DevOps <devops@mydatacenter.io>"

# 3. INSTALLATION: BIND service and troubleshooting utilities
RUN dnf -y update && \
    dnf -y install bind bind-utils && \
    dnf clean all

# 4. STRUCTURE: Pre-create the directory tree defined in your 'tree' output
RUN mkdir -p /etc/named/acl \
             /etc/named/general-conf \
             /etc/named/primary/zones-conf \
             /etc/named/secondary/zones-conf \
             /etc/named/tsig/keys/dns-update \
             /etc/named/tsig/keys/zone-transfer \
             /etc/named/tsig/keys/zone-update \
             /etc/named/zones-db \
             /var/log/named \
             /var/named/slaves

# 5. CONFIGURATION: Copy your local 'files' directory into the container
# Ensure all your .conf and .key files are inside a local folder named 'files'
COPY . /etc/named/

# 6. PERMISSIONS: Security hardening
# - BIND runs as 'named' user.
# - We grant 'named' ownership of zones-db for Dynamic DNS (.jnl files).
RUN chmod +x /etc/named/entrypoint.sh && \
    chown -R root:named /etc/named /var/named /var/log/named && \
    chmod -R 770 /var/named /var/log/named && \
    chmod 640 /etc/named/tsig/keys/*/*.key

# 7. NETWORKING: Expose standard DNS ports
EXPOSE 53/tcp 53/udp

# 8. VOLUMES: Ensure persistence for zones and logs
VOLUME ["/etc/named", "/var/named", "/var/log/named"]

# 9. EXECUTION: Hand off to the role-switcher script
ENTRYPOINT ["/etc/named/entrypoint.sh"]

