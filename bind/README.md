# 🌐 Modular BIND DNS Server (AlmaLinux 9)

An enterprise-grade, state-aware BIND DNS container. This setup uses a modular configuration tree allowing a single image to function as either a **Primary (Master)** or **Secondary (Slave)** server via environment variables.

## 🏗️ Architecture Overview
The configuration is split into functional modules to ensure security and ease of maintenance:
- **`acl/`**: Network access control lists.
- **`tsig/`**: Cryptographic keys for Transfers and Dynamic DNS.
- **`primary/` & `secondary/`**: Role-specific manifests and zone logic.
- **`zones-db/`**: Static zone files (Master records).

---

## 💡 Human-Friendly Quick Start

### 1. Build the Image
Ensure you are in the root directory containing the `Dockerfile` and your `files/` folder.
```bash
docker build -t bind-dns:latest .

