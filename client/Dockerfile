# 🐧 ALMALINUX TEST CLIENT
FROM almalinux:9

# 1. Install basic tools for testing (dnf, curl, gettext, etc.)
RUN dnf install -y curl-minimal ca-certificates dnf-plugins-core file tree gettext && \
    dnf clean all

# 2. Prepare the directory structure for the volume mounts
# These match the paths in your docker-compose.yml
RUN mkdir -p /etc/pki/tls/certs \
             /etc/pki/tls/private \
             /etc/pki/ca-trust/source/anchors

# 3. Copy static Repo config, mTLS validation script, and entrypoint
ADD files/ /tmp/files/
RUN mv /tmp/files/etc_yum.repos.d_cert.repo /etc/yum.repos.d/cert.repo && \
    mv /tmp/files/validate_client_to_rpmrepo_mtls.sh /validate_client_to_rpmrepo_mtls.sh && \
    mv /tmp/files/client-entrypoint.sh /client-entrypoint.sh && \
    chmod +x /client-entrypoint.sh /validate_client_to_rpmrepo_mtls.sh && \
    ln -sf /validate_client_to_rpmrepo_mtls.sh /usr/local/bin/validate-mtls && \
    rm -rf /tmp/files

ENTRYPOINT ["/client-entrypoint.sh"]