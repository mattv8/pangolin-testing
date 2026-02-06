#!/bin/bash
# =============================================================================
# DNS Authority Feature - Build, Push & Deploy Script
# =============================================================================
# Builds Pangolin, Newt, and OLM from local source, pushes Docker images to
# Harbor, cross-compiles Go binaries, creates GitHub releases, and optionally
# deploys to the staging environment on proxy.visnovsky.us.
#
# Usage:
#   ./scripts/deploy.sh <command> [options]
#
# Commands:
#   build           Build Docker images for all components
#   push            Push Docker images to Harbor
#   compile         Cross-compile Newt and OLM Go binaries
#   release         Create GitHub releases with compiled binaries
#   deploy-staging  Deploy to the staging environment (Proxy DCA)
#   push-git        Push all repos to GitHub (origin)
#   sync-upstream   Fetch and rebase from upstream (fosrl/*)
#   all             Run: build → push → compile → release → deploy-staging
#   status          Show current state of all repos and images
#
# Environment Variables:
#   HARBOR_URL       Harbor registry URL (default: hub.docker.visnovsky.us)
#   HARBOR_PROJECT   Harbor project name (default: library)
#   GITHUB_USER      GitHub username (default: mattv8)
#   TAG              Image/release tag (default: dns-authority-dev)
#   PLATFORMS        Docker buildx platforms (default: linux/amd64,linux/arm64)
# =============================================================================

set -euo pipefail

# ==== Configuration ==========================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTING_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(dirname "$TESTING_DIR")"

# Component source directories
PANGOLIN_DIR="${REPO_ROOT}/pangolin"
NEWT_DIR="${REPO_ROOT}/newt"
OLM_DIR="${REPO_ROOT}/olm"

# Docker / Harbor
HARBOR_URL="${HARBOR_URL:-hub.docker.visnovsky.us}"
HARBOR_PROJECT="${HARBOR_PROJECT:-library}"
TAG="${TAG:-dns-authority-dev}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"

# GitHub
GITHUB_USER="${GITHUB_USER:-mattv8}"

# Staging
STAGING_HOST="proxy.visnovsky.us"

# Binary output
BIN_DIR="${TESTING_DIR}/bin"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ==== Helpers ================================================================

log()     { echo -e "${CYAN}[deploy]${NC} $1"; }
success() { echo -e "${GREEN}[deploy]${NC} $1"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $1"; }
error()   { echo -e "${RED}[deploy]${NC} $1"; }
header()  { echo -e "\n${BLUE}${BOLD}═══ $1 ═══${NC}\n"; }

confirm() {
    local msg="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}[deploy]${NC} ${msg} [y/N] ")" answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { error "Required command '$1' not found"; exit 1; }
}

# ==== Build Docker Images ====================================================

cmd_build() {
    header "Building Docker Images (tag: ${TAG})"

    require_cmd docker

    # Pangolin
    log "Building Pangolin..."
    docker build \
        --build-arg BUILD=oss \
        --build-arg DATABASE=sqlite \
        --build-arg VERSION="${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/pangolin:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/pangolin:latest" \
        -f "${PANGOLIN_DIR}/Dockerfile" \
        "${PANGOLIN_DIR}"
    success "Pangolin image built"

    # Newt
    log "Building Newt..."
    docker build \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/newt:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/newt:latest" \
        -f "${NEWT_DIR}/Dockerfile" \
        "${NEWT_DIR}"
    success "Newt image built"

    # OLM
    log "Building OLM..."
    docker build \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/olm:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/olm:latest" \
        -f "${OLM_DIR}/Dockerfile" \
        "${OLM_DIR}"
    success "OLM image built"

    success "All images built successfully"
}

# ==== Build Multi-Platform (buildx) ==========================================

cmd_build_multiarch() {
    header "Building Multi-Arch Docker Images (tag: ${TAG}, platforms: ${PLATFORMS})"

    require_cmd docker

    # Ensure buildx builder exists
    docker buildx inspect pangolin-builder >/dev/null 2>&1 || \
        docker buildx create --name pangolin-builder --use

    docker buildx use pangolin-builder

    # Pangolin
    log "Building Pangolin (multi-arch)..."
    docker buildx build \
        --platform "${PLATFORMS}" \
        --build-arg BUILD=oss \
        --build-arg DATABASE=sqlite \
        --build-arg VERSION="${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/pangolin:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/pangolin:latest" \
        -f "${PANGOLIN_DIR}/Dockerfile" \
        "${PANGOLIN_DIR}" \
        --push
    success "Pangolin multi-arch built and pushed"

    # Newt
    log "Building Newt (multi-arch)..."
    docker buildx build \
        --platform "${PLATFORMS}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/newt:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/newt:latest" \
        -f "${NEWT_DIR}/Dockerfile" \
        "${NEWT_DIR}" \
        --push
    success "Newt multi-arch built and pushed"

    # OLM
    log "Building OLM (multi-arch)..."
    docker buildx build \
        --platform "${PLATFORMS}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/olm:${TAG}" \
        -t "${HARBOR_URL}/${HARBOR_PROJECT}/olm:latest" \
        -f "${OLM_DIR}/Dockerfile" \
        "${OLM_DIR}" \
        --push
    success "OLM multi-arch built and pushed"

    success "All multi-arch images built and pushed"

    # Sign with cosign if available
    if command -v cosign >/dev/null 2>&1; then
        header "Signing Images with Cosign"
        local cosign_key="${COSIGN_KEY:-}"
        if [ -z "$cosign_key" ]; then
            warn "Set COSIGN_KEY to your private key path to sign images."
            warn "  COSIGN_KEY=~/cosign.key ./scripts/deploy.sh build-multiarch"
        else
            for component in pangolin newt olm; do
                local image="${HARBOR_URL}/${HARBOR_PROJECT}/${component}:${TAG}"
                log "Signing ${image}..."
                cosign sign --key "${cosign_key}" --yes "${image}" || \
                    warn "Failed to sign ${image}"
            done
            success "All images signed"
        fi
    else
        warn "cosign not installed — skipping image signing"
    fi
}

# ==== Push to Harbor ==========================================================

cmd_push() {
    header "Pushing Docker Images to Harbor (${HARBOR_URL})"

    require_cmd docker

    # Ensure logged in
    log "Checking Harbor authentication..."
    if ! docker login "${HARBOR_URL}" 2>/dev/null; then
        warn "Not logged in to Harbor. Run: docker login ${HARBOR_URL}"
        exit 1
    fi

    for component in pangolin newt olm; do
        local image="${HARBOR_URL}/${HARBOR_PROJECT}/${component}"
        log "Pushing ${image}:${TAG}..."
        docker push "${image}:${TAG}"
        docker push "${image}:latest"
        success "${component} pushed"
    done

    success "All images pushed to Harbor"
}

# ==== Cross-Compile Go Binaries ===============================================

cmd_compile() {
    header "Cross-Compiling Newt & OLM Binaries"

    require_cmd go

    mkdir -p "${BIN_DIR}"

    # Define targets (subset matching the Makefiles)
    local targets=(
        "linux:amd64:"
        "linux:arm64:"
        "linux:arm:7"
        "linux:arm:6"
        "darwin:amd64:"
        "darwin:arm64:"
    )

    # Newt
    log "Compiling Newt..."
    pushd "${NEWT_DIR}" > /dev/null
    for target in "${targets[@]}"; do
        IFS=':' read -r goos goarch goarm <<< "$target"
        local suffix="${goos}_${goarch}"
        [[ -n "$goarm" ]] && suffix="${goos}_arm32$([ "$goarm" = "6" ] && echo "v6" || echo "")"

        local env="CGO_ENABLED=0 GOOS=${goos} GOARCH=${goarch}"
        [[ -n "$goarm" ]] && env="${env} GOARM=${goarm}"

        log "  newt_${suffix}"
        eval "${env}" go build -ldflags="-s -w" -o "${BIN_DIR}/newt_${suffix}" .
    done
    popd > /dev/null
    success "Newt binaries compiled"

    # OLM
    log "Compiling OLM..."
    pushd "${OLM_DIR}" > /dev/null
    for target in "${targets[@]}"; do
        IFS=':' read -r goos goarch goarm <<< "$target"
        local suffix="${goos}_${goarch}"
        [[ -n "$goarm" ]] && suffix="${goos}_arm32$([ "$goarm" = "6" ] && echo "v6" || echo "")"

        local env="CGO_ENABLED=0 GOOS=${goos} GOARCH=${goarch}"
        [[ -n "$goarm" ]] && env="${env} GOARM=${goarm}"

        log "  olm_${suffix}"
        eval "${env}" go build -ldflags="-s -w" -o "${BIN_DIR}/olm_${suffix}" .
    done
    popd > /dev/null
    success "OLM binaries compiled"

    log "Binaries in ${BIN_DIR}:"
    ls -lh "${BIN_DIR}/"
}

# ==== GitHub Release ==========================================================

cmd_release() {
    header "Creating GitHub Releases (tag: ${TAG})"

    require_cmd gh

    if [ ! -d "${BIN_DIR}" ] || [ -z "$(ls -A "${BIN_DIR}/" 2>/dev/null)" ]; then
        warn "No binaries found in ${BIN_DIR}. Run 'compile' first."
        exit 1
    fi

    local release_notes="DNS Authority feature development build.

Components:
- Newt (site agent with DNS Authority & Auth Proxy)
- OLM (redundant NS client)

Built from local branches on $(date -u +"%Y-%m-%d %H:%M UTC").

Install:
\`\`\`bash
# Newt
curl -fsSL https://raw.githubusercontent.com/${GITHUB_USER}/pangolin-testing/main/scripts/get-newt.sh | bash

# OLM
curl -fsSL https://raw.githubusercontent.com/${GITHUB_USER}/pangolin-testing/main/scripts/get-olm.sh | bash
\`\`\`"

    # Release Newt binaries
    log "Creating Newt release..."
    local newt_bins=("${BIN_DIR}"/newt_*)
    if [ ${#newt_bins[@]} -gt 0 ]; then
        pushd "${NEWT_DIR}" > /dev/null
        gh release delete "${TAG}" --yes 2>/dev/null || true
        gh release create "${TAG}" \
            --title "Newt ${TAG}" \
            --notes "${release_notes}" \
            --prerelease \
            "${newt_bins[@]}"
        popd > /dev/null
        success "Newt release created: https://github.com/${GITHUB_USER}/newt/releases/tag/${TAG}"
    fi

    # Release OLM binaries
    log "Creating OLM release..."
    local olm_bins=("${BIN_DIR}"/olm_*)
    if [ ${#olm_bins[@]} -gt 0 ]; then
        pushd "${OLM_DIR}" > /dev/null
        gh release delete "${TAG}" --yes 2>/dev/null || true
        gh release create "${TAG}" \
            --title "OLM ${TAG}" \
            --notes "${release_notes}" \
            --prerelease \
            "${olm_bins[@]}"
        popd > /dev/null
        success "OLM release created: https://github.com/${GITHUB_USER}/olm/releases/tag/${TAG}"
    fi

    success "GitHub releases created"
}

# ==== Push to GitHub ==========================================================

cmd_push_git() {
    header "Pushing All Repos to GitHub (origin)"

    for dir in "${PANGOLIN_DIR}" "${NEWT_DIR}" "${OLM_DIR}"; do
        local name=$(basename "$dir")
        local branch=$(cd "$dir" && git branch --show-current)
        log "Pushing ${name} (branch: ${branch})..."
        (cd "$dir" && git push origin "${branch}")
        success "${name} pushed"
    done

    success "All repos pushed to origin (${GITHUB_USER}/*)"
}

# ==== Sync with Upstream ======================================================

cmd_sync_upstream() {
    header "Syncing with Upstream (fosrl/*)"

    for dir in "${PANGOLIN_DIR}" "${NEWT_DIR}" "${OLM_DIR}"; do
        local name=$(basename "$dir")
        local branch=$(cd "$dir" && git branch --show-current)
        log "Fetching upstream for ${name}..."
        (cd "$dir" && git fetch upstream)
        log "Rebasing ${name} onto upstream/main..."
        (cd "$dir" && git rebase upstream/main) || {
            error "Rebase conflict in ${name}. Resolve manually then re-run."
            (cd "$dir" && git rebase --abort)
            return 1
        }
        success "${name} synced with upstream"
    done

    success "All repos synced. Run 'push-git' to push rebased branches."
}

# ==== Deploy to Staging =======================================================

cmd_deploy_staging() {
    header "Deploying to Staging (${STAGING_HOST})"

    require_cmd ssh

    local pangolin_image="${HARBOR_URL}/${HARBOR_PROJECT}/pangolin:${TAG}"

    log "Target: ${STAGING_HOST}"
    log "Pangolin image: ${pangolin_image}"
    echo ""

    if ! confirm "Deploy to staging?"; then
        warn "Aborted."
        return
    fi

    # Update the pangolin image on staging
    log "Pulling new Pangolin image on staging..."
    ssh "root@${STAGING_HOST}" bash -s <<-DEPLOY_EOF
        set -e
        cd /root

        echo "[deploy] Logging in to Harbor..."
        docker login ${HARBOR_URL} 2>/dev/null || true

        echo "[deploy] Pulling ${pangolin_image}..."
        docker pull ${pangolin_image}

        echo "[deploy] Updating docker-compose.yml..."
        # Update image reference in docker-compose.yml
        sed -i "s|image:.*pangolin:.*|image: ${pangolin_image}|" docker-compose.yml

        echo "[deploy] Restarting Pangolin..."
        docker compose up -d pangolin

        echo "[deploy] Waiting for health..."
        sleep 5
        for i in \$(seq 1 30); do
            if curl -sf http://localhost:3001/api/v1/ > /dev/null 2>&1; then
                echo "[deploy] Pangolin is healthy!"
                exit 0
            fi
            echo "[deploy] Waiting... (\$i/30)"
            sleep 3
        done
        echo "[deploy] WARNING: Health check timed out"
        exit 1
DEPLOY_EOF

    success "Staging deployment complete"
}

# ==== Status ==================================================================

cmd_status() {
    header "Repository & Image Status"

    echo -e "${BOLD}Git Repositories:${NC}"
    for dir in "${PANGOLIN_DIR}" "${NEWT_DIR}" "${OLM_DIR}"; do
        local name=$(basename "$dir")
        local branch=$(cd "$dir" && git branch --show-current)
        local dirty=$(cd "$dir" && git status --porcelain | wc -l)
        local ahead=$(cd "$dir" && git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo "?")
        local status_icon="✅"
        [[ "$dirty" -gt 0 ]] && status_icon="📝"

        printf "  ${status_icon} %-12s branch=%-20s dirty=%-4s ahead=%s\n" \
            "${name}" "${branch}" "${dirty}" "${ahead}"
    done

    echo ""
    echo -e "${BOLD}Docker Images (local):${NC}"
    for component in pangolin newt olm; do
        local image="${HARBOR_URL}/${HARBOR_PROJECT}/${component}:${TAG}"
        if docker image inspect "$image" > /dev/null 2>&1; then
            local size=$(docker image inspect "$image" --format '{{.Size}}' | awk '{printf "%.0fMB", $1/1024/1024}')
            local created=$(docker image inspect "$image" --format '{{.Created}}' | cut -dT -f1)
            printf "  ✅ %-40s  %s  %s\n" "$image" "$size" "$created"
        else
            printf "  ❌ %-40s  (not built)\n" "$image"
        fi
    done

    echo ""
    echo -e "${BOLD}Compiled Binaries:${NC}"
    if [ -d "${BIN_DIR}" ] && [ -n "$(ls -A "${BIN_DIR}/" 2>/dev/null)" ]; then
        ls -lh "${BIN_DIR}/" | tail -n +2 | awk '{printf "  📦 %-30s %s\n", $NF, $5}'
    else
        echo "  (none — run './scripts/deploy.sh compile')"
    fi

    echo ""
    echo -e "${BOLD}Configuration:${NC}"
    printf "  Harbor:    %s/%s\n" "${HARBOR_URL}" "${HARBOR_PROJECT}"
    printf "  GitHub:    %s\n" "${GITHUB_USER}"
    printf "  Tag:       %s\n" "${TAG}"
    printf "  Staging:   %s\n" "${STAGING_HOST}"
}

# ==== All =====================================================================

cmd_all() {
    header "Full Build → Push → Compile → Release → Deploy Pipeline"
    confirm "Run the full pipeline?" || { warn "Aborted."; return; }

    cmd_build
    cmd_push
    cmd_compile
    cmd_release
    cmd_deploy_staging

    success "Full pipeline complete!"
}

# ==== Usage ===================================================================

usage() {
    echo ""
    echo -e "${BOLD}DNS Authority Feature — Build & Deploy${NC}"
    echo ""
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  build            Build Docker images (single-arch, local)"
    echo "  build-multiarch  Build & push multi-arch images via buildx"
    echo "  push             Push Docker images to Harbor"
    echo "  compile          Cross-compile Newt & OLM Go binaries"
    echo "  release          Create GitHub pre-releases with binaries"
    echo "  deploy-staging   Deploy Pangolin to staging server"
    echo "  push-git         Push all repos to GitHub (origin)"
    echo "  sync-upstream    Fetch & rebase all repos from upstream"
    echo "  status           Show repo, image, and binary status"
    echo "  all              Full pipeline: build → push → compile → release → deploy"
    echo ""
    echo "Environment:"
    echo "  HARBOR_URL       Registry URL       (current: ${HARBOR_URL})"
    echo "  HARBOR_PROJECT   Registry project    (current: ${HARBOR_PROJECT})"
    echo "  GITHUB_USER      GitHub username     (current: ${GITHUB_USER})"
    echo "  TAG              Build/release tag   (current: ${TAG})"
    echo "  PLATFORMS        Buildx platforms    (current: ${PLATFORMS})"
    echo ""
    echo "Examples:"
    echo "  $0 build                           # Build images locally"
    echo "  $0 compile && $0 release           # Compile Go bins & release to GitHub"
    echo "  TAG=v0.2.0 $0 all                  # Full pipeline with custom tag"
    echo "  $0 push-git                        # Push all repos to origin"
    echo "  $0 sync-upstream && $0 push-git    # Sync upstream then push"
    echo ""
}

# ==== Main ====================================================================

case "${1:-help}" in
    build)           cmd_build ;;
    build-multiarch) cmd_build_multiarch ;;
    push)            cmd_push ;;
    compile)         cmd_compile ;;
    release)         cmd_release ;;
    deploy-staging)  cmd_deploy_staging ;;
    deploy)          cmd_deploy_staging ;;
    push-git)        cmd_push_git ;;
    sync-upstream)   cmd_sync_upstream ;;
    sync)            cmd_sync_upstream ;;
    status)          cmd_status ;;
    all)             cmd_all ;;
    help|--help|-h)  usage ;;
    *)
        error "Unknown command: $1"
        usage
        exit 1
        ;;
esac
