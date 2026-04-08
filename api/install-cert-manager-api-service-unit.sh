#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# cert-manager-api systemd unit installer
# - Loads and validates project .env
# - Expands nested env vars like ${REPO_FQDN}
# - Resolves relative paths from project root
# - Generates a concrete systemd service unit
# - Installs, reloads, enables, and optionally restarts the service
# ==============================================================================

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

readonly SERVICE_NAME="cert-manager-api"
readonly SERVICE_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
readonly ENV_FILE="${PROJECT_ROOT}/.env"
readonly API_BIN="${PROJECT_ROOT}/api/cert-manager-api"

DRY_RUN=false
PRINT_UNIT=false
INSTALL_ONLY=false
ENABLE_SERVICE=true
RESTART_SERVICE=false
REMOVE=false

log() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

err() {
  printf '[ERROR] %s\n' "$*" >&2
}

die() {
  err "$*"
  exit 1
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --dry-run       Validate configuration and render the unit, but do not write it
                  or modify systemd.
  --print-unit    Print the rendered systemd unit to stdout.
  --install-only  Install the unit, reload systemd, and optionally enable it,
                  but do not restart the service.
  --force         Install the unit, enable it, and restart the service.
  --no-enable     Do not enable the service at boot.
  --remove        Stop, disable, and remove the systemd unit if it exists.
  --help, -h      Show this help.

Examples:
  sudo ${SCRIPT_NAME}
  sudo ${SCRIPT_NAME} --dry-run --print-unit
  sudo ${SCRIPT_NAME} --install-only
  sudo ${SCRIPT_NAME} --no-enable --print-unit
EOF
}

parse_args() {
  if [[ $# -eq 0 ]]; then
    printf '[ERROR] Empty argument detected. Please check your input.\n' >&2
    usage
    exit 1
  fi
  while [[ $# -gt 0 ]]; do
  if [[ -z "$1" ]]; then
      printf '[ERROR] Empty argument detected. Please check your input.\n' >&2
      usage
      exit 1
  fi
    case "$1" in
      --dry-run)
        DRY_RUN=true
        ;;
      --print-unit)
        PRINT_UNIT=true
        ;;
      --install-only)
        INSTALL_ONLY=true
        ;;
      --force)
        ENABLE_SERVICE=true
        RESTART_SERVICE=true
        ;;
      --no-enable)
        ENABLE_SERVICE=false
        ;;
      --remove)
        REMOVE=true
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this script as root."
}

remove() {
if [[ "${REMOVE}" == true ]]; then
  printf '[WARN] Remove mode enabled. This will stop, disable, and remove the %s service if it exists.\n' "${SERVICE_NAME}" >&2
  require_root
  require_cmd systemctl

  if [[ ! -f "${SERVICE_UNIT_PATH}" ]]; then
    warn "Service unit does not exist: ${SERVICE_UNIT_PATH}"
    log "Nothing to remove."
    exit 0
  fi

  log "Stopping service (if running)..."
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true

  log "Disabling service (if enabled)..."
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

  log "Removing unit file..."
  rm -f "${SERVICE_UNIT_PATH}"

  log "Reloading systemd daemon..."
  systemctl daemon-reload

  log "Resetting failed state (if any)..."
  systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true

  log "Service ${SERVICE_NAME} has been removed successfully."
  exit 0
fi
}

resolve_path() {
  local raw="${1:-}"
  [[ -n "${raw}" ]] || die "resolve_path received an empty value"

  if [[ "${raw}" = /* ]]; then
    printf '%s\n' "${raw}"
  else
    printf '%s\n' "${PROJECT_ROOT}/${raw#./}"
  fi
}

load_env() {
  [[ -f "${ENV_FILE}" ]] || die ".env file not found: ${ENV_FILE}"

  log "Loading environment from ${ENV_FILE}"

  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

require_env() {
  local var_name="$1"
  [[ -n "${!var_name:-}" ]] || die "Required environment variable is missing or empty: ${var_name}"
}

check_file_readable() {
  local path="$1"
  [[ -e "${path}" ]] || die "Required path does not exist: ${path}"
  [[ -r "${path}" ]] || die "Required path is not readable: ${path}"
}

check_binary_executable() {
  [[ -x "${API_BIN}" ]] || die "API binary is missing or not executable: ${API_BIN}"
}

shell_escape() {
  printf '%q' "$1"
}

render_unit() {
  local listen_addr="$1"
  local tls_cert="$2"
  local tls_key="$3"
  local mtls_ca="$4"
  local allowed_cns="$5"
  local ip_list="$6"
  local cert_csv="$7"
  local cert_manager="$8"
  local ip_policy="$9"

  cat <<EOF
[Unit]
Description=Cert Manager API (mTLS + Certbot Automation)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=$(shell_escape "${PROJECT_ROOT}")

ExecStartPre=/usr/bin/test -x $(shell_escape "${API_BIN}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${tls_cert}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${tls_key}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${mtls_ca}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${allowed_cns}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${ip_list}")
ExecStartPre=/usr/bin/test -r $(shell_escape "${cert_csv}")

ExecStart=$(shell_escape "${API_BIN}") \\
  -listen $(shell_escape "${listen_addr}") \\
  -tls-cert $(shell_escape "${tls_cert}") \\
  -tls-key $(shell_escape "${tls_key}") \\
  -mtls-client-ca $(shell_escape "${mtls_ca}") \\
  -mtls-allowed-cns $(shell_escape "${allowed_cns}") \\
  -ip-list $(shell_escape "${ip_list}") \\
  -ip-policy $(shell_escape "${ip_policy}") \\
  -cert-csv $(shell_escape "${cert_csv}") \\
  -cert-manager $(shell_escape "${cert_manager}")

Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Root is intentional here because TLS private keys and mTLS material
# are often root-owned in Let's Encrypt / PKI layouts.
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$(shell_escape "${PROJECT_ROOT}")

TimeoutStartSec=30
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
}

main() {
  parse_args "$@"

  if [[ "${DRY_RUN}" == false ]]; then
    require_root
  fi

  if [[ "${REMOVE}" == true ]]; then
    require_root
    remove
    exit 0
  fi

  require_cmd tee
  require_cmd readlink

  if [[ "${DRY_RUN}" == false ]]; then
    require_cmd systemctl
  fi

  check_binary_executable
  load_env

  require_env REPO_FQDN
  require_env API_PORT
  require_env API_CERT_MANAGER
  require_env API_CERT_CSV_FILE
  require_env API_TLS_CERT_FILE
  require_env API_TLS_KEY_FILE
  require_env API_MTLS_CA_FILE
  require_env API_MTLS_ALLOWED_CNS_FILE
  require_env API_MTLS_IPS_FILE
  require_env API_IP_POLICY

  case "${API_IP_POLICY}" in
    allow|deny) ;;
    *) die "API_IP_POLICY must be 'allow' or 'deny', got: ${API_IP_POLICY}" ;;
  esac

  [[ "${API_PORT}" =~ ^[0-9]+$ ]] || die "API_PORT must be numeric, got: ${API_PORT}"
  (( API_PORT >= 1 && API_PORT <= 65535 )) || die "API_PORT must be between 1 and 65535, got: ${API_PORT}"

  local listen_addr=":${API_PORT}"

  local tls_cert
  local tls_key
  local mtls_ca
  local allowed_cns
  local ip_list
  local cert_csv

  tls_cert="$(resolve_path "${API_TLS_CERT_FILE}")"
  tls_key="$(resolve_path "${API_TLS_KEY_FILE}")"
  mtls_ca="$(resolve_path "${API_MTLS_CA_FILE}")"
  allowed_cns="$(resolve_path "${API_MTLS_ALLOWED_CNS_FILE}")"
  ip_list="$(resolve_path "${API_MTLS_IPS_FILE}")"
  cert_csv="$(resolve_path "${API_CERT_CSV_FILE}")"

  log "Resolved configuration:"
  printf '  %-22s %s\n' "Project root:" "${PROJECT_ROOT}"
  printf '  %-22s %s\n' "API binary:" "${API_BIN}"
  printf '  %-22s %s\n' "Repo FQDN:" "${REPO_FQDN}"
  printf '  %-22s %s\n' "Listen:" "${listen_addr}"
  printf '  %-22s %s\n' "TLS cert:" "${tls_cert}"
  printf '  %-22s %s\n' "TLS key:" "${tls_key}"
  printf '  %-22s %s\n' "mTLS CA:" "${mtls_ca}"
  printf '  %-22s %s\n' "Allowed CNs:" "${allowed_cns}"
  printf '  %-22s %s\n' "IP list:" "${ip_list}"
  printf '  %-22s %s\n' "IP policy:" "${API_IP_POLICY}"
  printf '  %-22s %s\n' "Cert CSV:" "${cert_csv}"
  printf '  %-22s %s\n' "Cert manager:" "${API_CERT_MANAGER}"

  check_file_readable "${tls_cert}"
  check_file_readable "${tls_key}"
  check_file_readable "${mtls_ca}"
  check_file_readable "${allowed_cns}"
  check_file_readable "${ip_list}"
  check_file_readable "${cert_csv}"

  if readlink -f "${tls_cert}" >/dev/null 2>&1; then
    local tls_cert_real
    tls_cert_real="$(readlink -f "${tls_cert}")"
    log "Resolved TLS certificate target: ${tls_cert_real}"
    check_file_readable "${tls_cert_real}"
  fi

  if readlink -f "${tls_key}" >/dev/null 2>&1; then
    local tls_key_real
    tls_key_real="$(readlink -f "${tls_key}")"
    log "Resolved TLS private key target: ${tls_key_real}"
    check_file_readable "${tls_key_real}"
  fi

  local rendered_unit
  rendered_unit="$(
    render_unit \
      "${listen_addr}" \
      "${tls_cert}" \
      "${tls_key}" \
      "${mtls_ca}" \
      "${allowed_cns}" \
      "${ip_list}" \
      "${cert_csv}" \
      "${API_CERT_MANAGER}" \
      "${API_IP_POLICY}"
  )"

  if [[ "${PRINT_UNIT}" == true ]]; then
    printf '%s\n' "${rendered_unit}"
  fi

  if [[ "${DRY_RUN}" == true ]]; then
    log "Dry run complete. No files were written and systemd was not modified."
    exit 0
  fi

  log "Writing systemd unit to ${SERVICE_UNIT_PATH}"
  printf '%s\n' "${rendered_unit}" | tee "${SERVICE_UNIT_PATH}" >/dev/null

  log "Reloading systemd"
  systemctl daemon-reload

  if [[ "${ENABLE_SERVICE}" == true ]]; then
    log "Enabling ${SERVICE_NAME}"
    systemctl enable "${SERVICE_NAME}" >/dev/null
  else
    warn "Skipping enable step because --no-enable was requested."
  fi

  if [[ "${INSTALL_ONLY}" == true ]]; then
    warn "Skipping restart because --install-only was requested."
    log "Install complete."
    exit 0
  fi

  if [[ "${RESTART_SERVICE}" == false ]]; then
    warn "Skipping restart because --force was not requested."
    log "Install complete."
    exit 0
  else
    log "Restarting ${SERVICE_NAME}"
    systemctl restart "${SERVICE_NAME}"
  fi

  log "Final service status"
  systemctl --no-pager --full status "${SERVICE_NAME}" || true

  log "Done"
}

main "$@"