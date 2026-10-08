#!/usr/bin/env python3
"""
===============================================================================
🚀 ENTERPRISE CERTBOT CERTIFICATE LIFECYCLE MANAGER
===============================================================================

DESCRIPTION
-----------
A CSV-driven automation service for managing Let's Encrypt TLS certificates
using Certbot and DNS-01 authentication.

Designed for containerized environments, this service continuously monitors
a certificate inventory, processes certificate issuance and renewals, and
optionally executes deployment hooks following successful operations.

The service provides configurable DNS propagation delays, real-time Certbot
logging, execution timeouts, failure backoff, graceful shutdown handling,
and safeguards against concurrent execution.


KEY FEATURES
------------
  • Automated certificate issuance and renewal.
  • CSV-based certificate inventory management.
  • Cloudflare and RFC2136 DNS authentication.
  • Provider-specific DNS propagation configuration.
  • Real-time Certbot output with periodic heartbeat messages.
  • Per-certificate exponential failure backoff.
  • Configurable command execution timeouts.
  • Graceful SIGTERM/SIGINT shutdown handling.
  • File locking to prevent concurrent manager instances.
  • Optional certificate deployment hooks.
  • Isolated Let's Encrypt staging environment.
  • Single-cycle execution mode for testing and automation.
  • Certificate issuance and renewal status tracking.
  • Per-cycle processing summaries.
  • Credential file permission warnings.


CSV INVENTORY FORMAT
--------------------
Required columns:

    fqdn,dns_provider,email

Example:

    fqdn,dns_provider,email
    app.example.com,cloudflare,admin@example.com
    vpn.example.com,primarydns,admin@example.com
    legacy.example.com,legacydns,admin@example.com

Supported DNS providers:

    cloudflare  -> Certbot Cloudflare DNS plugin
    primarydns  -> Certbot RFC2136 DNS plugin
    legacydns   -> Certbot RFC2136 DNS plugin
    rfc2136     -> Certbot RFC2136 DNS plugin

Credentials are expected at:

    /etc/letsencrypt/secrets/<dns_provider>.ini

The credentials directory can be customized using --secrets-dir.

IMPORTANT:
    The CSV parser validates the entire inventory before processing.
    Invalid domains, duplicate FQDNs, unsupported providers, or malformed
    entries prevent the processing cycle from proceeding.


DNS PROPAGATION CONFIGURATION
-----------------------------
DNS propagation delays are determined using the following precedence:

    1. --propagation-delay CLI override.
    2. Propagation setting inside the provider credentials file.
    3. Provider-specific default.

Default propagation delays:

    legacydns               : 300 seconds
    All other providers     : 60 seconds

These defaults can be customized using:

    --legacy-propagation-delay
    --default-propagation-delay

The global --propagation-delay overrides all provider-specific settings.


CERTIFICATE DEPLOYMENT HOOKS
----------------------------
An optional executable deployment hook can be specified using:

    --hook /path/to/deploy-hook.sh

The hook executes following successful certificate issuance or renewal.

The hook receives:

    argv[1]           : FQDN from the CSV inventory
    RENEWED_LINEAGE   : Actual certificate lineage directory
    RENEWED_DOMAINS   : Domains associated with the certificate

IMPORTANT:
    Deployment hooks MUST use RENEWED_LINEAGE to locate certificates.

    Do not construct certificate paths directly from the CSV FQDN.
    Certbot certificate lineage names may differ from the requested domain.

    Deployment hooks are prohibited when --staging is enabled.

A failed deployment hook is tracked separately from a Certbot issuance
failure.


EXECUTION AND FAILURE HANDLING
------------------------------
The manager executes Certbot as a subprocess and streams its output
directly to the container logs.

Execution safeguards include:

    • Configurable command execution timeout.
    • Automatic timeout extension based on DNS propagation delay.
    • Periodic heartbeat logging during execution.
    • Graceful process-group termination.
    • Forced termination after the configured grace period.
    • Per-certificate exponential failure backoff.

Default failure backoff:

    Initial delay    : 3600 seconds (1 hour)
    Maximum delay    : 86400 seconds (24 hours)

Backoff state is maintained in memory.

Restarting the service resets this state. It does not reset external
Let's Encrypt rate limits.

The manager uses an exclusive file lock to prevent multiple instances
from running concurrently when they share the same lock file.


STAGING AND TESTING
-------------------
Use --staging to test certificate issuance against Let's Encrypt's
staging environment.

Staging certificates:

    • Are not trusted by production clients.
    • Are stored in isolated configuration directories.
    • Do not execute user deployment hooks.

Default staging directory:

    /etc/letsencrypt/staging-manager/

Use --once to execute a single processing cycle and exit.

Example:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --staging \
        --once


COMMON USAGE EXAMPLES
---------------------
1. Standard continuous operation:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv

2. Enable verbose Certbot logging:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --verbose

3. Enable deployment hooks:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --hook /usr/local/bin/deploy-certificate.sh

4. Customize processing frequency:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --frequency 30

5. Override DNS propagation delay:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --propagation-delay 120

6. Perform a single staging validation cycle:

    python3 certbot_manager.py \
        --csv /etc/letsencrypt/certificates.csv \
        --staging \
        --once


OPERATIONAL NOTES
-----------------
• Designed for long-running execution inside Docker containers.

• SIGTERM and SIGINT initiate graceful shutdown.

• The manager processes certificates sequentially.

• A failed certificate does not prevent subsequent valid certificates
  from being processed.

• Inventory validation failures prevent the entire processing cycle.

• Successful Certbot execution does not necessarily indicate that
  a certificate was newly issued or renewed.

• Certificate issuance is detected using an internal deployment hook.

• Certificate deployment failures are reported separately.

• The manager does not bypass Let's Encrypt issuance rate limits.

• Python 3 and the appropriate Certbot DNS plugins are required.

• The file-locking mechanism requires a Unix-compatible environment.


===============================================================================
"""
import argparse
import csv
import fcntl
import os
import re
import selectors
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
from collections import Counter
from pathlib import Path

PROVIDERS = {"legacydns": "rfc2136", "primarydns": "rfc2136",
             "rfc2136": "rfc2136", "cloudflare": "cloudflare"}
STOP = False
ACTIVE = None


def log(message, error=False):
    stamp = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{stamp}] {'❌ ERROR:' if error else 'ℹ️ INFO:'} {message}", flush=True)


def positive(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than zero")
    return number


def nonnegative(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be zero or greater")
    return number


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--csv", required=True, type=Path)
    parser.add_argument("--hook", type=Path)
    parser.add_argument("--frequency", type=positive, default=60,
                        help="Minutes between cycles (default: 60)")
    parser.add_argument("--propagation-delay", type=nonnegative,
                        help="Override propagation wait for ALL providers")
    parser.add_argument("--legacy-propagation-delay", type=nonnegative, default=300)
    parser.add_argument("--default-propagation-delay", type=nonnegative, default=60)
    parser.add_argument("--secrets-dir", type=Path, default=Path("/etc/letsencrypt/secrets"))
    parser.add_argument("--lock-file", type=Path,
                        default=Path("/etc/letsencrypt/.certbot-manager.lock"))
    parser.add_argument("--command-timeout", type=positive, default=1800,
                        help="Minimum per-command timeout; automatically enlarged for DNS wait")
    parser.add_argument("--termination-grace", type=positive, default=30)
    parser.add_argument("--backoff-base", type=positive, default=3600,
                        help="Initial failure backoff in seconds")
    parser.add_argument("--backoff-max", type=positive, default=86400)
    parser.add_argument("--heartbeat", type=positive, default=30)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--staging", action="store_true",
                        help="Use isolated staging config/work/log directories; NEVER deploy")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.backoff_max < args.backoff_base:
        parser.error("--backoff-max must be >= --backoff-base")
    if args.staging and args.hook:
        parser.error("--staging cannot be combined with --hook")
    if args.hook:
        args.hook = args.hook.resolve()
        if not args.hook.is_file() or not os.access(args.hook, os.X_OK):
            parser.error("--hook must be an existing executable file")
    return args


def valid_domain(value):
    name = value[2:] if value.startswith("*.") else value
    if len(name) > 253 or "." not in name:
        return False
    return all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
               for label in name.split("."))


def read_rows(path):
    rows, seen = [], set()
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream, skipinitialspace=True)
        if not reader.fieldnames or not {"fqdn", "dns_provider", "email"}.issubset(reader.fieldnames):
            raise ValueError("CSV requires fqdn,dns_provider,email headers")
        for row in reader:
            if not any(row.values()):
                continue
            if None in row:
                raise ValueError(f"CSV line {reader.line_num}: extra fields")
            fqdn = (row.get("fqdn") or "").strip().lower()
            provider = (row.get("dns_provider") or "").strip().lower()
            email = (row.get("email") or "").strip()
            if not valid_domain(fqdn):
                raise ValueError(f"CSV line {reader.line_num}: invalid FQDN")
            if provider not in PROVIDERS:
                raise ValueError(f"CSV line {reader.line_num}: unsupported provider {provider!r}")
            if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
                raise ValueError(f"CSV line {reader.line_num}: invalid email")
            if fqdn in seen:
                raise ValueError(f"CSV line {reader.line_num}: duplicate FQDN {fqdn}")
            seen.add(fqdn)
            rows.append((fqdn, provider, email))
    if not rows:
        raise ValueError("CSV has no domains")
    return rows


def propagation_delay(args, provider, credentials):
    # Do not print credentials or include their contents in error messages.
    setting = f"dns_{PROVIDERS[provider]}_propagation_seconds"
    configured = None
    matches = 0
    for raw in credentials.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith(("#", ";")):
            continue
        key, separator, value = line.partition("=")
        if separator and key.strip() == setting:
            matches += 1
            value = re.split(r"\s*[#;]", value, maxsplit=1)[0].strip().strip("\"'")
            if not value.isdigit():
                raise ValueError(f"Invalid {setting} in {credentials.name}")
            configured = int(value)
    if matches > 1:
        raise ValueError(f"Duplicate {setting} in {credentials.name}")
    if args.propagation_delay is not None:
        return args.propagation_delay
    if configured is not None:
        return configured
    return (args.legacy_propagation_delay if provider == "legacydns"
            else args.default_propagation_delay)


def shutdown(signum, frame):
    global STOP
    STOP = True


def signal_child(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def execute(command, timeout, args):
    """Stream output without waiting for newline; terminate the process group safely."""
    global ACTIVE
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               start_new_session=True, env={**os.environ, "PYTHONUNBUFFERED": "1"})
    ACTIVE = process
    start = last_heartbeat = time.monotonic()
    terminating = None
    timed_out = False
    retained = bytearray()
    selector = selectors.DefaultSelector()
    os.set_blocking(process.stdout.fileno(), False)
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while selector.get_map() or process.poll() is None:
            now = time.monotonic()
            if terminating is None and (STOP or now - start >= timeout):
                timed_out = not STOP
                log("Stopping active Certbot command: " + ("timeout" if timed_out else "shutdown"), True)
                signal_child(process, signal.SIGTERM)
                terminating = now
            if terminating is not None and now - terminating >= args.termination_grace:
                signal_child(process, signal.SIGKILL)
            for key, _ in selector.select(timeout=0.5):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                sys.stdout.write(chunk.decode("utf-8", errors="replace"))
                sys.stdout.flush()
                retained.extend(chunk)
                if len(retained) > 131072:
                    del retained[:-131072]
            if now - last_heartbeat >= args.heartbeat:
                log(f"⏳ Certbot command active for {int(now - start)} seconds")
                last_heartbeat = now
        return process.wait(), retained.decode("utf-8", errors="replace"), timed_out
    finally:
        selector.close()
        process.stdout.close()
        if process.poll() is None:
            signal_child(process, signal.SIGKILL)
            process.wait()
        ACTIVE = None


def run_certbot(row, args):
    fqdn, provider, email = row
    credentials = args.secrets_dir / f"{provider}.ini"
    if not credentials.is_file():
        log(f"{fqdn}: missing credentials file {credentials}", True)
        return "failed"
    if credentials.stat().st_mode & 0o077:
        log(f"{fqdn}: credentials permissions allow group/other access; restrict them", True)
    delay = propagation_delay(args, provider, credentials)
    plugin = PROVIDERS[provider]
    print("\n" + "·" * 70, flush=True)
    log(f"🔍 [PROVISIONING] Target: {fqdn}")
    log(f"🌐 Provider: {provider} | ⏳ Propagation wait: {delay}s")
    command = ["certbot", "certonly", "--non-interactive", "--agree-tos",
               "--email", email, f"--dns-{plugin}",
               f"--dns-{plugin}-credentials", str(credentials),
               f"--dns-{plugin}-propagation-seconds", str(delay),
               "--keep-until-expiring", "-d", fqdn]
    if args.verbose:
        command.append("-vvv")
    if args.staging:
        base = Path("/etc/letsencrypt/staging-manager")
        command.extend(["--staging", "--config-dir", str(base / "config"),
                        "--work-dir", str(base / "work"), "--logs-dir", str(base / "logs")])
    # A private temporary deploy hook records issuance independently of output wording.
    # It also distinguishes a user packaging-hook failure from successful issuance.
    with tempfile.TemporaryDirectory(prefix="certbot-manager-") as directory:
        base = Path(directory)
        issued = base / "issued"
        hook_failed = base / "hook-failed"
        wrapper = base / "deploy.sh"
        content = "#!/bin/sh\nset -eu\n"
        content += ': "${RENEWED_LINEAGE:?Certbot did not provide RENEWED_LINEAGE}"\n'
        content += f"printf '%s\\n' \"$RENEWED_LINEAGE\" > {shlex.quote(str(issued))}\n"
        if args.hook:
            call = shlex.join([str(args.hook), fqdn])
            content += (f"if {call}; then\n  :\nelse\n  rc=$?\n"
                        f"  printf '%s\\n' \"$rc\" > {shlex.quote(str(hook_failed))}\n"
                        "  exit \"$rc\"\nfi\n")
        wrapper.write_text(content, encoding="utf-8")
        wrapper.chmod(0o700)
        command.extend(["--deploy-hook", shlex.quote(str(wrapper))])
        rc, output, timed_out = execute(command, max(args.command_timeout, delay + 600), args)
        if STOP:
            return "interrupted"
        if hook_failed.exists():
            log(f"{fqdn}: certificate issued but packaging/deploy hook FAILED", True)
            return "deploy_failed"
        if timed_out or rc != 0:
            log(f"{fqdn}: command failed (exit={rc}, timeout={timed_out}); inspect Certbot log", True)
            return "failed"
        if issued.exists():
            lineage = issued.read_text(encoding="utf-8").strip()
            log(f"✨ {fqdn}: ISSUED/RENEWED successfully; actual lineage={lineage}")
            if args.staging:
                log("🧪 STAGING certificate only; not trusted and not deployed")
            return "issued"
        if "certificate not yet due" in output.lower():
            log(f"✅ {fqdn}: VALID / existing certificate retained; issuance skipped")
            return "retained"
        log(f"✔️ {fqdn}: command succeeded; no issuance event observed")
        return "completed"


def sleep_interruptibly(seconds):
    end = time.monotonic() + seconds
    while not STOP and time.monotonic() < end:
        time.sleep(min(1, max(0, end - time.monotonic())))


def main():
    args = parse_args()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    args.lock_file.parent.mkdir(parents=True, exist_ok=True)
    # Keep the lock descriptor open for the lifetime of the service.
    with args.lock_file.open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Another manager holds the lock; exiting", True)
            return 1
        print("\n" + "🌟" * 20, flush=True)
        print("  CERTBOT MANAGER LOADED", flush=True)
        print("🌟" * 20, flush=True)
        failures = {}  # Process-local: restart resets backoff. Not a rate-limit bypass.
        exit_code = 0
        while not STOP:
            summary = Counter()
            print("\n" + "█" * 70, flush=True)
            log(f"🔄 STARTING PROCESSING CYCLE (Freq: {args.frequency}m)")
            try:
                rows = read_rows(args.csv)  # Validate the whole CSV before any issuance.
                for row in rows:
                    if STOP:
                        break
                    fqdn = row[0]
                    count, retry_at = failures.get(fqdn, (0, 0))
                    if time.monotonic() < retry_at:
                        log(f"⏸️ {fqdn}: backoff; retry eligible in {int(retry_at - time.monotonic())}s")
                        summary["backoff"] += 1
                        continue
                    try:
                        outcome = run_certbot(row, args)
                    except Exception as exc:
                        # Avoid printing arbitrary exception text that could include credentials.
                        log(f"{fqdn}: manager error ({type(exc).__name__}); check configuration", True)
                        outcome = "failed"
                    summary[outcome] += 1
                    if outcome in ("failed", "deploy_failed"):
                        count += 1
                        wait = min(args.backoff_max, args.backoff_base * 2 ** min(count - 1, 16))
                        failures[fqdn] = (count, time.monotonic() + wait)
                        log(f"⏸️ {fqdn}: failure backoff={wait}s")
                    elif outcome != "interrupted":
                        failures.pop(fqdn, None)
                exit_code = int(bool(summary["failed"] or summary["deploy_failed"]))
            except (OSError, ValueError) as exc:
                log(f"CSV validation/read failed: {exc}", True)
                exit_code = 1
            labels = {"issued": "✨ Issued/renewed", "retained": "✅ Retained",
                      "failed": "❌ Failed", "deploy_failed": "📦❌ Deploy failed",
                      "backoff": "⏸️ Backoff", "completed": "✔️ Completed",
                      "interrupted": "🛑 Interrupted"}
            print("\n" + "█" * 70, flush=True)
            log("🏁 Cycle summary: " + (" | ".join(
                f"{labels.get(key, key)}: {value}"
                for key, value in sorted(summary.items())) or "no targets processed"))
            if args.once or STOP:
                break
            log(f"💤 Sleeping for {args.frequency} minutes")
            sleep_interruptibly(args.frequency * 60)
        log("🛑 Manager stopped. Goodbye!")
        return exit_code


if __name__ == "__main__":
    sys.exit(main())