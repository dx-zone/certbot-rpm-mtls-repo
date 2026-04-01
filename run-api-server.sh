#!/bin/bash
# run-server.sh - Build and execute the Cert Manager API

APP_NAME="cert-manager-api"
BASE_DIR="/opt/certbot"
LIVE_DIR="${BASE_DIR}/datastore/certbot-data/letsencrypt/live/repo.example.com"
PKI_DIR="${BASE_DIR}/secrets/rpmrepo-secrets/pki_mtls_material"

echo "--- Building $APP_NAME ---"
go build -o $APP_NAME .

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "--- Starting Server ---"
sudo ./$APP_NAME \
  -listen :8443 \
  -tls-cert "${LIVE_DIR}/fullchain.pem" \
  -tls-key "${LIVE_DIR}/privkey.pem" \
  -client-ca "${PKI_DIR}/ca.crt" \
  -allowed-cns ./clients.txt \
  -ip-list ./ips.txt \
  -ip-policy allow \
  -cert-csv ./certificates.csv

