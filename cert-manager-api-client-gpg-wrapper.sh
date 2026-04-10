#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# 🔐 GPG mTLS Helper Script
#
# This script decrypts and re-encrypts sensitive mTLS material using GPG.
# It assumes a working GPG setup and the presence of the correct keys.
#
# ⚠️ BEFORE USING THIS SCRIPT, YOU MUST:
#
# 1. Create or import a GPG keypair in the keyring you will use
#
#    Example (generate new key in custom keyring):
#    gpg --homedir ./.custom_gnupg_dir --full-generate-key
#
# 2. Verify the key exists
#
#    gpg --homedir ./.custom_gnupg_dir --list-keys
#
# 3. Ensure the recipient UID (email) exists in the keyring
#
#    The recipient must match a UID like:
#    "Name <user@example.com>"
#
#    Example:
#    export GPG_RECIPIENT="user@example.com"
#
# 4. Understand encryption vs decryption
#
#    🔐 Encryption (uses PUBLIC key of recipient)
#    gpg --homedir /home/USER/.gnupg \
#        --encrypt \
#        --recipient "${GPG_RECIPIENT}" \
#        mysecret.txt
#
#    Output:
#      mysecret.txt.gpg   (binary)
#
#    ASCII armored (text format):
#    gpg --homedir /home/USER/.gnupg \
#        --armor \
#        --encrypt \
#        --recipient "${GPG_RECIPIENT}" \
#        mysecret.txt
#
#    Output:
#      mysecret.txt.asc
#
#    🔓 Decryption (uses PRIVATE key from keyring)
#    gpg --homedir /home/USER/.gnupg \
#        --decrypt \
#        mysecret.txt.gpg
#
#    Output:
#      plaintext to STDOUT
#
#    Decrypt to file:
#    gpg --homedir /home/USER/.gnupg \
#        --output mysecret.txt \
#        --decrypt mysecret.txt.gpg
#
# 5. Ensure correct keyring is used
#
#    This script may use:
#      --homedir /home/USER/.gnupg
#    or a custom keyring like:
#      --homedir ./.custom_gnupg_dir
#
#    The required keys MUST exist in that location.
#
# ⚠️ IMPORTANT NOTES:
#
# - GPG does NOT create keys automatically during encryption
# - Encryption will FAIL if the recipient public key is missing
# - Decryption will FAIL if the private key is not present
# - UID (email) is just a lookup label — fingerprint is the real identity
# - File permissions for GPG dirs should be restrictive (chmod 700)
#
# 🧠 Mental Model:
#   Encrypt → you choose recipient (-r)
#   Decrypt → file chooses the key automatically
#
###############################################################################


###############################################################################
# cert-manager-api-client-gpg-wrapper.sh
#
# Purpose:
#   Decrypt mTLS assets into a secure temp directory, run the API client
#   against the decrypted plaintext files, then re-encrypt and clean up.
#
# Example:
#   ./cert-manager-api-client-gpg-wrapper.sh \
#     --gpg-homedir /home/USER/.gnupg \
#     --recipient user@example.com \
#     --src-dir .mtls \
#     --client-script ./cert-manager-api-client.sh \
#     --client-name cert-manager-automation-client \
#     -- health
#
#   ./cert-manager-api-client-gpg-wrapper.sh \
#     --src-dir .mtls \
#     --client-script ./cert-manager-api-client.sh \
#     --client-name cert-manager-automation-client \
#     -- add --fqdn test.example.com --dns cloudflare --email admin@test.com
#
# Notes:
#   - Wrapper options must come before `--`
#   - Client command/options must come after `--`
#   - The wrapper exports API_MTLS_CA_FILE and API_MTLS_CLIENT_NAME so the
#     client script resolves cert/key paths inside the temp workdir.
###############################################################################

###############################################################################
# Defaults
###############################################################################
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GPG_HOMEDIR="/home/USER/.gnupg"
GPG_RECIPIENT="user@example.com"
SRC_DIR=".mtls"
CLIENT_SCRIPT="./cert-manager-api-client.sh"
CLIENT_NAME="cert-manager-automation-client"
DRY_RUN=false
KEEP_WORKDIR=false

# These are the encrypted basenames expected in SRC_DIR as *.gpg.
# They are decrypted into canonical names expected by the client script:
#   api.ca
#   <CLIENT_NAME>.crt
#   <CLIENT_NAME>.key
CA_BASENAME="api.ca"
CRT_BASENAME="api.crt"
KEY_BASENAME="api.key"

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
  -d, --gpg-homedir DIR       GPG homedir to use
                              Default: /home/USER/.gnupg

  -r, --recipient UID         Recipient UID/email for re-encryption
                              Default: user@example.com

  -s, --src-dir DIR           Directory containing encrypted files
                              Default: .mtls

  -c, --client-script PATH    Path to cert-manager-api-client.sh
                              Default: ./cert-manager-api-client.sh

  -n, --client-name NAME      mTLS client name / cert CN basename
                              Used to create:
                                <workdir>/api.ca
                                <workdir>/<NAME>.crt
                                <workdir>/<NAME>.key
                              Default: cert-manager-automation-client

      --ca-basename NAME      Encrypted CA basename in source dir
                              Default: api.ca

      --crt-basename NAME     Encrypted client cert basename in source dir
                              Default: api.crt

      --key-basename NAME     Encrypted client key basename in source dir
                              Default: api.key

      --keep-workdir          Keep temp workdir after run (debugging only)

      --dry-run               Show what would happen without changing files

  -h, --help                  Show this help message

Client args:
  Everything after '--' is forwarded to the client script exactly as-is.

Examples:
  ${SCRIPT_NAME} -- --help

  ${SCRIPT_NAME} \\
    --gpg-homedir /home/USER/.gnupg \\
    --recipient user@example.com \\
    --src-dir .mtls \\
    --client-script ./cert-manager-api-client.sh \\
    --client-name cert-manager-automation-client \\
    -- health

  ${SCRIPT_NAME} \\
    --src-dir .mtls \\
    --client-script ./cert-manager-api-client.sh \\
    --client-name cert-manager-automation-client \\
    -- add --fqdn test.example.com --dns cloudflare --email admin@test.com

  ${SCRIPT_NAME} \\
    --src-dir .mtls \\
    --client-script ./cert-manager-api-client.sh \\
    --client-name cert-manager-automation-client \\
    -- delete --fqdn test.example.com
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

print_summary() {
  cat <<EOF
────────────────────────────────────────────────────────────
🔐 GPG Wrapper Configuration
────────────────────────────────────────────────────────────
Script          : $SCRIPT_NAME
GPG homedir     : $GPG_HOMEDIR
Recipient       : $GPG_RECIPIENT
Source dir      : $SRC_DIR
Client script   : $CLIENT_SCRIPT
Client name     : $CLIENT_NAME
CA basename     : $CA_BASENAME
CRT basename    : $CRT_BASENAME
KEY basename    : $KEY_BASENAME
Dry-run         : $DRY_RUN
Keep workdir    : $KEEP_WORKDIR
Work dir        : ${WORKDIR:-"(not created yet)"}
Client args     : ${CLIENT_ARGS[*]:-"(none)"}
────────────────────────────────────────────────────────────
EOF
}

cleanup() {
  local exit_code=$?

  if [[ "$DECRYPTION_DONE" == "true" ]]; then
    info "Re-encrypting decrypted material before exit..."

    local plain_ca="${WORKDIR}/api.ca"
    local plain_crt="${WORKDIR}/${CLIENT_NAME}.crt"
    local plain_key="${WORKDIR}/${CLIENT_NAME}.key"

    local enc_ca="${SRC_DIR}/${CA_BASENAME}.gpg"
    local enc_crt="${SRC_DIR}/${CRT_BASENAME}.gpg"
    local enc_key="${SRC_DIR}/${KEY_BASENAME}.gpg"

    if [[ -f "$plain_ca" ]]; then
      info "Encrypting ${plain_ca} -> ${enc_ca}"
      run_cmd gpg --batch --yes \
        --homedir "$GPG_HOMEDIR" \
        --output "$enc_ca" \
        --encrypt \
        --recipient "$GPG_RECIPIENT" \
        "$plain_ca"
      [[ "$DRY_RUN" == "true" ]] || shred -u "$plain_ca" 2>/dev/null || rm -f "$plain_ca"
    else
      warn "Missing plaintext CA during cleanup: ${plain_ca}"
    fi

    if [[ -f "$plain_crt" ]]; then
      info "Encrypting ${plain_crt} -> ${enc_crt}"
      run_cmd gpg --batch --yes \
        --homedir "$GPG_HOMEDIR" \
        --output "$enc_crt" \
        --encrypt \
        --recipient "$GPG_RECIPIENT" \
        "$plain_crt"
      [[ "$DRY_RUN" == "true" ]] || shred -u "$plain_crt" 2>/dev/null || rm -f "$plain_crt"
    else
      warn "Missing plaintext client cert during cleanup: ${plain_crt}"
    fi

    if [[ -f "$plain_key" ]]; then
      info "Encrypting ${plain_key} -> ${enc_key}"
      run_cmd gpg --batch --yes \
        --homedir "$GPG_HOMEDIR" \
        --output "$enc_key" \
        --encrypt \
        --recipient "$GPG_RECIPIENT" \
        "$plain_key"
      [[ "$DRY_RUN" == "true" ]] || shred -u "$plain_key" 2>/dev/null || rm -f "$plain_key"
    else
      warn "Missing plaintext client key during cleanup: ${plain_key}"
    fi
  else
    info "Skipping re-encryption because decryption did not complete."
  fi

  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    if [[ "$KEEP_WORKDIR" == "true" ]]; then
      warn "Keeping temp workdir for debugging: $WORKDIR"
    elif [[ "$DRY_RUN" == "true" ]]; then
      info "Would remove temporary work directory: ${WORKDIR}"
    else
      rm -rf "$WORKDIR"
    fi
  fi

  exit "$exit_code"
}

decrypt_one() {
  local encrypted_path="$1"
  local plaintext_path="$2"

  info "Decrypting ${encrypted_path} -> ${plaintext_path}"
  run_cmd gpg --batch --yes \
    --homedir "$GPG_HOMEDIR" \
    --output "$plaintext_path" \
    --decrypt \
    "$encrypted_path"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "Would set secure permissions on: ${plaintext_path}"
  else
    chmod 600 "$plaintext_path" 2>/dev/null || true
  fi
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
    --ca-basename)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CA_BASENAME="$2"
      shift 2
      ;;
    --crt-basename)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CRT_BASENAME="$2"
      shift 2
      ;;
    --key-basename)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      KEY_BASENAME="$2"
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
# Validation
###############################################################################
require_cmd gpg
require_cmd mktemp
require_cmd rm
require_cmd dirname

if [[ "$DRY_RUN" != "true" ]]; then
  require_cmd shred
fi

require_dir "$SRC_DIR"
require_dir "$GPG_HOMEDIR"
require_file "$CLIENT_SCRIPT"
[[ -x "$CLIENT_SCRIPT" ]] || die "Client script must be executable: $CLIENT_SCRIPT"
[[ -n "$GPG_RECIPIENT" ]] || die "Recipient must not be empty"
[[ -n "$CLIENT_NAME" ]] || die "Client name must not be empty"

require_file "${SRC_DIR}/${CA_BASENAME}.gpg"
require_file "${SRC_DIR}/${CRT_BASENAME}.gpg"
require_file "${SRC_DIR}/${KEY_BASENAME}.gpg"

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

decrypt_one "${SRC_DIR}/${CA_BASENAME}.gpg"  "${WORKDIR}/api.ca"
decrypt_one "${SRC_DIR}/${CRT_BASENAME}.gpg" "${WORKDIR}/${CLIENT_NAME}.crt"
decrypt_one "${SRC_DIR}/${KEY_BASENAME}.gpg" "${WORKDIR}/${CLIENT_NAME}.key"

DECRYPTION_DONE=true
ok "Decryption complete."

###############################################################################
# Export overrides so client script resolves paths from decrypted temp dir
###############################################################################
export MTLS_DIR="$WORKDIR"
export API_MTLS_CA_FILE="${WORKDIR}/api.ca"
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