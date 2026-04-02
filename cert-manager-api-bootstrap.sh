#!/usr/bin/env bash
################################################################################
# 🔐 bootstrap-cert-manager-api.sh
# ------------------------------------------------------------------------------
# Purpose:
#   Prepare the files required by cert-manager-api, generate missing API mTLS
#   material when needed, and optionally launch the API.
#
# Priority order:
#   1. CLI flags
#   2. .env values
#   3. Built-in defaults
#
# Security model:
#   - API mTLS identities should be separate from rpmrepo mTLS identities
#   - This script prefers API_MTLS_* variables first
#   - Then falls back to RPMREPO_MTLS_* and finally legacy shared vars
################################################################################

set -euo pipefail

# ------------------------------------------------------------------------------
# 🎨 Output helpers
# ------------------------------------------------------------------------------
NC='\033[0m'
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'

log()     { printf "%b[%s]%b %s\n" "${CYAN}" "$(date +%T)" "${NC}" "$*"; }
info()    { printf "%bℹ%b  %s\n" "${BLUE}" "${NC}" "$*"; }
success() { printf "%b✅%b %s\n" "${GREEN}" "${NC}" "$*"; }
warn()    { printf "%b⚠️%b  %s\n" "${YELLOW}" "${NC}" "$*"; }
error()   { printf "%b❌%b %s\n" "${RED}" "${NC}" "$*" >&2; }

header() {
  printf "\n%b%s%b\n" "${CYAN}" "──────────────────────────────────────────────────────────────" "${NC}"
  printf "%b%s%b\n" "${BOLD}" "$1" "${NC}"
  printf "%b%s%b\n" "${CYAN}" "──────────────────────────────────────────────────────────────" "${NC}"
}

die() {
  error "$*"
  exit 1
}

# ------------------------------------------------------------------------------
# ⚙️ Defaults
# ------------------------------------------------------------------------------
ENV_FILE=".env"

DEFAULT_REPO_FQDN="repo.example.com"

# Legacy/shared defaults
DEFAULT_CA_NAME="Internal-RPM-Repo-CA"
DEFAULT_CLIENT_NAME="mtls-client-identity"

# API-specific defaults
DEFAULT_API_MTLS_CA_NAME="Internal-Cert-Manager-API-CA"
DEFAULT_API_MTLS_CLIENT_NAME="cert-manager-automation-client"

DEFAULT_API_PORT="8000"
DEFAULT_API_BIN="./api/cert-manager-api"
DEFAULT_IP_POLICY="allow"
DEFAULT_CERT_MANAGER="certbot"

DEFAULT_WORK_BASE="./secrets/api-secrets"
DEFAULT_PKI_DIR="${DEFAULT_WORK_BASE}/pki_mtls_material"

DEFAULT_IPS_FILE="./api/mtls-api-clients-ip.txt"
DEFAULT_CLIENTS_FILE="./api/mtls-api-clients-cn.txt"
DEFAULT_CA_FILE="./secrets/api-secrets/pki_mtls_material/ca.crt"
DEFAULT_CERT_CSV="./datastore/certbot-data/letsencrypt/certificates.csv"

DEFAULT_DAYS_VALID_CA=3650
DEFAULT_DAYS_VALID_SERVER=825
DEFAULT_DAYS_VALID_CLIENT=365

# ------------------------------------------------------------------------------
# 🧩 CLI-overridable variables
# ------------------------------------------------------------------------------
DRY_RUN=false
RUN_API=false
FORCE=false

API_BIN=""
REPO_FQDN=""

# Names used specifically for API-generated mTLS material
API_MTLS_CA_NAME_EFFECTIVE=""
API_MTLS_CLIENT_NAME_EFFECTIVE=""

API_PORT=""
LISTEN_ADDR=""
IP_POLICY=""
CERT_MANAGER=""
WORK_BASE=""
PKI_DIR=""
IPS_FILE=""
CLIENTS_FILE=""
CA_CERT_PATH=""
TLS_CERT_PATH=""
TLS_KEY_PATH=""
CERT_CSV=""
ALLOWED_IPS=""
ALLOWED_CNS=""

# ------------------------------------------------------------------------------
# 🛠 Helpers
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage:
  ./bootstrap-cert-manager-api.sh [options]

Options:
  --run-api                 Prepare files, then launch the API
  --dry-run                 Show actions without making changes
  --force                   Regenerate generated files and overwrite them

  --api-bin PATH            API binary path
  --fqdn DOMAIN             Repo/API FQDN

  --api-mtls-ca-name NAME   API mTLS root CA Common Name
  --api-mtls-client-name NAME
                            API mTLS client identity CN

  --api-port PORT           API port (used if --listen is not set)
  --listen ADDR             Full listen address, example: :8000
  --ip-policy POLICY        allow|deny

  --work-base PATH          Base working directory for generated material
  --ips-file PATH           IP ACL file path
  --clients-file PATH       Allowed CN file path
  --ca-file PATH            CA cert path for API mTLS validation
  --tls-cert PATH           API server certificate path
  --tls-key PATH            API server private key path
  --cert-csv PATH           certificates.csv path
  --cert-manager NAME       Certificate manager name passed to API

  --allowed-ip VALUE        Add IP/CIDR to ACL (repeatable)
  --allowed-cn VALUE        Add allowed client CN (repeatable)

  --help                    Show help
EOF
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf "%b🧪 DRY-RUN%b %s\n" "${YELLOW}" "${NC}" "$*"
  else
    eval "$@"
  fi
}

ensure_parent_dir() {
  local path="$1"
  local dir
  dir="$(dirname "$path")"
  run_cmd "mkdir -p '$dir'"
}

write_file() {
  local target="$1"
  local content="$2"

  ensure_parent_dir "$target"

  if [[ -f "$target" && "$FORCE" != "true" ]]; then
    info "Keeping existing file: $target"
    return 0
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "%b🧪 DRY-RUN%b would write file: %s\n" "${YELLOW}" "${NC}" "$target"
    return 0
  fi

  printf "%s" "$content" > "$target"
  success "Wrote file: $target"
}

append_unique_line() {
  local file="$1"
  local line="$2"

  ensure_parent_dir "$file"

  if [[ "$DRY_RUN" == "true" ]]; then
    printf "%b🧪 DRY-RUN%b would ensure line exists in %s: %s\n" "${YELLOW}" "${NC}" "$file" "$line"
    return 0
  fi

  touch "$file"
  grep -Fxq "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

file_missing_or_empty() {
  local path="$1"
  [[ ! -f "$path" || ! -s "$path" ]]
}

# ------------------------------------------------------------------------------
# 🔎 Parse CLI args
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-api) RUN_API=true ;;
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    --api-bin) API_BIN="${2:?Missing value for --api-bin}"; shift ;;
    --fqdn) REPO_FQDN="${2:?Missing value for --fqdn}"; shift ;;
    --api-mtls-ca-name) API_MTLS_CA_NAME_EFFECTIVE="${2:?Missing value for --api-mtls-ca-name}"; shift ;;
    --api-mtls-client-name) API_MTLS_CLIENT_NAME_EFFECTIVE="${2:?Missing value for --api-mtls-client-name}"; shift ;;
    --api-port) API_PORT="${2:?Missing value for --api-port}"; shift ;;
    --listen) LISTEN_ADDR="${2:?Missing value for --listen}"; shift ;;
    --ip-policy) IP_POLICY="${2:?Missing value for --ip-policy}"; shift ;;
    --work-base) WORK_BASE="${2:?Missing value for --work-base}"; shift ;;
    --ips-file) IPS_FILE="${2:?Missing value for --ips-file}"; shift ;;
    --clients-file) CLIENTS_FILE="${2:?Missing value for --clients-file}"; shift ;;
    --ca-file) CA_CERT_PATH="${2:?Missing value for --ca-file}"; shift ;;
    --tls-cert) TLS_CERT_PATH="${2:?Missing value for --tls-cert}"; shift ;;
    --tls-key) TLS_KEY_PATH="${2:?Missing value for --tls-key}"; shift ;;
    --cert-csv) CERT_CSV="${2:?Missing value for --cert-csv}"; shift ;;
    --cert-manager) CERT_MANAGER="${2:?Missing value for --cert-manager}"; shift ;;
    --allowed-ip) ALLOWED_IPS+="${2:?Missing value for --allowed-ip}"$'\n'; shift ;;
    --allowed-cn) ALLOWED_CNS+="${2:?Missing value for --allowed-cn}"$'\n'; shift ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
  shift
done

# ------------------------------------------------------------------------------
# 🌱 Load .env first, then resolve: CLI > .env > default
# ------------------------------------------------------------------------------
header "Loading Configuration"

if [[ -f "$ENV_FILE" ]]; then
  log "Loading values from ${ENV_FILE}"
  set -a
  # shellcheck disable=SC1090
  source <(grep -v -E '^[[:space:]]*(#|$)' "$ENV_FILE")
  set +a
  success "Loaded .env"
else
  warn "No .env file found at ${ENV_FILE}; falling back to defaults"
fi

# ------------------------------------------------------------------------------
# Resolve effective configuration
# ------------------------------------------------------------------------------
REPO_FQDN="${REPO_FQDN:-${REPO_FQDN:-$DEFAULT_REPO_FQDN}}"

# Prefer API-specific names first, then RPMREPO-scoped, then legacy shared vars
API_MTLS_CA_NAME_EFFECTIVE="${API_MTLS_CA_NAME_EFFECTIVE:-${API_MTLS_CA_NAME:-${RPMREPO_MTLS_CA_NAME:-${CA_NAME:-$DEFAULT_API_MTLS_CA_NAME}}}}"
API_MTLS_CLIENT_NAME_EFFECTIVE="${API_MTLS_CLIENT_NAME_EFFECTIVE:-${API_MTLS_CLIENT_NAME:-${RPMREPO_MTLS_CLIENT_NAME:-${CLIENT_NAME:-$DEFAULT_API_MTLS_CLIENT_NAME}}}}"

# If legacy CA_NAME/CLIENT_NAME are the only things present, use them.
# If nothing is present at all, use explicit API defaults instead of repo defaults.
if [[ -z "${API_MTLS_CA_NAME_EFFECTIVE}" ]]; then
  API_MTLS_CA_NAME_EFFECTIVE="$DEFAULT_API_MTLS_CA_NAME"
fi

if [[ -z "${API_MTLS_CLIENT_NAME_EFFECTIVE}" ]]; then
  API_MTLS_CLIENT_NAME_EFFECTIVE="$DEFAULT_API_MTLS_CLIENT_NAME"
fi

API_PORT="${API_PORT:-${API_PORT:-$DEFAULT_API_PORT}}"
LISTEN_ADDR="${LISTEN_ADDR:-:${API_PORT}}"
IP_POLICY="${IP_POLICY:-$DEFAULT_IP_POLICY}"
CERT_MANAGER="${CERT_MANAGER:-${API_CERT_MANAGER:-$DEFAULT_CERT_MANAGER}}"
API_BIN="${API_BIN:-$DEFAULT_API_BIN}"

WORK_BASE="${WORK_BASE:-$DEFAULT_WORK_BASE}"
PKI_DIR="${PKI_DIR:-${WORK_BASE}/pki_mtls_material}"

# New names first, then old names for backward compatibility
CLIENTS_FILE="${CLIENTS_FILE:-${API_MTLS_ALLOWED_CNS_FILE:-${API_MTLS_CN_CLIENTS_FILE:-$DEFAULT_CLIENTS_FILE}}}"
IPS_FILE="${IPS_FILE:-${API_MTLS_IPS_FILE:-$DEFAULT_IPS_FILE}}"
CA_CERT_PATH="${CA_CERT_PATH:-${API_MTLS_CA_FILE:-$DEFAULT_CA_FILE}}"
TLS_CERT_PATH="${TLS_CERT_PATH:-${API_TLS_CERT_FILE:-./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/fullchain.pem}}"
TLS_KEY_PATH="${TLS_KEY_PATH:-${API_TLS_KEY_FILE:-./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/privkey.pem}}"
CERT_CSV="${CERT_CSV:-${API_CERT_CSV_FILE:-${API_CERT_CSV:-$DEFAULT_CERT_CSV}}}"

[[ -n "$REPO_FQDN" ]] || die "REPO_FQDN is required"
[[ "$IP_POLICY" =~ ^(allow|deny)$ ]] || die "ip-policy must be allow or deny"

info "FQDN              : $REPO_FQDN"
info "API mTLS CA Name  : $API_MTLS_CA_NAME_EFFECTIVE"
info "API mTLS Client CN: $API_MTLS_CLIENT_NAME_EFFECTIVE"
info "API Port          : $API_PORT"
info "Listen Addr       : $LISTEN_ADDR"
info "API Binary        : $API_BIN"
info "TLS Cert          : $TLS_CERT_PATH"
info "TLS Key           : $TLS_KEY_PATH"
info "mTLS CA File      : $CA_CERT_PATH"
info "Client CN File    : $CLIENTS_FILE"
info "IP ACL File       : $IPS_FILE"
info "Cert CSV          : $CERT_CSV"
info "Cert Manager      : $CERT_MANAGER"

# ------------------------------------------------------------------------------
# ✅ Pre-flight
# ------------------------------------------------------------------------------
header "Pre-flight Checks"

need_cmd openssl
need_cmd grep
need_cmd mkdir
need_cmd dirname
success "Base dependencies look good"

# ------------------------------------------------------------------------------
# 📁 Prepare working directories
# ------------------------------------------------------------------------------
header "Preparing Workspace"

run_cmd "mkdir -p '$WORK_BASE' '$PKI_DIR'"
ensure_parent_dir "$IPS_FILE"
ensure_parent_dir "$CLIENTS_FILE"
ensure_parent_dir "$CA_CERT_PATH"
ensure_parent_dir "$CERT_CSV"

success "Workspace ready"

# ------------------------------------------------------------------------------
# 🔐 Generated internal PKI material paths
# ------------------------------------------------------------------------------
GEN_CA_KEY="${PKI_DIR}/ca.key"
GEN_CA_CERT="${PKI_DIR}/ca.crt"

GEN_SERVER_KEY="${PKI_DIR}/server.key"
GEN_SERVER_CSR="${PKI_DIR}/server.csr"
GEN_SERVER_CERT="${PKI_DIR}/server.crt"
GEN_SERVER_EXT="${PKI_DIR}/server-ext.cnf"

GEN_CLIENT_KEY="${PKI_DIR}/${API_MTLS_CLIENT_NAME_EFFECTIVE}.key"
GEN_CLIENT_CSR="${PKI_DIR}/${API_MTLS_CLIENT_NAME_EFFECTIVE}.csr"
GEN_CLIENT_CERT="${PKI_DIR}/${API_MTLS_CLIENT_NAME_EFFECTIVE}.crt"

# ------------------------------------------------------------------------------
# 🛡️ Generate API CA only if CA file path is missing
# ------------------------------------------------------------------------------
header "API CA Material"

if file_missing_or_empty "$CA_CERT_PATH"; then
  warn "CA file missing. Generating API mTLS CA at ${GEN_CA_CERT}"

  if [[ -f "$GEN_CA_KEY" && -f "$GEN_CA_CERT" && "$FORCE" != "true" ]]; then
    info "Reusing existing generated API CA from ${PKI_DIR}"
  else
    run_cmd "openssl genrsa -out '$GEN_CA_KEY' 4096"
    run_cmd "openssl req -x509 -new -nodes \
      -key '$GEN_CA_KEY' \
      -sha256 \
      -days '$DEFAULT_DAYS_VALID_CA' \
      -out '$GEN_CA_CERT' \
      -subj '/C=US/ST=Infrastructure/O=Internal API PKI/CN=${API_MTLS_CA_NAME_EFFECTIVE}'"
    success "Generated API mTLS CA"
  fi

  if [[ "$CA_CERT_PATH" != "$GEN_CA_CERT" ]]; then
    run_cmd "cp -f '$GEN_CA_CERT' '$CA_CERT_PATH'"
    success "Copied API CA cert to ${CA_CERT_PATH}"
  fi
else
  success "CA file already exists: ${CA_CERT_PATH}"
fi

# ------------------------------------------------------------------------------
# 🌐 TLS cert/key for API
# Prefer configured files from .env.
# Only generate fallback server certs if missing.
# ------------------------------------------------------------------------------
header "API TLS Material"

if file_missing_or_empty "$TLS_CERT_PATH" || file_missing_or_empty "$TLS_KEY_PATH"; then
  warn "Configured TLS cert/key missing. Generating fallback API server cert in ${PKI_DIR}"

  [[ -f "$CA_CERT_PATH" ]] || die "Cannot generate fallback server cert because CA file is missing: $CA_CERT_PATH"
  [[ -f "$GEN_CA_KEY" ]] || die "Cannot sign fallback server cert because CA key is missing: $GEN_CA_KEY"

  if [[ ! -f "$GEN_SERVER_EXT" || "$FORCE" == "true" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      printf "%b🧪 DRY-RUN%b would write extfile: %s\n" "${YELLOW}" "${NC}" "$GEN_SERVER_EXT"
    else
      cat > "$GEN_SERVER_EXT" <<EOF
subjectAltName=DNS:${REPO_FQDN}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
basicConstraints=CA:FALSE
EOF
    fi
  fi

  run_cmd "openssl genrsa -out '$GEN_SERVER_KEY' 2048"
  run_cmd "openssl req -new \
    -key '$GEN_SERVER_KEY' \
    -out '$GEN_SERVER_CSR' \
    -subj '/C=US/ST=Infrastructure/O=Internal API/CN=${REPO_FQDN}'"
  run_cmd "openssl x509 -req \
    -in '$GEN_SERVER_CSR' \
    -CA '$CA_CERT_PATH' \
    -CAkey '$GEN_CA_KEY' \
    -CAcreateserial \
    -out '$GEN_SERVER_CERT' \
    -days '$DEFAULT_DAYS_VALID_SERVER' \
    -sha256 \
    -extfile '$GEN_SERVER_EXT'"

  TLS_CERT_PATH="$GEN_SERVER_CERT"
  TLS_KEY_PATH="$GEN_SERVER_KEY"
  success "Using generated fallback TLS files for API startup"
else
  success "Using configured TLS files from existing path(s)"
fi

# ------------------------------------------------------------------------------
# 👤 Generate API client identity if useful for bootstrap/validation
# ------------------------------------------------------------------------------
header "API Client Identity"

if [[ -f "$GEN_CLIENT_CERT" && -f "$GEN_CLIENT_KEY" && "$FORCE" != "true" ]]; then
  info "API client identity already exists in ${PKI_DIR}"
else
  if [[ -f "$GEN_CA_KEY" && -f "$CA_CERT_PATH" ]]; then
    run_cmd "openssl genrsa -out '$GEN_CLIENT_KEY' 2048"
    run_cmd "openssl req -new \
      -key '$GEN_CLIENT_KEY' \
      -out '$GEN_CLIENT_CSR' \
      -subj '/CN=${API_MTLS_CLIENT_NAME_EFFECTIVE}'"
    run_cmd "openssl x509 -req \
      -in '$GEN_CLIENT_CSR' \
      -CA '$CA_CERT_PATH' \
      -CAkey '$GEN_CA_KEY' \
      -CAcreateserial \
      -out '$GEN_CLIENT_CERT' \
      -days '$DEFAULT_DAYS_VALID_CLIENT' \
      -sha256 \
      -extfile <(printf 'extendedKeyUsage=clientAuth\nkeyUsage=digitalSignature,keyEncipherment\nbasicConstraints=CA:FALSE\n')"
    success "Generated API client identity: ${API_MTLS_CLIENT_NAME_EFFECTIVE}"
  else
    warn "Skipping API client identity generation because CA key is not locally available"
  fi
fi

# ------------------------------------------------------------------------------
# 📄 Prepare allowed CN file
# ------------------------------------------------------------------------------
header "Allowed API mTLS Client CNs"

if file_missing_or_empty "$CLIENTS_FILE"; then
  write_file "$CLIENTS_FILE" "${API_MTLS_CLIENT_NAME_EFFECTIVE}
"
  success "Seeded allowed client CN file"
else
  info "Client CN allowlist already exists: $CLIENTS_FILE"
fi

append_unique_line "$CLIENTS_FILE" "$API_MTLS_CLIENT_NAME_EFFECTIVE"

if [[ -n "${ALLOWED_CNS//$'\n'/}" ]]; then
  while IFS= read -r cn; do
    [[ -n "${cn// }" ]] || continue
    append_unique_line "$CLIENTS_FILE" "$cn"
  done <<< "$ALLOWED_CNS"
  success "Merged additional allowed CNs"
fi

# ------------------------------------------------------------------------------
# 📄 Prepare IP ACL file
# ------------------------------------------------------------------------------
header "API IP Access Control"

if file_missing_or_empty "$IPS_FILE"; then
  write_file "$IPS_FILE" "127.0.0.1
::1
"
  warn "Seeded minimal local-only IP ACL because file was missing"
else
  info "IP ACL file already exists: $IPS_FILE"
fi

if [[ -n "${ALLOWED_IPS//$'\n'/}" ]]; then
  while IFS= read -r ip; do
    [[ -n "${ip// }" ]] || continue
    append_unique_line "$IPS_FILE" "$ip"
  done <<< "$ALLOWED_IPS"
  success "Merged additional IP/CIDR entries"
fi

# ------------------------------------------------------------------------------
# 📄 Prepare certificates.csv
# ------------------------------------------------------------------------------
header "Certificate Inventory"

if file_missing_or_empty "$CERT_CSV"; then
  write_file "$CERT_CSV" "fqdn,dns_provider,email
${REPO_FQDN},cloudflare,admin@example.com
"
  warn "Created placeholder certificates.csv because file was missing"
else
  success "Certificate CSV already exists: $CERT_CSV"
fi

# ------------------------------------------------------------------------------
# ✅ Validate API required files
# ------------------------------------------------------------------------------
header "Validating API Inputs"

required_files=(
  "$TLS_CERT_PATH"
  "$TLS_KEY_PATH"
  "$IPS_FILE"
  "$CA_CERT_PATH"
  "$CLIENTS_FILE"
  "$CERT_CSV"
)

for file in "${required_files[@]}"; do
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Would validate file: $file"
  else
    [[ -f "$file" ]] || die "Required file missing: $file"
    [[ -s "$file" ]] || die "Required file is empty: $file"
    success "Ready: $file"
  fi
done

# ------------------------------------------------------------------------------
# 🚀 Launch API or print command
# ------------------------------------------------------------------------------
header "API Command"

API_CMD=(
  "$API_BIN"
  -listen "$LISTEN_ADDR"
  -tls-cert "$TLS_CERT_PATH"
  -tls-key "$TLS_KEY_PATH"
  -ip-list "$IPS_FILE"
  -ip-policy "$IP_POLICY"
  -mtls-client-ca "$CA_CERT_PATH"
  -mtls-allowed-cns "$CLIENTS_FILE"
  -cert-csv "$CERT_CSV"
  -cert-manager "$CERT_MANAGER"
)

printf "Prepared command:\n  "
printf '%q ' "${API_CMD[@]}"
printf "\n"

if [[ "$RUN_API" != "true" ]]; then
  info "Bootstrap complete. API launch not requested."
  exit 0
fi

[[ -x "$API_BIN" || -f "$API_BIN" ]] || die "API binary not found: $API_BIN"

if [[ "$DRY_RUN" == "true" ]]; then
  warn "Dry-run enabled. API will not be started."
  exit 0
fi

success "Starting cert-manager-api"
exec "${API_CMD[@]}"