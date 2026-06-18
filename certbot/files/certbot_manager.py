#!/usr/bin/env python3
"""
🚀 Enterprise Certbot Provisioning Service
-----------------------------------------
A high-availability automation engine for TLS certificate lifecycles.

CSV Backward Compatibility
--------------------------

Old/original CSV format is fully supported:

    fqdn,dns_provider,email
    repo.example.io,cloudflare,admin@example.com

In this format, no key-related Certbot flags are added.
Certbot will use its default key behavior.

Optional new CSV format:

    fqdn,dns_provider,email,key_type,key_param
    repo.example.io,cloudflare,admin@example.com,,
    legacy.example.io,cloudflare,admin@example.com,rsa,4096

Supported optional key values:

    key_type=rsa
    key_param=2048, 3072, or 4096

Design rule:
    CSV = per-certificate settings.
    CLI flags = container/runtime settings.
"""

import argparse
import csv
import os
import shlex
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


# --- Configuration ---

SECRETS_DIR = Path("/etc/letsencrypt/secrets")

# Delay used when the service hits a recoverable runtime issue.
RETRY_DELAY = 60

# Default DNS propagation delay in seconds.
DEFAULT_PROPAGATION_DELAY = 60

# Slower propagation delay for legacy DNS credentials/providers.
LEGACY_PROPAGATION_DELAY = 200

# RSA sizes accepted from CSV.
SUPPORTED_RSA_SIZES = {"2048", "3072", "4096"}


def log(message, is_error=False):
    """Print a timestamped log message."""
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    icon = "❌ ERROR:" if is_error else "ℹ️ "
    print(
        f"[{timestamp}] {icon} {message}",
        file=sys.stderr if is_error else sys.stdout,
    )


# --- Argument Parsing ---

parser = argparse.ArgumentParser(
    description="🛠️  Certbot Manager: Automated TLS lifecycle for Enterprise Infrastructure.",
    formatter_class=argparse.RawDescriptionHelpFormatter,
)

# Runtime/container options.
# Certificate-specific values belong in the CSV.
parser.add_argument(
    "--csv",
    required=True,
    help="Path to the certificate inventory CSV.",
)

parser.add_argument(
    "--hook",
    help="Optional deploy hook script to run after successful issuance/renewal.",
)

parser.add_argument(
    "--frequency",
    type=int,
    default=60,
    help="Frequency in minutes between processing cycles.",
)

parser.add_argument(
    "--propagation-delay",
    type=int,
    default=None,
    help="Global DNS propagation delay override in seconds.",
)

parser.add_argument(
    "--verbose",
    action="store_true",
    help="Enable verbose Certbot output.",
)

args = parser.parse_args()


def get_dns_plugin(provider_key):
    """
    Determine which Certbot DNS plugin to use.

    Current behavior:
        - If dns_provider contains 'cloudflare', use dns-cloudflare.
        - Otherwise, fall back to dns-rfc2136.

    Example:
        cloudflare      -> --dns-cloudflare
        rfc2136-prod    -> --dns-rfc2136
        legacy-dns      -> --dns-rfc2136
    """
    return "cloudflare" if "cloudflare" in provider_key.lower() else "rfc2136"


def get_propagation_delay(provider_key):
    """
    Determine DNS propagation delay.

    Priority:
        1. CLI --propagation-delay override.
        2. Legacy delay if dns_provider contains 'legacy'.
        3. Default propagation delay.
    """
    if args.propagation_delay is not None:
        return args.propagation_delay

    if "legacy" in provider_key.lower():
        return LEGACY_PROPAGATION_DELAY

    return DEFAULT_PROPAGATION_DELAY


def apply_key_options(cmd, fqdn, key_type=None, key_param=None):
    """
    Add optional Certbot key options.

    Backward-compatible behavior:
        - If key_type/key_param are missing or blank, do nothing.
        - Certbot will use its default key behavior.

    Supported forced behavior:
        key_type=rsa
        key_param=2048, 3072, or 4096

    Example resulting flags:
        --key-type rsa --rsa-key-size 4096
    """
    key_type = (key_type or "").strip().lower()
    key_param = str(key_param or "").strip()

    # Important backward-compatible behavior:
    # No key_type means old CSV behavior. Do not add key flags.
    if not key_type:
        return

    if key_type == "rsa":
        if key_param in SUPPORTED_RSA_SIZES:
            cmd.extend(["--key-type", "rsa", "--rsa-key-size", key_param])
        else:
            log(
                f"Invalid RSA key size for {fqdn}: '{key_param}'. "
                f"Expected one of: {', '.join(sorted(SUPPORTED_RSA_SIZES))}. "
                "Skipping custom key options and using Certbot defaults.",
                is_error=True,
            )
        return

    log(
        f"Invalid key type for {fqdn}: '{key_type}'. "
        "Only 'rsa' is currently supported for forced key behavior. "
        "Skipping custom key options and using Certbot defaults.",
        is_error=True,
    )


def build_certbot_command(
    fqdn,
    provider_key,
    email,
    key_type=None,
    key_param=None,
    hook_script=None,
):
    """
    Build the Certbot command for a single certificate entry.

    This function keeps command construction centralized and easier to test.
    """
    plugin = get_dns_plugin(provider_key)
    creds_path = SECRETS_DIR / f"{provider_key}.ini"
    current_delay = get_propagation_delay(provider_key)

    cmd = [
        "certbot",
        "certonly",
        "--non-interactive",
        "--agree-tos",
        "--email",
        email,
        f"--dns-{plugin}",
        f"--dns-{plugin}-credentials",
        str(creds_path),
        f"--dns-{plugin}-propagation-seconds",
        str(current_delay),
        "--keep-until-expiring",
        "-d",
        fqdn,
    ]

    if args.verbose:
        cmd.append("-vvv")

    # Optional per-certificate key behavior from CSV.
    # If missing, old CSV behavior is preserved.
    apply_key_options(cmd, fqdn, key_type, key_param)

    if hook_script:
        # Certbot --deploy-hook receives a shell command string.
        # shlex.quote protects paths/domains that may contain shell-sensitive characters.
        hook_command = f"{shlex.quote(str(hook_script))} {shlex.quote(fqdn)}"
        cmd.extend(["--deploy-hook", hook_command])

    return cmd, creds_path


def run_certbot(
    fqdn,
    provider_key,
    email,
    key_type=None,
    key_param=None,
    hook_script=None,
):
    """Execute Certbot for a single FQDN."""
    print(f"\n🔍 [PROVISIONING] Target: {fqdn}")
    print(f"   {'·' * 40}")

    cmd, creds_path = build_certbot_command(
        fqdn=fqdn,
        provider_key=provider_key,
        email=email,
        key_type=key_type,
        key_param=key_param,
        hook_script=hook_script,
    )

    if not creds_path.exists():
        log(f"Missing credentials for {fqdn} at {creds_path}", is_error=True)
        print(f"   {'·' * 40}")
        return

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=True,
        )

        if "Certificate not yet due" in result.stdout:
            print("   ✅ STATUS: VALID (No action needed)")
        else:
            print("   ✨ STATUS: ISSUED/RENEWED successfully")

    except subprocess.CalledProcessError as e:
        log(f"Failed to process {fqdn}!", is_error=True)

        # Keep Certbot output visually grouped under the domain block.
        error_output = e.stderr.strip() or e.stdout.strip()

        if error_output:
            for line in error_output.splitlines():
                print(f"     | {line}")
        else:
            print("     | Certbot failed without stderr/stdout output.")

    print(f"   {'·' * 40}")


def validate_required_row_fields(row):
    """
    Validate required CSV fields.

    Required columns:
        fqdn
        dns_provider
        email

    If any required value is missing, skip only that row.
    This prevents one bad API-created entry from breaking the whole cycle.
    """
    fqdn = (row.get("fqdn") or "").strip()
    provider = (row.get("dns_provider") or "").strip()
    email = (row.get("email") or "").strip()

    if not fqdn or not provider or not email:
        log(
            f"Skipping invalid CSV row. Missing fqdn, dns_provider, or email: {row}",
            is_error=True,
        )
        return None

    return fqdn, provider, email


def extract_key_options(row):
    """
    Extract optional key settings from CSV.

    Optional columns:
        key_type,key_param

    Old CSV behavior:
        If these columns do not exist, or the values are blank,
        return None values so Certbot uses defaults.
    """
    key_type = (row.get("key_type") or "").strip().lower()
    key_param = (row.get("key_param") or "").strip()

    return key_type or None, key_param or None


def resolve_hook_script():
    """
    Validate optional deploy hook.

    If hook is not provided, return None.
    If hook path is invalid, log the issue and continue without a hook.
    """
    if not args.hook:
        return None

    hook_path = Path(args.hook)

    if not hook_path.exists() or not hook_path.is_file():
        log(
            f"Hook script not found or not a file: {args.hook}. Continuing without hook.",
            is_error=True,
        )
        return None

    if not os.access(hook_path, os.X_OK):
        log(
            f"Hook script is not executable: {args.hook}. Continuing without hook.",
            is_error=True,
        )
        return None

    return hook_path.resolve()


def check_dns_connectivity():
    """
    Basic DNS connectivity check.

    This verifies that the container can resolve Let's Encrypt's ACME endpoint.
    If resolution fails, the current cycle is skipped and retried later.
    """
    try:
        socket.gethostbyname("acme-v02.api.letsencrypt.org")
        return True
    except socket.gaierror as e:
        log(f"DNS connectivity check failed: {e}", is_error=True)
        return False


def process_csv(csv_file, hook_script):
    """
    Read the CSV inventory and process each valid certificate row.

    Old CSV headers are supported:
        fqdn,dns_provider,email

    Optional new headers are supported:
        fqdn,dns_provider,email,key_type,key_param
    """
    log(f"Reading: {csv_file}")

    with csv_file.open(mode="r", encoding="utf-8") as f:
        reader = csv.DictReader(f, skipinitialspace=True)

        if not reader.fieldnames:
            log(f"CSV file '{csv_file}' is empty or missing headers.", is_error=True)
            return

        for row in reader:
            required_values = validate_required_row_fields(row)

            if not required_values:
                continue

            fqdn, provider, email = required_values
            key_type, key_param = extract_key_options(row)

            run_certbot(
                fqdn=fqdn,
                provider_key=provider,
                email=email,
                key_type=key_type,
                key_param=key_param,
                hook_script=hook_script,
            )


def main_service():
    """Main service loop for the Docker container entrypoint."""
    csv_file = Path(args.csv)
    hook_script = resolve_hook_script()

    while True:
        try:
            print("\n" + "█" * 70)
            log(f"🔄 STARTING PROCESSING CYCLE (Freq: {args.frequency}m)")

            if not check_dns_connectivity():
                time.sleep(RETRY_DELAY)
                continue

            if not csv_file.exists():
                log(f"📄 CSV file '{csv_file}' missing!", is_error=True)
                time.sleep(RETRY_DELAY)
                continue

            process_csv(csv_file, hook_script)

            print("\n" + "█" * 70)
            log(f"🏁 Cycle complete. Sleeping for {args.frequency} minutes.")
            time.sleep(args.frequency * 60)

        except Exception as e:
            log(f"💥 Runtime Exception: {e}", is_error=True)
            time.sleep(RETRY_DELAY)


def shutdown_handler(signum, frame):
    """Handle Docker stop/interrupt signals cleanly."""
    print("\n")
    log("🛑 Service termination received. Goodbye!")
    sys.exit(0)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)

    print("\n" + "🌟" * 20)
    print("  CERTBOT MANAGER LOADED")
    print("🌟" * 20)

    main_service()
