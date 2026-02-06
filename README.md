# 🔐 Enterprise PKI & Secure RPM Distribution Pipeline

An automated, containerized system for issuing **Let’s Encrypt TLS certificates via DNS-01**, packaging them as **RPMs**, and distributing them through a **secure, client-authenticated (mTLS) RPM repository**.

This project is designed for **enterprise and internal infrastructure**, providing a controlled, auditable pipeline for sensitive PKI material.

---

## 🧭 Project Capabilities

| Problem | Solution |
| :--- | :--- |
| **No Port 80/443 Exposure** | DNS-01 challenges via Cloudflare or RFC2136 |
| **Standardized Distribution** | Certificates and private keys are packaged as versioned RPMs |
| **Strict Access Control** | Apache RPM repository enforced by **mTLS (Mutual TLS)** |
| **Lifecycle Automation** | Continuous monitoring loop for issuance, renewal, and repodata updates |
| **Declarative Management** | CSV-based certificate inventory management |

---

## 🏗️ Architecture Overview

The system is orchestrated via `docker-compose` and consists of three specialized roles:

### 1️⃣ Certbot Manager (The Factory)
- **Role**: Continuous certificate issuance and packaging.
- **Engine**: Python-based manager (`certbot_manager.py`) monitoring `certificates.csv`.
- **Packaging**: Post-issuance hook (`cert2rpm.sh`) builds AlmaLinux-compatible RPMs automatically.

### 2️⃣ RPM Repository (The Vault)
- **Role**: Secure distribution hub serving RPMs over HTTPS.
- **Security**: Requires clients to present a valid certificate signed by the internal CA.
- **Automation**: `inotify` watcher triggers `createrepo_c` updates on new package arrival.

### 3️⃣ Linux Client (The Consumer)
- **Role**: Verification and simulation of an end-user machine.
- **Validation**: Proves connectivity, mTLS handshake, and DNF repository integration.

---

## 🚀 Quick Start

### 1. Prerequisites
- Docker & Docker Compose
- DNS Provider credentials (Cloudflare API Token or RFC2136 TSIG Key)
- `sudo` access (for host-side directory initialization)

### 2. Configuration
Create a `.env` file in the root directory:
```bash
REPO_FQDN=repo.mydatacenter.io
CA_NAME=My-Internal-CA
CLIENT_NAME=workstation-01
```

Configure your certificates in `certbot/files/certificates.csv`:
```csv
fqdn,dns_provider,email
repo.mydatacenter.io,cloudflare,admin@mydatacenter.io
app.mydatacenter.io,rfc2136,admin@mydatacenter.io
```

### 3. Deployment
Use the unified stack manager for all operations:

```bash
# 1. Initialize workspace and permissions
sudo ./manage-certbo-repo-client-stack.sh init

# 2. Add your secrets to:
# secrets/certbot-secrets/ini/cloudflare.ini (or rfc2136.ini)

# 3. Launch the stack
./manage-certbo-repo-client-stack.sh up
```

---

## 🛠️ Stack Management Reference

The `./manage-certbo-repo-client-stack.sh` script is the primary entrypoint for operations:

| Command | Description |
| :--- | :--- |
| `init` | 🚀 Setup directories and fix UID 1000 permissions |
| `up` | ⚡ Start the stack and wait for service health |
| `status` | 📊 Show container health and certificate info |
| `check pipeline` | 🔍 Run end-to-end diagnostic |
| `check mtls` | 🔐 Audit/Rotate mTLS materials |
| `rebuild` | 🛠️  Recreate containers (applies config/env changes) |
| `logs` | 📜 Follow all container logs |
| `down` | 🛑 Stop and remove containers |
| `clean` | 🧹 Full wipe: Delete data, images, and orphans |

---

## 📁 Repository Structure

```bash
.
├── manage-certbo-repo-client-stack.sh  # 🚀 Primary Management Entrypoint
├── docker-compose.yml                  # 🧩 Service Orchestration
├── certbot/                            # 🔐 Certificate Factory
│   ├── files/certbot_manager.py        # Lifecycle controller
│   └── files/cert2rpm.sh               # RPM packaging engine
├── rpmrepo/                            # 📦 Secure RPM Repository
│   ├── files/rpmrepo-entrypoint.sh     # Apache & mTLS bootstrapper
│   └── files/generate_mtls_client_ca.sh # Internal PKI generator
├── client/                             # 🧪 Test Client
├── datastore/                          # 💾 Persistent Data (Certificates, RPMs)
└── secrets/                            # 🔑 Sensitive Keys (DNS APIs, mTLS CA)
```

---

## 🔐 Security Boundaries & Trust Model

### 1. External Trust (Server)
The `rpmrepo` uses Let's Encrypt certificates issued for `${REPO_FQDN}`. This ensures the client can verify the repository's identity using standard OS trust stores.

### 2. Internal Trust (Client)
Access to RPMs is restricted via **mTLS**. 
- The `rpmrepo` container generates an **Internal CA**.
- Clients must present a certificate signed by this CA to pass Apache's `SSLVerifyClient require` gate.
- This creates a private, authenticated channel for distributing sensitive private keys.

### 3. Data Protection
- **Secrets**: `./secrets/` must be protected (mode `700`) and never committed.
- **Datastore**: `./datastore/` contains live private keys and should be treated as high-security storage.
- **Permissions**: The stack uses UID `1000` to align container processes with standard Linux users.

---

## 🕵️ Troubleshooting & Diagnostics

If the pipeline fails, use the built-in diagnostic tools:

1. **Check Pipeline**: `./manage-certbo-repo-client-stack.sh check pipeline`
   - Validates DNS, Network, mTLS Handshake, and DNF download.
2. **Audit mTLS**: `./manage-certbo-repo-client-stack.sh check mtls`
   - Verifies the integrity of the internal CA and client identities.
3. **Logs**: `./manage-certbo-repo-client-stack.sh logs`
   - Tail Certbot and Apache logs for real-time errors.

---

## 📜 License
This project is intended for internal enterprise use. See local compliance guidelines for PKI management.