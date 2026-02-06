#!/usr/bin/env bash

# --- Configuration ---
RPM_DIST_DIR="/rpms"

echo "🚀 Starting PKI-to-RPM Packaging Pipeline..."

# 1. Environment Setup
echo "📦 Step 1: Validating build environment..."
# Ensure metadata tools are present
if ! command -v createrepo_c &> /dev/null; then
    echo "📥 Installing metadata tools..."
    dnf install -y createrepo_c &>/dev/null
fi

# Initialize the rpmbuild structure if missing
rpmdev-setuptree &>/dev/null

# 2. Define the Packaging Engine
cert2rpm() {
    local DOMAIN=$1
    # Convert dots to dashes for valid RPM naming (e.g., app-mydatacenter-io)
    local DOMAIN_SPEC=$(echo "$DOMAIN" | tr '.' '-')

    echo "---------------------------------------------------"
    echo "🔍 Processing: $DOMAIN"

    # Ensure the build subdirectories exist (Redundancy check)
    mkdir -p ~/rpmbuild/{SOURCES,SPECS,RPMS,BUILD,BUILDROOT}

    if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        echo "⚠️  Skip: Certificate for $DOMAIN not found."
        return 1
    fi

    # Unique release version based on file timestamp (Epoch)
    local RELEASE_VERSION=$(stat -c %Y /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem)

    # 3. Prepare Sources
    cp -f /etc/letsencrypt/live/"$DOMAIN"/fullchain.pem ~/rpmbuild/SOURCES/"$DOMAIN".crt
    cp -f /etc/letsencrypt/live/"$DOMAIN"/privkey.pem ~/rpmbuild/SOURCES/"$DOMAIN".key

    # 4. Create Spec File
    echo "📝 Generating Spec file..."
    cat << EOF > ~/rpmbuild/SPECS/${DOMAIN_SPEC}-pki.spec
Name:           ${DOMAIN_SPEC}
Version:        1.0
Release:        ${RELEASE_VERSION}
Summary:        SSL Certificates for $DOMAIN
License:        Proprietary
BuildArch:      noarch
Source0:        $DOMAIN.crt
Source1:        $DOMAIN.key

%description
Automated PKI distribution for $DOMAIN.

%install
mkdir -p %{buildroot}/etc/pki/tls/certs
mkdir -p %{buildroot}/etc/pki/tls/private
mkdir -p %{buildroot}/etc/pki/ca-trust/source/anchors

install -m 644 %{SOURCE0} %{buildroot}/etc/pki/tls/certs/$DOMAIN.crt
install -m 600 %{SOURCE1} %{buildroot}/etc/pki/tls/private/$DOMAIN.key
# Link for OS trust store integration
ln -sf /etc/pki/tls/certs/$DOMAIN.crt %{buildroot}/etc/pki/ca-trust/source/anchors/$DOMAIN.pem

%post
/usr/bin/update-ca-trust extract || true

%files
%defattr(-,root,root,-)
/etc/pki/tls/certs/$DOMAIN.crt
/etc/pki/tls/private/$DOMAIN.key
/etc/pki/ca-trust/source/anchors/$DOMAIN.pem
EOF

    # 5. Build Package
    echo "🛠️  Building RPM..."
    rpmbuild -ba ~/rpmbuild/SPECS/${DOMAIN_SPEC}-pki.spec &>/dev/null

    # 6. Secure Move to Distribution Folder
    echo "🚚 Exporting RPM to $RPM_DIST_DIR..."
    cp ~/rpmbuild/RPMS/noarch/${DOMAIN_SPEC}-1.0-${RELEASE_VERSION}*.rpm "$RPM_DIST_DIR/"

    echo "✅ Successfully packed: $DOMAIN"
}

# 3. Execution Logic: Loop through all issued certificates
for d in /etc/letsencrypt/live/*/ ; do
     DOMAIN_NAME=$(basename "$d")
     if [ "$DOMAIN_NAME" != "README" ] && [ -d "$d" ]; then
         cert2rpm "$DOMAIN_NAME"
     fi
done

# --- 🧹 WORKSPACE CLEANUP (Outside loop to keep dirs available for next domain) ---
echo "---------------------------------------------------"
echo "🧹 Step 6: Cleaning up build workspace..."
rm -rf ~/rpmbuild/{BUILD,BUILDROOT,RPMS,SRPMS,SPECS,SOURCES}/*

# --- 🏁 REGENERATE REPOSITORY METADATA ---
echo "📦 Step 7: Regenerating Repository Metadata..."
# Run it directly on the distribution folder
createrepo_c --update "$RPM_DIST_DIR" &>/dev/null


echo "---------------------------------------------------"
echo "✨ PIPELINE COMPLETE! Repository is indexed and ready for DNF."
