# Check if the client-test container is resolving the REPO_FQDN defined in the srvice > rpmrepo > hostname variable sourced from .env
getent hosts repo.mydatacenter.io

# Validate rpmrepo access
curl -v \
  --cert /etc/pki/tls/certs/client-identity.crt \
  --key  /etc/pki/tls/private/client-identity.key \
  --cacert /path/to/ca-that-signed-fallback.crt \
  https://repo.mydatacenter.io/

# Quick test-only bypass (not for real use)
curl -vk --cert "$CRT" --key "$KEY" "$REPO_FQDN"

# Only inspect the server's certificate
openssl s_client -connect repo.mydatacenter.io:443 -servername repo.mydatacenter.io </dev/null \
  | openssl x509 -noout -subject -issuer -dates

# 1. First, grab the server cert from the repo
openssl s_client -connect repo.mydatacenter.io:443 -servername repo.mydatacenter.io -showcerts </dev/null \
  | openssl x509 -outform PEM > /tmp/repo-server.crt

# 2. Then curl using that as the trusted CA
curl -v \
  --cacert /tmp/repo-server.crt \
  --cert /etc/pki/tls/certs/client-identity.crt \
  --key  /etc/pki/tls/private/client-identity.key \
  https://repo.mydatacenter.io/

# 3. Validate the mTLS requirement is actually enforced
curl -vk https://repo.mydatacenter.io/

# 4. Validate you’re getting repo content (not just “it responds”)
curl -vk \
  --cert /etc/pki/tls/certs/client-identity.crt \
  --key  /etc/pki/tls/private/client-identity.key \
  https://repo.mydatacenter.io/ \
  | head

curl -vk \
  --cert /etc/pki/tls/certs/client-identity.crt \
  --key  /etc/pki/tls/private/client-identity.key \
  https://repo.mydatacenter.io/repodata/repomd.xml | head

