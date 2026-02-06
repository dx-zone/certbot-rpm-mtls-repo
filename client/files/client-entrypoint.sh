#!/usr/bin/env bash
#: Title        : client-entrypoint.sh
#: Date         : $(date)
#: Author       : Daniel Cruz
#: Version      : 1.0
#: Description: : Setup a repository configuration based of a template file and substitute variables (REPO_FQDN, CA_NAME, CLIENT_NAME) from .env
#: Option       : None
set -e

# Substitute variables in the repository configuration
envsubst '$REPO_FQDN $CA_NAME $CLIENT_NAME' < /etc/yum.repos.d/cert.repo > /etc/yum.repos.d/cert.repo.tmp && \
  mv /etc/yum.repos.d/cert.repo.tmp /etc/yum.repos.d/cert.repo

echo "✅ Client configured to use the following repository: ${REPO_FQDN}"
echo "✅ Certificate Authority configured: ${CA_NAME}"
echo "✅ Client identity configured as ${CLIENT_NAME}"

# Keep container alive for testing
exec sleep infinity
