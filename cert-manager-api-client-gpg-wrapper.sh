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
# Defaults
###############################################################################
SCRIPT_NAME="$(basename "$0")"

GPG_HOMEDIR="/home/USER/.gnupg"
GPG_RECIPIENT="user@example.com"
HOOK_SCRIPT="./my_hook_script.sh"
SRC_DIR=".mtls"
DRY_RUN=false

FILES=(
  "api.ca"
  "api.crt"
  "api.key"
)

###############################################################################
# Runtime state
###############################################################################
CUSTOM_FILES=()
WORKDIR=""
DECRYPTION_DONE=false

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
  ${SCRIPT_NAME} [options]

Options:
  -f, --file NAME           File basename to process (repeatable)
                            Example: -f api.ca -f api.crt -f api.key

  -d, --gpg-homedir DIR     GPG homedir to use
                            Default: /home/USER/.gnupg

  -r, --recipient UID       Recipient UID/email for encryption
                            Default: user@example.com

  -s, --src-dir DIR         Directory containing encrypted files
                            Default: .mtls

  -k, --hook-script PATH    Hook script to execute after decryption
                            Default: ./my_hook_script.sh

  -n, --dry-run             Show what would happen without changing files

  -h, --help                Show this help message

Examples:
  ${SCRIPT_NAME}

  ${SCRIPT_NAME} \
    --gpg-homedir /home/USER/.gnupg \
    --recipient user@example.com \
    --src-dir .mtls \
    --hook-script ./deploy_hook.sh

  ${SCRIPT_NAME} \
    -f api.ca -f api.crt -f api.key \
    --dry-run
EOF
}

###############################################################################
# Helpers
###############################################################################
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
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
Script        : $SCRIPT_NAME
GPG homedir   : $GPG_HOMEDIR
Recipient     : $GPG_RECIPIENT
Source dir    : $SRC_DIR
Hook script   : $HOOK_SCRIPT
Dry-run       : $DRY_RUN
Files         : ${FILES[*]}
Work dir      : ${WORKDIR:-"(not created yet)"}
────────────────────────────────────────────────────────────
EOF
}

cleanup() {
  local exit_code=$?

  if [[ "$DECRYPTION_DONE" == "true" ]]; then
    info "Re-encrypting decrypted material before exit..."

    for base in "${FILES[@]}"; do
      local plain="${WORKDIR}/${base}"
      local enc="${SRC_DIR}/${base}.gpg"

      if [[ -f "$plain" ]]; then
        info "Encrypting ${plain} -> ${enc}"

        run_cmd gpg --batch --yes \
          --homedir "$GPG_HOMEDIR" \
          --output "$enc" \
          --encrypt \
          --recipient "$GPG_RECIPIENT" \
          "$plain"

        if [[ "$DRY_RUN" == "true" ]]; then
          info "Would securely delete plaintext file: ${plain}"
        else
          shred -u "$plain" 2>/dev/null || rm -f "$plain"
        fi
      else
        warn "Plaintext file not found during cleanup, skipping: ${plain}"
      fi
    done
  else
    info "Skipping re-encryption because decryption did not complete."
  fi

  if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "Would remove temporary work directory: ${WORKDIR}"
    else
      rm -rf "$WORKDIR"
    fi
  fi

  exit "$exit_code"
}

###############################################################################
# Optional env loading
###############################################################################
if [[ -f .env ]]; then
  info "Loading environment from .env"
  # shellcheck disable=SC1091
  source .env
fi

###############################################################################
# Parsing
###############################################################################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--file)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      CUSTOM_FILES+=("$2")
      shift 2
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
    -k|--hook-script)
      [[ $# -ge 2 ]] || die "Missing value for $1"
      HOOK_SCRIPT="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

if (( ${#CUSTOM_FILES[@]} > 0 )); then
  FILES=("${CUSTOM_FILES[@]}")
fi

###############################################################################
# Validation
###############################################################################
require_cmd gpg
require_cmd mktemp
require_cmd rm

if [[ "$DRY_RUN" != "true" ]]; then
  require_cmd shred
fi

[[ -d "$SRC_DIR" ]] || die "Source directory does not exist: $SRC_DIR"
[[ -d "$GPG_HOMEDIR" ]] || die "GPG homedir does not exist: $GPG_HOMEDIR"
[[ -f "$HOOK_SCRIPT" ]] || die "Hook script not found: $HOOK_SCRIPT"
[[ -x "$HOOK_SCRIPT" ]] || die "Hook script must be executable: $HOOK_SCRIPT"
[[ -n "$GPG_RECIPIENT" ]] || die "Recipient must not be empty"

for base in "${FILES[@]}"; do
  [[ -f "${SRC_DIR}/${base}.gpg" ]] || die "Missing encrypted file: ${SRC_DIR}/${base}.gpg"
done

chmod 700 "$SRC_DIR" 2>/dev/null || true
chmod 700 "$GPG_HOMEDIR" 2>/dev/null || true

WORKDIR="$(mktemp -d)"
chmod 700 "$WORKDIR" 2>/dev/null || true

trap cleanup EXIT

print_summary

###############################################################################
# Decrypt into temp workdir
###############################################################################
info "Decrypting requested material into temporary work directory..."

for base in "${FILES[@]}"; do
  enc="${SRC_DIR}/${base}.gpg"
  plain="${WORKDIR}/${base}"

  info "Decrypting ${enc} -> ${plain}"
  run_cmd gpg --batch --yes \
    --homedir "$GPG_HOMEDIR" \
    --output "$plain" \
    --decrypt \
    "$enc"
done

for sensitive in "${FILES[@]}"; do
  if [[ "$DRY_RUN" == "true" ]]; then
    info "Would set secure permissions on: ${WORKDIR}/${sensitive}"
  elif [[ -f "${WORKDIR}/${sensitive}" ]]; then
    chmod 600 "${WORKDIR}/${sensitive}" 2>/dev/null || true
  fi
done

DECRYPTION_DONE=true
ok "Decryption complete."

###############################################################################
# Run hook
###############################################################################
info "Executing hook script: $HOOK_SCRIPT"

if [[ "$DRY_RUN" == "true" ]]; then
  info "Would run hook script with plaintext files available in: $WORKDIR"
else
  MTLS_DIR="$WORKDIR" "$HOOK_SCRIPT"
fi

ok "Hook execution complete."