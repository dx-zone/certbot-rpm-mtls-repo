#!/usr/bin/env bash
set -euo pipefail

PERSISTENT_CSV="/etc/letsencrypt/certificates.csv"
DEFAULT_CSV="/usr/local/share/certbot-defaults/certificates.csv"

mkdir -p /etc/letsencrypt

if [ ! -f "$PERSISTENT_CSV" ]; then
  echo "No persistent certificates.csv found. Seeding default CSV..."
  cp "$DEFAULT_CSV" "$PERSISTENT_CSV"
else
  echo "Persistent certificates.csv already exists. Leaving it unchanged."
fi

exec /usr/bin/python3 /usr/local/bin/certbot-scripts/certbot_manager.py "$@"
