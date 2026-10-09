#!/usr/bin/env bash

################################################################################
# 🏗️  ENTERPRISE PKI & RPM REPOSITORY STACK MANAGER
#
# Rebuild safety:
#   1. Validate Compose configuration.
#   2. Build each replacement image SEQUENTIALLY before changing containers.
#   3. Copy the persistent datastore into a timestamped backup.
#   4. Recreate affected containers without deleting bind-mounted data.
#   5. Check startup status and report failures.
#
# CAUTION: A live file-level backup is not an atomic snapshot. For strict
# consistency, coordinate application writes or use filesystem snapshots.
# Backup covers ./datastore only; separately preserve secrets (including mTLS CA).
# Python 3 is required on the host to enumerate Compose build services.
# Before running a rebuild, ensure image changes and Python scripts are tested.
# Use: ./manage-certbot-repo-client-stack.sh rebuild [SERVICE]
#      ./manage-certbot-repo-client-stack.sh deploy [SERVICE]
################################################################################

set -e
set -o pipefail


# ==============================================================================
# 1. COLORS & EMOJIS
# ==============================================================================

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color


# ==============================================================================
# 2. LOGGING HELPERS
# ==============================================================================

log() {
    local level="$1"
    shift

    local timestamp
    timestamp="$(date '+%H:%M:%S')"

    printf "[%s] %b%s%b\n" "$timestamp" "$level" "$*" "$NC"
}

log_info() {
    log "${CYAN}ℹ️  " "$*"
}

log_success() {
    log "${GREEN}✅ " "$*"
}

log_warn() {
    log "${YELLOW}⚠️  " "$*"
}

log_error() {
    log "${RED}❌ " "$*"
}


# ==============================================================================
# 3. CONFIGURATION & PRE-FLIGHT
# ==============================================================================

load_env() {
    if [ -f .env ]; then
        set -a
        source .env
        set +a
    else
        log_error ".env file not found. Please create it first."
        exit 1
    fi

    if [ -z "${REPO_FQDN:-}" ]; then
        log_error "REPO_FQDN is not set in .env"
        exit 1
    fi
}


# ==============================================================================
# 4. USAGE GUIDES
# ==============================================================================

usage() {
    printf "${BOLD}🏗️  RPM Repository Stack Manager${NC}\n"
    printf "Usage: %s [-v] [TARGET] [SERVICE]\n\n" "$0"

    printf "Options:\n"
    printf "  -v       🔍 Verbose: Show every command being executed\n\n"

    printf "Available Targets:\n"
    printf "  init     🚀 Setup directories, fix permissions, and prepare PKI workspace\n"
    printf "  pki      🔐 Generate/Rotate mTLS client certificates (manual mode)\n"
    printf "  up       ⚡ Start the stack and wait for healthchecks\n"
    printf "  rebuild  🛠️  Sequential build, back up, then recreate stack (or one SERVICE)\n"
    printf "  deploy   🚀 Back up and deploy existing images WITHOUT rebuilding\n"
    printf "  status   📊 Show container health and certificate info\n"
    printf "  check    🔍 Run diagnostic checks (validation sub-commands)\n"
    printf "  logs     📜 Follow all container logs\n"
    printf "  down     🛑 Stop and remove containers\n"
    printf "  purge    🧨 DELETE ALL DATA (volumes & bind mounts)\n"
    printf "  clean    🧹 Full wipe: Delete data, images, and orphans\n"

    printf "\nExamples:\n"
    printf "  %s init\n" "$0"
    printf "  %s up\n" "$0"
    printf "  %s rebuild\n" "$0"
    printf "  %s rebuild certbot\n" "$0"
    printf "  %s deploy\n" "$0"
    printf "  %s deploy certbot\n" "$0"
    printf "  %s status\n" "$0"
    printf "  %s check pipeline\n" "$0"
    printf "  %s logs\n" "$0"
}

check_usage() {
    printf "Available Checks:\n"
    printf "  pipeline ✅ Run end-to-end PKI pipeline validation\n"
    printf "  mtls     🔐 Verify mTLS handshake and connectivity\n"
    printf "  certs    📜 Show current certificate status and expiry\n"
    printf "  repo     📦 Audit RPM repository metadata\n"
}


# ==============================================================================
# 5. IMPLEMENTATION TARGETS
# ==============================================================================

init_stack() {
    log_info "Preparing persistent host directories..."

    DIRS=(
        "./datastore/certbot-data/letsencrypt"
        "./datastore/rpmrepo-data/rpms"
        "./secrets/certbot-secrets/ini"
        "./secrets/rpmrepo-secrets/pki_mtls_material"
    )

    for dir in "${DIRS[@]}"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            log_info "  ➕ Created directory: $dir"
        else
            log_info "  ✔️  Directory exists: $dir"
        fi
    done

    log_info "Syncing security permissions with Container UID 1000..."

    # Ensure ownership and permissions for shared volumes.
    sudo chown -R 1000:1000 ./datastore ./secrets/rpmrepo-secrets
    # Do not chmod -R 775: private keys and stored TLS credentials need
    # restrictive permissions. Set directory traverse rights only.
    sudo find ./datastore ./secrets/rpmrepo-secrets -type d -exec chmod 750 {} +

    # Secure DNS .ini files.
    if ls ./secrets/certbot-secrets/ini/*.ini >/dev/null 2>&1; then
        sudo chown 1000:1000 ./secrets/certbot-secrets/ini/*.ini
        sudo chmod 600 ./secrets/certbot-secrets/ini/*.ini
        log_success "Secured DNS .ini files (chmod 600)"
    fi

    log_success "Permissions and directory structure initialized."

    # Auto-generate PKI if missing.
    if [ ! -f "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" ]; then
        log_info "No mTLS material detected. Triggering automatic PKI generation..."
        generate_pki
    fi
}


generate_pki() {
    log_info "Generating mTLS material (Internal CA & Client Identity)..."

    local gen_script="./secrets/rpmrepo-secrets/generate_mtls_client_ca.sh"

    if [ -f "$gen_script" ]; then

        # Run the script from its own directory to maintain relative pathing.
        (
            cd "./secrets/rpmrepo-secrets"

            # The script uses ENV_FILE="../../.env", so execution from this
            # directory preserves its expected relative paths.
            bash "./generate_mtls_client_ca.sh"
        )

        # Synchronize client-ca.crt for Apache's expected container path.
        #
        # docker-compose.yml maps:
        #
        #   ./secrets/rpmrepo-secrets/pki_mtls_material
        #
        # to:
        #
        #   /etc/httpd/certs
        #
        # The entrypoint expects:
        #
        #   /etc/httpd/certs/client-ca.crt
        #
        if [ -f "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" ]; then
            sudo cp \
                "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" \
                "./secrets/rpmrepo-secrets/pki_mtls_material/client-ca.crt"

            log_info "Synchronized ca.crt to client-ca.crt for container parity."
        fi

        sudo chown -R \
            1000:1000 \
            ./secrets/rpmrepo-secrets/pki_mtls_material

        log_success "mTLS material generated and secured."

    else
        log_error "PKI generation script not found: $gen_script"
        exit 1
    fi
}


backup_datastore() {
    local datastore="./datastore"
    local timestamp backup_dir
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    backup_dir="./datastore.BAK.${timestamp}"

    DATASTORE_BACKUP=""
    if [ ! -d "$datastore" ]; then
        log_warn "No datastore directory found; nothing to back up."
        return 0
    fi

    # Never move the live datastore: container bind mounts must remain valid.
    if [ -e "$backup_dir" ]; then
        log_error "Backup destination already exists: $backup_dir"
        return 1
    fi
    log_info "Copying persistent datastore to $backup_dir ..."
    sudo cp -a -- "$datastore" "$backup_dir"
    DATASTORE_BACKUP="$backup_dir"
    log_success "Datastore backup created: $DATASTORE_BACKUP"
    log_warn "This is a live file copy, not an atomic filesystem snapshot."
}


up_stack() {
    log_info "Starting the RPM Repository stack..."

    docker compose config --quiet
    docker compose up -d

    log_info "Waiting for services to be healthy..."

    # Simple wait loop for rpmrepo.
    local max_retries=30
    local count=0

    while [ "$count" -lt "$max_retries" ]; do
        if docker compose ps rpmrepo | grep -q "running"; then
            log_success "Services are running."
            break
        fi

        printf "."
        sleep 2
        count=$((count + 1))
    done

    printf "\n"
    if [ "$count" -ge "$max_retries" ]; then
        log_error "rpmrepo did not reach running state during the startup check."
        docker compose ps
        return 1
    fi

    # Run validation check if available.
    if [ -f "./validate-pki-pipeline.sh" ]; then
        ./validate-pki-pipeline.sh ||
            log_warn "Initial pipeline check failed (may need time for cert issuance)"
    fi
}


# Build each Compose service image separately. This avoids concurrent DNF
# downloads, which have repeatedly timed out in this environment.
# Services without a build specification are skipped (prebuilt images).
build_images_sequentially() {
    local service service_list
    local -a services=()

    if ! service_list="$(docker compose config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
for name, service in config.get("services", {}).items():
    if service.get("build"):
        print(name)
')"; then
        log_error "Could not determine Compose build services."
        return 1
    fi

    if [[ -n "$service_list" ]]; then
        mapfile -t services <<< "$service_list"
    fi

    if ((${#services[@]} == 0)); then
        log_info "No buildable services found; using existing images."
        return 0
    fi

    log_info "Building ${#services[@]} images sequentially: ${services[*]}"
    for service in "${services[@]}"; do
        log_info "Building $service ..."
        if ! docker compose --progress plain build "$service"; then
            log_error "Build failed for $service. Deployment aborted; running containers unchanged."
            return 1
        fi
        log_success "Image built: $service"
    done
}


# Deploy previously built images only. No image download/build is requested.
# Full-stack deployment requires a completed datastore backup first.
deploy_stack() {
    local service_target="${1:-}"
    DATASTORE_BACKUP=""

    log_info "Validating Docker Compose configuration..."
    docker compose config --quiet || return 1

    if [[ -n "$service_target" ]]; then
        if ! docker compose config --services | grep -Fxq -- "$service_target"; then
            log_error "Unknown service for deploy: $service_target"
            docker compose config --services
            return 1
        fi
        log_info "Deploying prebuilt image for service: $service_target"
        log_warn "Single-service deploy does not create a datastore backup; no persistent paths are intentionally modified."
        if ! docker compose up -d --no-build --no-deps --force-recreate "$service_target"; then
            log_error "Service deployment failed; inspect Compose status and logs."
            docker compose ps || true
            return 1
        fi
    else
        # Do not deploy without the existing datastore: this is not initialization.
        if [[ ! -d ./datastore ]]; then
            log_error "./datastore is missing; refusing deploy to avoid starting with empty certificate state."
            return 1
        fi
        backup_datastore || {
            log_error "Datastore backup failed; deployment aborted."
            return 1
        }
        log_info "Deploying existing images (no rebuild)..."
        if ! docker compose up -d --no-build --force-recreate; then
            log_error "Deployment failed; datastore remains on disk. Rollback may be required."
            log_info "Backup: ${DATASTORE_BACKUP:-none}"
            docker compose ps || true
            return 1
        fi
        log_success "Datastore backup: ${DATASTORE_BACKUP}"
    fi

    printf "\n%b📊 CURRENT STACK STATUS%b\n" "$BOLD" "$NC"
    docker compose ps || return 1
    log_success "Deploy command completed using prebuilt images."
    log_warn "Startup is not proof of health: run 'check pipeline', 'check mtls', and review logs."
    log_warn "mTLS secrets outside ./datastore are not included in the datastore backup."
}


rebuild_stack() {
    local service_target="${1:-}"
    DATASTORE_BACKUP=""

    log_info "Validating Docker Compose configuration..."
    docker compose config --quiet

    if [ -n "$service_target" ]; then
        if ! docker compose config --services | grep -Fxq -- "$service_target"; then
            log_error "Unknown service for rebuild: $service_target"
            docker compose config --services
            return 1
        fi
        log_info "Building image for service: $service_target"
        docker compose --progress plain build "$service_target" || {
            log_error "Image build failed; running service remains untouched."
            return 1
        }
        log_info "Recreating only service: $service_target"
        docker compose up -d --no-build --no-deps --force-recreate "$service_target" || {
            log_error "Service recreation failed; inspect Compose logs."
            return 1
        }
        docker compose ps
        log_success "Service image built and container recreated: $service_target"
        log_warn "Verify the service is healthy; container recreation alone is not a health check."
        return 0
    fi

    log_info "Building all images sequentially BEFORE modifying the running stack..."
    if ! build_images_sequentially; then
        log_error "Build failed. Existing containers and datastore were not changed by this rebuild."
        return 1
    fi

    backup_datastore || {
        log_error "Backup failed. Deployment aborted before container recreation."
        return 1
    }

    log_info "Starting/recreating stack using prebuilt images (preserving datastore)..."
    # No 'down' and no --build: named/bind-mounted state is preserved.
    # Do not remove orphaned containers automatically during this maintenance operation.
    if ! docker compose up -d --no-build --force-recreate; then
        log_error "Deployment failed. Datastore is preserved; rollback may be required."
        log_info "Saved backup: ${DATASTORE_BACKUP:-none}"
        docker compose ps || true
        return 1
    fi

    printf "\n%b📊 CURRENT STACK STATUS%b\n" "$BOLD" "$NC"
    docker compose ps
    log_success "Rebuild deployment commands completed."
    log_info "Datastore backup: ${DATASTORE_BACKUP:-none}"
    log_warn "Container startup does not prove application health; run 'check pipeline' and inspect logs."
    log_warn "mTLS secrets are outside ./datastore and were NOT included in this backup."
}


status_stack() {
    printf "\n${BOLD}📊 CONTAINER STATUS${NC}\n"

    docker compose ps

    printf "\n${BOLD}📜 CERTIFICATE AUDIT (${REPO_FQDN})${NC}\n"

    if [ -f "./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/fullchain.pem" ]; then

        openssl x509 \
            -in "./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/fullchain.pem" \
            -noout \
            -issuer \
            -dates

    else
        log_warn "Production certificate not yet issued (using fallback or pending)"
    fi

    printf "\n${BOLD}🔐 mTLS CLIENT IDENTITY (${CLIENT_NAME:-unknown})${NC}\n"

    if [ -n "${CLIENT_NAME:-}" ] &&
       [ -f "./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.crt" ]; then

        openssl x509 \
            -in "./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.crt" \
            -noout \
            -subject \
            -dates

    else
        log_warn "mTLS client certificate not found."
    fi
}


logs_stack() {
    docker compose logs -f
}


down_stack() {
    log_info "Stopping the stack..."

    docker compose down

    log_success "Stack stopped."
}


purge_stack() {
    log_warn "🧨 WARNING: THIS WILL DELETE ALL PERSISTENT DATA!"

    read -p "Are you sure you want to continue? (y/N) " -n 1 -r

    printf "\n"

    if [[ $REPLY =~ ^[Yy]$ ]]; then

        docker compose down -v

        sudo rm -rf \
            ./datastore/* \
            ./secrets/rpmrepo-secrets/pki_mtls_material/*

        log_success "All persistent data purged."

    else
        log_info "Purge cancelled."
    fi
}


clean_stack() {
    log_warn "🧹 Full wipe initiated..."

    docker compose down \
        -v \
        --rmi all \
        --remove-orphans

    sudo rm -rf \
        ./datastore/* \
        ./secrets/rpmrepo-secrets/pki_mtls_material/*

    log_success "System cleaned."
}


# ==============================================================================
# 6. ARGUMENT PARSING & MAIN LOGIC
# ==============================================================================

cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

VERBOSE=false

if [[ "${1:-}" == "-v" ]]; then
    VERBOSE=true
    set -x
    shift
fi


load_env


TARGET="${1:-usage}"


case "$TARGET" in

    init)
        init_stack
        ;;

    pki)
        generate_pki
        ;;

    up)
        up_stack
        ;;

    rebuild)
        rebuild_stack "${2:-}"
        ;;

    deploy)
        deploy_stack "${2:-}"
        ;;

    status)
        status_stack
        ;;

    logs)
        logs_stack
        ;;

    down)
        down_stack
        ;;

    purge)
        purge_stack
        ;;

    clean)
        clean_stack
        ;;

    check)
        case "${2:-}" in

            pipeline)
                ./validate-pki-pipeline.sh
                ;;

            mtls)
                ./rpmrepo-mtls-audit-rotation.sh
                ;;

            certs)
                ./verify-rpm-repo.sh
                ;;

            repo)
                docker compose exec \
                    rpmrepo \
                    ls -R /var/www/html/repo/
                ;;

            *)
                check_usage
                ;;

        esac
        ;;

    usage)
        usage
        ;;

    *)
        log_error "Unknown target: $TARGET"
        usage
        exit 1
        ;;

esac