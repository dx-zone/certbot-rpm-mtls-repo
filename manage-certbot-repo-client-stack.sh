#!/usr/bin/env bash

################################################################################
# 🏗️  ENTERPRISE PKI & RPM REPOSITORY STACK MANAGER
################################################################################
# PURPOSE:
#   Orchestrates the lifecycle of the secure RPM distribution pipeline.
#   Provides a human-friendly interface for initialization, deployment, 
#   auditing, and maintenance of the stack.
################################################################################

set -e

# --- 1. Colors & Emojis ---
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# --- 2. Logging Helpers ---
log() {
    local level="$1"; shift
    local timestamp; timestamp="$(date '+%H:%M:%S')"
    printf "[%s] %b%s%b\n" "$timestamp" "$level" "$*" "$NC"
}

log_info()    { log "${CYAN}ℹ️  " "$*"; }
log_success() { log "${GREEN}✅ " "$*"; }
log_warn()    { log "${YELLOW}⚠️  " "$*"; }
log_error()   { log "${RED}❌ " "$*"; }

# --- 3. Configuration & Pre-flight ---
load_env() {
    if [ -f .env ]; then
        set -a; source .env; set +a
    else
        log_error ".env file not found. Please create it first."
        exit 1
    fi

    if [ -z "${REPO_FQDN}" ]; then
        log_error "REPO_FQDN is not set in .env"
        exit 1
    fi
}

# --- 4. Usage Guide ---
usage() {
    printf "${BOLD}🏗️  RPM Repository Stack Manager${NC}\n"
    printf "Usage: $0 [-v] [TARGET] [SERVICE]\n\n"
    printf "Options:\n"
    printf "  -v       🔍 Verbose: Show every command being executed\n\n"
    printf "Available Targets:\n"
    printf "  init     🚀 Setup directories, fix permissions, and prepare PKI workspace\n"
    printf "  pki      🔐 Generate/Rotate mTLS client certificates (manual mode)\n"
    printf "  up       ⚡ Start the stack and wait for healthchecks\n"
    printf "  rebuild  🛠️  Recreate containers (or one SERVICE)\n"
    printf "  status   📊 Show container health and certificate info\n"
    printf "  check    🔍 Run diagnostic checks (validation sub-commands)\n"
    printf "  logs     📜 Follow all container logs\n"
    printf "  down     🛑 Stop and remove containers\n"
    printf "  purge    🧨 DELETE ALL DATA (volumes & bind mounts)\n"
    printf "  clean    🧹 Full wipe: Delete data, images, and orphans\n"
}

check_usage() {
    printf "Available Checks:\n"
    printf "  pipeline ✅ Run end-to-end PKI pipeline validation\n"
    printf "  mtls     🔐 Verify mTLS handshake and connectivity\n"
    printf "  certs    📜 Show current certificate status and expiry\n"
    printf "  repo     📦 Audit RPM repository metadata\n"
}

# --- 5. Implementation Targets ---

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
    # Ensure ownership and permissions for shared volumes
    sudo chown -R 1000:1000 ./datastore ./secrets/rpmrepo-secrets
    sudo chmod -R 775 ./datastore ./secrets/rpmrepo-secrets
    
    # Secure DNS .ini files
    if ls ./secrets/certbot-secrets/ini/*.ini >/dev/null 2>&1; then
        sudo chown 1000:1000 ./secrets/certbot-secrets/ini/*.ini
        sudo chmod 600 ./secrets/certbot-secrets/ini/*.ini
        log_success "Secured DNS .ini files (chmod 600)"
    fi

    log_success "Permissions and directory structure initialized."
    
    # Auto-generate PKI if missing
    if [ ! -f "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" ]; then
        log_info "No mTLS material detected. Triggering automatic PKI generation..."
        generate_pki
    fi
}

generate_pki() {
    log_info "Generating mTLS material (Internal CA & Client Identity)..."
    
    local gen_script="./secrets/rpmrepo-secrets/generate_mtls_client_ca.sh"
    
    if [ -f "$gen_script" ]; then
        # Run the script from its own directory to maintain relative pathing
        (
            cd "./secrets/rpmrepo-secrets"
            # Pass .env path relative to the script directory if needed
            # The script uses ENV_FILE="../../.env" so it should work from secrets/rpmrepo-secrets
            bash "./generate_mtls_client_ca.sh"
        )
        
        # Syncing client-ca.crt for Apache's expected path inside container
        # Note: In docker-compose.yml, ./secrets/rpmrepo-secrets/pki_mtls_material is mapped to /etc/httpd/certs
        # The entrypoint expects /etc/httpd/certs/client-ca.crt
        if [ -f "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" ]; then
            sudo cp "./secrets/rpmrepo-secrets/pki_mtls_material/ca.crt" "./secrets/rpmrepo-secrets/pki_mtls_material/client-ca.crt"
            log_info "Synchronized ca.crt to client-ca.crt for container parity."
        fi
        
        sudo chown -R 1000:1000 ./secrets/rpmrepo-secrets/pki_mtls_material
        log_success "mTLS material generated and secured."
    else
        log_error "PKI generation script not found: $gen_script"
        exit 1
    fi
}

up_stack() {
    log_info "Starting the RPM Repository stack..."
    docker compose up -d
    
    log_info "Waiting for services to be healthy..."
    # Simple wait loop for rpmrepo
    local max_retries=30
    local count=0
    while [ $count -lt $max_retries ]; do
        if docker compose ps rpmrepo | grep -q "running"; then
            log_success "Services are running."
            break
        fi
        printf "."
        sleep 2
        ((count++))
    done
    
    # Run the validation check if online
    printf "\n"
    if [ -f "./validate-pki-pipeline.sh" ]; then
        ./validate-pki-pipeline.sh || log_warn "Initial pipeline check failed (may need time for cert issuance)"
    fi
}

rebuild_stack() {
    local service_target="$1"

    if [ -n "$service_target" ]; then
        if ! docker compose config --services | grep -Fxq "$service_target"; then
            log_error "Unknown service for rebuild: $service_target"
            log_info "Available services:"
            docker compose config --services
            exit 1
        fi

        log_info "Rebuilding service: $service_target"
        docker compose up -d --build --force-recreate "$service_target"
        log_success "Service rebuilt and restarted: $service_target"
    else
        log_info "Performing a clean rebuild of the stack..."
        docker compose up -d --build --force-recreate --remove-orphans
        log_success "Stack rebuilt and restarted."
    fi
}

status_stack() {
    printf "\n${BOLD}📊 CONTAINER STATUS${NC}\n"
    docker compose ps
    
    printf "\n${BOLD}📜 CERTIFICATE AUDIT (${REPO_FQDN})${NC}\n"
    if [ -f "./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/fullchain.pem" ]; then
        openssl x509 -in "./datastore/certbot-data/letsencrypt/live/${REPO_FQDN}/fullchain.pem" -noout -issuer -dates
    else
        log_warn "Production certificate not yet issued (using fallback or pending)"
    fi

    printf "\n${BOLD}🔐 mTLS CLIENT IDENTITY (${CLIENT_NAME})${NC}\n"
    if [ -f "./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.crt" ]; then
        openssl x509 -in "./secrets/rpmrepo-secrets/pki_mtls_material/${CLIENT_NAME}.crt" -noout -subject -dates
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
        sudo rm -rf ./datastore/* ./secrets/rpmrepo-secrets/pki_mtls_material/*
        log_success "All persistent data purged."
    else
        log_info "Purge cancelled."
    fi
}

clean_stack() {
    log_warn "🧹 Full wipe initiated..."
    docker compose down -v --rmi all --remove-orphans
    sudo rm -rf ./datastore/* ./secrets/rpmrepo-secrets/pki_mtls_material/*
    log_success "System cleaned."
}

# --- 6. Argument Parsing & Main Logic ---

# Check for verbose flag
VERBOSE=false
if [[ "$1" == "-v" ]]; then
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
        rebuild_stack "$2"
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
        case "$2" in
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
                docker compose exec rpmrepo ls -R /var/www/html/repo/
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