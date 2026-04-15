#!/usr/bin/env bash
################################################################################
# 🔐 cert-manager-api-client-gpg-wrapper.sh
# ------------------------------------------------------------------------------
# Purpose:
#   Secure wrapper for cert-manager-api-client.sh that decrypts encrypted mTLS
#   assets into a temporary runtime directory, executes the API client using
#   those decrypted files, then re-encrypts and removes plaintext material.
#
# Workflow:
#   1. Validate GPG prerequisites, source files, and client script
#   2. Decrypt ASCII-armored .asc files into a secure temporary work directory
#   3. Export runtime overrides so the API client resolves decrypted file paths
#   4. Execute cert-manager-api-client.sh with forwarded client arguments
#   5. Re-encrypt the plaintext assets back to .asc and securely clean up
#
# Trust model:
#   - This wrapper manages client-side mTLS material only
#   - Server TLS validation remains the responsibility of the client script
#   - For public-TLS API servers, the client script should use the system trust
#     store by default
#   - For internal/private-TLS API servers, the client script may use
#     API_SERVER_CA_FILE if defined in .env
#
# Encrypted source file model:
#   <SRC_DIR>/ca.crt.asc
#   <SRC_DIR>/<CLIENT_NAME>.crt.asc
#   <SRC_DIR>/<CLIENT_NAME>.key.asc
#
# Temporary decrypted runtime file model:
#   <WORKDIR>/ca.crt
#   <WORKDIR>/<CLIENT_NAME>.crt
#   <WORKDIR>/<CLIENT_NAME>.key
#
# GPG passphrase handling:
#   Preferred order:
#     1. --gpg-passphrase-file PATH
#     2. GPG_PASSPHRASE_FILE environment variable
#     3. plain GPG behavior (agent/pinentry/manual resolution)
#
# Compatibility:
#   - Supports older GnuPG 2.0.x environments by avoiding --pinentry-mode when
#     unsupported
#   - Uses loopback pinentry only on GnuPG versions that support it
#
# Notes:
#   - Wrapper options must come before `--`
#   - Client command and options must come after `--`
#   - The wrapper exports API_MTLS_CA_FILE and API_MTLS_CLIENT_NAME so the
#     client script resolves cert/key paths from the temp workdir
################################################################################

set -Eeuo pipefail

###############################################################################
# Defaults
###############################################################################
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GPG_HOMEDIR="${HOME}/.gnupg"
GPG_RECIPIENT="user@example.com"
GPG_PASSPHRASE_FILE="${GPG_PASSPHRASE_FILE:-}"

SRC_DIR="./secrets/api-secrets/pki_mtls_material"
CLIENT_SCRIPT="./cert-manager-api-client.sh"
CLIENT_NAME="cert-manager-automation-client"

DRY_RUN=false
KEEP_WORKDIR=false

CA_FILENAME="ca.crt"
CRT_FILENAME=""
KEY_FILENAME=""

###############################################################################
# Runtime state
###############################################################################
WORKDIR=""
DECRYPTION_DONE=false
CLIENT_ARGS=()

###############################################################################
# Output helpers
###############################################################################
info()  { printf 'ℹ️  %s\n' "$*"; }
ok()    { printf '✅ %s\n' "$*"; }
warn()  { printf '⚠️  %s\n' "$*" >&2; }
error() { printf '❌ %s\n' "$*" >&2; }
die()   { error "$*"; exit 1; }

usage() {
  cat <<EOF
Usage:
  ${SCRIPT_NAME} [wrapper-options] -- <client-command> [client-options]

Wrapper options:
  -d, --gpg-homedir DIR         GPG homedir to use
                                Default: ${HOME}/.gnupg

  -r, --recipient UID           Recipient UID/email for ASCII-armored
                                re-encryption
                                Default: user@example.com

  -p, --gpg-passphrase-file PATH
                                Optional GPG passphrase file for unattended use
                                Preferred over env fallback

  -s, --src-dir DIR             Directory containing encrypted .asc files
                                Default: ./secrets/api-secrets/pki_mtls_material

  -c, --client-script PATH      Path to cert-manager-api-client.sh
                                Default: ./cert-manager-api-client.sh

  -n, --client-name NAME        mTLS client name / certificate CN basename
                                Default: cert-manager-automation-client

      --ca-file NAME            CA filename basename
                                Default: ca.crt

      --crt-file NAME           Client certificate filename basename
                                Default: <client-name>.crt

      --key-file NAME           Client private key filename basename
                                Default: <client-name>.key

      --keep-workdir            Keep temp workdir after run (debugging only)
      --dry-run                 Show actions without changing files

  -h, --help                    Show this help message

Fallback logic:
  If --gpg-passphrase-file is not provided, the wrapper checks:
    GPG_PASSPHRASE_FILE

  If neither is set, GPG is invoked without loopback/passphrase-file options and
  will rely on its normal agent/pinentry behavior.

Client args:
  Everything after '--' is forwarded to the client script exactly as-is.

Examples:
  ${SCRIPT_NAME} -- --help

  ${SCRIPT_NAME} \\
    --gpg-homedir /opt/rundeck/.gnupg \\
    --gpg-passphrase-file /opt/rundeck/.gnupg/passphrase.txt \\
    --recipient CloudPlatformServices@alvaria.com \\
    --src-dir ./secrets/api-secrets/pki_mtls_material \\
    --client-script ./cert-manager-api-client.sh \\
    --client-name cert-manager-automation-client \\
    -- health

  ${SCRIPT_NAME} \\
    --src-dir ./secrets/api-secrets/pki_mtls_material \\
    --client-script ./cert-manager-api-client.sh \\
    --client-name cert-manager-automation-client \\
    -- list
EOF
}

###############################################################################
# Helpers
###############################################################################
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || die "Required file not found: $path"
}

require_dir() {
  local path="$1"
  [[ -d "$path" ]] || die "Required directory not found: $path"
}

run_cmd() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '🧪 DRY-RUN:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

secure_delete_file() {
  local path="$1"

  [[ -e "$path" ]] || return 0

  if [[ "$DRY_RUN" == "true" ]]; then
    info "Would securely remove: $path"
    return 0
  fi

  if command -v shred >/dev/null 2>&1; then
    shred -u "$path" 2>/dev/null || rm -f "$path"
  else
    rm -f "$path"
  fi
}

print_summary() {
  cat <<EOF
────────────────────────────────────────────────────────────
🔐 GPG Wrapper Configuration
────────────────────────────────────────────────────────────
Script              : $SCRIPT_NAME
GPG homedir         : $GPG_HOMEDIR
Recipient           : $GPG_RECIPIENT
Passphrase file     : ${GPG_PASSPHRASE_FILE:-"(not set; using normal GPG behavior)"}
Source dir          : $SRC_DIR
Client script       : $CLIENT_SCRIPT
Client name         : $CLIENT_NAME
CA file             : $CA_FILENAME.asc
CRT file            : $CRT_FILENAME.asc
KEY file            : $KEY_FILENAME.asc
Dry-run             : $DRY_RUN
Keep workdir        : $KEEP_WORKDIR
Work dir            : ${WORKDIR:-"(not created yet)"}
Client args         : ${CLIENT_ARGS[*]:-"(none)"}
────────────────────────────────────────────────────────────
EOF
}

gpg_supports_pinentry_loopback() {
  local version
  version="$(gpg --version 2>/dev/null | head -n1 || true)"
  printf '%s\n' "$version" | grep -Eq ' 2\.[1-9]| 3\.'
}

gpg_base_args() {
  printf '%s\0' --batch --yes --homedir "$GPG_HOMEDIR"
}

gpg_sensitive_args() {
  if [[ -n "${GPG_PASSPHRASE_FILE:-}" ]]; then
    if gpg_supports_pinentry_loopback; then
      printf '%s\0' \
        --pinentry-mode loopback \
        --passphrase-file "$GPG_PASSPHRASE_FILE"
    else
      printf '%s\0' \
        --passphrase-file "$GPG_PASSPHRASE_FILE"
    fi
  fi
}

encrypt_one() {
  local plaintext_path="$1"
  local encrypted_path="$2"

  info "Encrypting ${plaintext_path} -> ${encrypted_path}"

  local -a args=()
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(gpg_base_args)
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(gpg_sensitive_args)

  args+=(
    --armor
    --output "$encrypted_path"
    --encrypt
    --recipient "$GPG_RECIPIENT"
    "$plaintext_path"
  )

  run_cmd gpg "${args[@]}"
}

decrypt_one() {
  local encrypted_path="$1"
  local plaintext_path="$2"

  info "Decrypting ${encrypted_path} -> ${plaintext_path}"

  local -a args=()
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(gpg_base_args)
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(gpg_sensitive_args)

  args+=(
    --output "$plaintext_path"
    --decrypt
    "$encrypted_path"
  )

  run_cmd gpg "${args[@]}"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "Would set secure permissions on: ${plaintext_path}"
  else
    chmod 600 "$plaintext_path" 2>/dev/null || true
  fi
}

cleanup() {
  local exit_code=$?

  if [[ "$DECRYPTION_DONE" == "true" && -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    info "Re-encrypting decrypted material before exit..."

    local plain_ca="${WORKDIR}/${CA_FILENAME}"
    local plain_crt="${WORKDIR}/${CRT_FILENAME}"
    local plain_key="${WORKDIR}/${KEY_FILENAME}"

    local enc_ca="${SRC_DIR}/${CA_FILENAME}.asc"
    local enc_crt="${SRC_DIR}/${CRT_FILENAME}.asc"
    local enc_key="${SRC_DIR}/${KEY_FILENAME}.asc"

    if [[ -f "$plain_ca" ]]; then
      encrypt_one "$plain_ca" "$enc_ca"
      secure_delete_file "$plain_ca"
    else
      warn "Missing plaintext CA during cleanup: ${plain_ca}"
    fi

    if [[ -f "$plain_crt" ]]; then
      encrypt_one "$plain_crt" "$enc_crt"
      secure_delete_file "$plain_crt"
    else
      warn "Missing plaintext client certificate during cleanup: ${plain_crt}"
    fi

    if [[ -f "$plain_key" ]]; then
      encrypt_one "$plain_key" "$enc_key"
      secure_delete_file "$plain_key"
    else
      warn "Missing plaintext client key during cleanup: ${plain_key}"
    fi
  else
    info "Skipping re-encryption because decryption did not complete."
  fi

  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    if [[ "$KEEP_WORKDIR" == "true" ]]; then
      warn "Keeping temporary workdir for debugging: $WORKDIR"
    elif [[ "$DRY_RUN" == "true" ]]; then
      info "Would remove temporary work directory: $WORKDIR"
    else
      rm -rf "$WORKDIR"
    fi
  fi

  exit "$exit_code"
}

###############################################################################
# Optional env loading
###############################################################################
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
  info "Loading environment from ${SCRIPT_DIR}/.env"
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/.env"
fi

###############################################################################
# Parse wrapper args and capture client args after --
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      CLIENT_ARGS=("$@")
      break
      ;;
    -d|--gpg-homedir)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      GPG_HOMEDIR="$2"
      shift 2
      ;;
    -r|--recipient)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      GPG_RECIPIENT="$2"
      shift 2
      ;;
    -p|--gpg-passphrase-file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      GPG_PASSPHRASE_FILE="$2"
      shift 2
      ;;
    -s|--src-dir)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      SRC_DIR="$2"
      shift 2
      ;;
    -c|--client-script)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CLIENT_SCRIPT="$2"
      shift 2
      ;;
    -n|--client-name)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CLIENT_NAME="$2"
      shift 2
      ;;
    --ca-file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CA_FILENAME="$2"
      shift 2
      ;;
    --crt-file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CRT_FILENAME="$2"
      shift 2
      ;;
    --key-file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      KEY_FILENAME="$2"
      shift 2
      ;;
    --keep-workdir)
      KEEP_WORKDIR=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown wrapper argument: $1 (use -- before client args)"
      ;;
  esac
done

[[ ${#CLIENT_ARGS[@]} -gt 0 ]] || die "No client command/args supplied. Use -- <client-command> [options]"

###############################################################################
# Derived filenames
###############################################################################
if [[ -z "$CRT_FILENAME" ]]; then
  CRT_FILENAME="${CLIENT_NAME}.crt"
fi

if [[ -z "$KEY_FILENAME" ]]; then
  KEY_FILENAME="${CLIENT_NAME}.key"
fi

###############################################################################
# Validation
###############################################################################
require_cmd gpg
require_cmd mktemp
require_cmd rm
require_cmd chmod
require_cmd dirname

require_dir "$SRC_DIR"
require_dir "$GPG_HOMEDIR"
require_file "$CLIENT_SCRIPT"
[[ -x "$CLIENT_SCRIPT" ]] || die "Client script must be executable: $CLIENT_SCRIPT"
[[ -n "$GPG_RECIPIENT" ]] || die "Recipient must not be empty"
[[ -n "$CLIENT_NAME" ]] || die "Client name must not be empty"

require_file "${SRC_DIR}/${CA_FILENAME}.asc"
require_file "${SRC_DIR}/${CRT_FILENAME}.asc"
require_file "${SRC_DIR}/${KEY_FILENAME}.asc"

if [[ -n "${GPG_PASSPHRASE_FILE:-}" ]]; then
  require_file "$GPG_PASSPHRASE_FILE"
fi

chmod 700 "$SRC_DIR" 2>/dev/null || true
chmod 700 "$GPG_HOMEDIR" 2>/dev/null || true

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true

trap cleanup EXIT

print_summary

###############################################################################
# Decrypt into temp workdir using canonical names expected by client script
###############################################################################
info "Decrypting requested material into temporary work directory..."

decrypt_one "${SRC_DIR}/${CA_FILENAME}.asc"  "${WORKDIR}/${CA_FILENAME}"
decrypt_one "${SRC_DIR}/${CRT_FILENAME}.asc" "${WORKDIR}/${CRT_FILENAME}"
decrypt_one "${SRC_DIR}/${KEY_FILENAME}.asc" "${WORKDIR}/${KEY_FILENAME}"

DECRYPTION_DONE=true
ok "Decryption complete."

###############################################################################
# Export overrides so client script resolves paths from decrypted temp dir
###############################################################################
export MTLS_DIR="$WORKDIR"
export API_MTLS_CA_FILE="${WORKDIR}/${CA_FILENAME}"
export API_MTLS_CLIENT_NAME="$CLIENT_NAME"

info "Exported runtime mTLS overrides:"
printf '   MTLS_DIR=%q\n' "$MTLS_DIR"
printf '   API_MTLS_CA_FILE=%q\n' "$API_MTLS_CA_FILE"
printf '   API_MTLS_CLIENT_NAME=%q\n' "$API_MTLS_CLIENT_NAME"

###############################################################################
# Execute client script with forwarded args
###############################################################################
info "Executing client script: $CLIENT_SCRIPT ${CLIENT_ARGS[*]}"

if [[ "$DRY_RUN" == "true" ]]; then
  printf '🧪 DRY-RUN:'
  printf ' %q' "$CLIENT_SCRIPT"
  printf ' %q' "${CLIENT_ARGS[@]}"
  printf '\n'
else
  "$CLIENT_SCRIPT" "${CLIENT_ARGS[@]}"
fi

ok "Client execution complete."