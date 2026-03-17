#!/usr/bin/env python3
"""
🚀 Enterprise Certbot Provisioning Service
-----------------------------------------
A high-availability automation engine for TLS certificate lifecycles.
"""

import argparse
import cmd
import csv
import sys
import subprocess
import time
import signal
import socket
from pathlib import Path

# --- Configuration ---
SECRETS_DIR = Path("/etc/letsencrypt/secrets")
RETRY_DELAY = 60

def log(message, is_error=False):
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    icon = "❌ ERROR:" if is_error else "ℹ️ "
    print(f"[{timestamp}] {icon} {message}", file=sys.stderr if is_error else sys.stdout)


# --- Argument Parsing ---
parser = argparse.ArgumentParser(
    description="🛠️  Certbot Manager: Automated TLS lifecycle for Enterprise Infrastructure.",
    formatter_class=argparse.RawDescriptionHelpFormatter
)
parser.add_argument("--csv", required=True, help="Mandatory: Path to the CSV file listing domains,dns_provider,email per line.")
parser.add_argument("--hook", help="Optional: Executable script to run after success.")
parser.add_argument("--frequency", type=int, default=60, help="Frequency in minutes.")
parser.add_argument("--propagation-delay", type=int, default=60, help="DNS propagation delay in seconds (default: 60).")
parser.add_argument("--verbose", action="store_true", help="Enable verbose output (adds -vvv to Certbot commands).")

args = parser.parse_args()


def run_certbot(fqdn, provider_key, email, hook_script):
    """Executes Certbot with clear visual boundaries for each domain."""
    print(f"\n🔍 [PROVISIONING] Target: {fqdn}")
    print(f"   {'·' * 40}")  # Subtle internal separator

    # Determine plugin and provider path and .ini file based (fall back to rfc2136 if not cloudflare)
    plugin = "cloudflare" if "cloudflare" in provider_key.lower() else "rfc2136"
    creds_path = SECRETS_DIR / f"{provider_key}.ini"

    if not creds_path.exists():
        log(f"Missing credentials for {fqdn} at {creds_path}", is_error=True)
        return

    cmd = [
        "certbot", "certonly", "--non-interactive", "--agree-tos",
        "--email", email, f"--dns-{plugin}",
        f"--dns-{plugin}-credentials", str(creds_path),
        "--dns-rfc2136-propagation-seconds", str(args.propagation_delay),
        "--keep-until-expiring", "-d", fqdn
    ]

    if args.verbose:
        cmd.append("-vvv")

    if hook_script:
        cmd.extend(["--deploy-hook", f"{hook_script} {fqdn}"])

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        if "Certificate not yet due" in result.stdout:
            print(f"   ✅ STATUS: VALID (No action needed)")
        else:
            print(f"   ✨ STATUS: ISSUED/RENEWED successfully")
    except subprocess.CalledProcessError as e:
        log(f"Failed to process {fqdn}!", is_error=True)
        # Indent the error details to keep the domain block visually unified
        error_lines = e.stderr.strip().split('\n')
        for line in error_lines:
            print(f"     | {line}")

    print(f"   {'·' * 40}")  # Closing internal separator


def main_service():
    csv_file = Path(args.csv)
    hook_script = None

    if args.hook:
        p = Path(args.hook)
        if p.exists() and p.is_file():
            hook_script = p.resolve()

    while True:
        try:
            print("\n" + "█" * 70)
            log(f"🔄 STARTING PROCESSING CYCLE (Freq: {args.frequency}m)")

            if not socket.gethostbyname("acme-v02.api.letsencrypt.org"):  # Basic DNS connectivity check
                pass

            if not csv_file.exists():
                log(f"📄 CSV file '{csv_file}' missing!", is_error=True)
                time.sleep(RETRY_DELAY)
                continue

            log(f"Reading: {csv_file.name}")

            with csv_file.open(mode='r', encoding='utf-8') as f:
                reader = csv.DictReader(f, skipinitialspace=True)
                for row in reader:
                    run_certbot(row["fqdn"], row["dns_provider"], row["email"], hook_script)

            print("\n" + "█" * 70)
            log(f"🏁 Cycle complete. Sleeping for {args.frequency} minutes.")
            time.sleep(args.frequency * 60)

        except Exception as e:
            log(f"💥 Runtime Exception: {e}", is_error=True)
            time.sleep(RETRY_DELAY)


def shutdown_handler(signum, frame):
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
