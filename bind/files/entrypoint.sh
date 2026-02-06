#!/bin/bash
###############################################################################
# 🚀 BIND ROLE-SWITCHER ENTRYPOINT
# This script configures the container's persona (Primary vs Secondary)
# based on the $DNS_ROLE environment variable.
###############################################################################

# 1. SET THE ROLE (Default to 'primary' if not provided)
ROLE=${DNS_ROLE:-primary}
echo "Starting BIND in [$ROLE] mode..."

# 2. CREATE THE ACTIVE SYMLINK
# BIND looks for /etc/named.conf; we point it to your role-specific manifest.
ln -sf /etc/named/${ROLE}/${ROLE}.named.conf /etc/named.conf

# 3. VERIFY CONFIGURATION
# Runs a syntax check before actually starting the service to prevent crashes.
named-checkconf /etc/named.conf
if [ $? -ne 0 ]; then
    echo "❌ ERROR: BIND configuration check failed. Check your includes."
    exit 1
fi

# 4. START BIND
# -g : Run in foreground (required for Docker)
# -u : Run as the 'named' user (security best practice)
# -c : Use the symlinked config file
exec /usr/sbin/named -g -u named -c /etc/named.conf

