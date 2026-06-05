#!/bin/bash
# DNS Authority Test Stack - Setup & Management Script
# Run this from the testing/ directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() {
    echo -e "${CYAN}[test-stack]${NC} $1"
}

success() {
    echo -e "${GREEN}[test-stack]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[test-stack]${NC} $1"
}

error() {
    echo -e "${RED}[test-stack]${NC} $1"
}

# Build services
build() {
    log "Building test stack services..."

    # Build all services (Newt builds from ../newt context)
    docker compose build --parallel
    success "Build complete"
}

# Bootstrap test data into Pangolin
bootstrap() {
    log "Bootstrapping test data..."
    bash "$SCRIPT_DIR/scripts/bootstrap.sh"
    success "Bootstrap complete"
}

# Start services
start() {
    log "Starting test stack..."
    docker compose up -d

    log "Waiting for services to be healthy..."
    sleep 5

    # Check health
    local retries=30
    while [ $retries -gt 0 ]; do
        if docker compose ps | grep -q "unhealthy\|starting"; then
            log "Waiting for services... ($retries attempts left)"
            sleep 2
            ((retries--))
        else
            break
        fi
    done

    docker compose ps
    bootstrap
    success "Test stack started"
}

# Stop services
stop() {
    log "Stopping test stack..."
    docker compose down
    success "Test stack stopped"
}

# Clean up everything
clean() {
    log "Cleaning up test stack..."
    docker compose down -v --remove-orphans
    rm -rf results/*.json results/*.log 2>/dev/null || true
    success "Cleanup complete"
}

# View logs
logs() {
    local service="${1:-}"
    if [ -n "$service" ]; then
        docker compose logs -f "$service"
    else
        docker compose logs -f
    fi
}

# Run tests
test() {
    log "Running tests in test-client container..."
    bootstrap
    docker compose exec test-client bash /scripts/run-tests.sh
}

# Interactive shell in test client
shell() {
    log "Opening shell in test-client container..."
    docker compose exec test-client bash
}

# Quick DNS test
dns() {
    local domain="${1:-app.test.local}"
    log "Testing DNS resolution for $domain..."
    docker compose exec test-client dig @172.28.0.10 "$domain" A
}

# Status check
status() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}               Test Stack Status                           ${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
    echo ""
    docker compose ps
    echo ""

    # Quick health checks
    log "Quick connectivity tests:"

    # Pangolin
    if docker compose exec -T test-client curl -s --connect-timeout 2 http://pangolin:3001/api/v1/health > /dev/null 2>&1; then
        success "  Pangolin API: ✅ UP"
    else
        error "  Pangolin API: ❌ DOWN"
    fi

    # Newt DNS
    if docker compose exec -T test-client nc -z -w2 172.28.0.10 53 2>/dev/null; then
        success "  Newt DNS: ✅ UP"
    else
        error "  Newt DNS: ❌ DOWN"
    fi

    # Backend
    if docker compose exec -T test-client curl -s --connect-timeout 2 http://172.28.0.20/health > /dev/null 2>&1; then
        success "  Primary Backend: ✅ UP"
    else
        error "  Primary Backend: ❌ DOWN"
    fi

    echo ""
}

# Show usage
usage() {
    echo ""
    echo "DNS Authority & Auth Proxy Test Stack"
    echo ""
    echo "Usage: $0 <command> [args]"
    echo ""
    echo "Commands:"
    echo "  build       Build all Docker images"
    echo "  bootstrap   Seed Pangolin test data"
    echo "  start       Start the test stack"
    echo "  stop        Stop the test stack"
    echo "  restart     Restart the test stack"
    echo "  clean       Remove all containers, volumes and build artifacts"
    echo "  logs [svc]  View logs (optionally for specific service)"
    echo "  test        Run the test suite"
    echo "  shell       Open a shell in the test-client container"
    echo "  dns [dom]   Quick DNS test (default: app.test.local)"
    echo "  status      Show stack status and health"
    echo "  help        Show this help"
    echo ""
    echo "Quick Start:"
    echo "  $0 build && $0 start && $0 test"
    echo ""
}

# Main
case "${1:-help}" in
    build)
        build
        ;;
    bootstrap)
        bootstrap
        ;;
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    clean)
        clean
        ;;
    logs)
        logs "$2"
        ;;
    test)
        test
        ;;
    shell)
        shell
        ;;
    dns)
        dns "$2"
        ;;
    status)
        status
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
