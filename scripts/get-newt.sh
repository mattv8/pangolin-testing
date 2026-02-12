#!/bin/bash

# Get Newt (Fork) - Cross-platform installation script
# Installs Newt with DNS Authority features from mattv8/newt releases
# Usage: curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-newt.sh | bash
#
# The upstream script (fosrl/newt/get-newt.sh) uses the same structure.
# This fork version defaults to mattv8/newt releases but can be overridden:
#   NEWT_REPO=fosrl/newt curl -fsSL .../get-newt.sh | bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# GitHub repository info - binaries are released on the testing repo
REPO="${NEWT_REPO:-mattv8/pangolin-testing}"
GITHUB_API_URL="https://api.github.com/repos/${REPO}/releases"

# Auth header for private repos (set GITHUB_TOKEN env var)
AUTH_HEADER=""
if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_HEADER="Authorization: token ${GITHUB_TOKEN}"
fi

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

get_latest_version() {
    local latest_info

    if command -v curl >/dev/null 2>&1; then
        latest_info=$(curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$GITHUB_API_URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        latest_info=$(wget -qO- ${AUTH_HEADER:+--header="$AUTH_HEADER"} "$GITHUB_API_URL" 2>/dev/null)
    else
        print_error "Neither curl nor wget is available." >&2
        exit 1
    fi

    if [ -z "$latest_info" ]; then
        print_error "Failed to fetch latest version from ${REPO}" >&2
        exit 1
    fi

    # Store full release info for asset URL resolution
    RELEASE_INFO="$latest_info"

    local version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$version" ]; then
        print_error "Could not parse version from GitHub API response" >&2
        exit 1
    fi

    # Remove 'v' prefix if present
    version=$(echo "$version" | sed 's/^v//')
    echo "$version"
}

detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux*)     os="linux" ;;
        Darwin*)    os="darwin" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        FreeBSD*)   os="freebsd" ;;
        *)
            print_error "Unsupported operating system: $(uname -s)"
            exit 1
            ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        arm64|aarch64)  arch="arm64" ;;
        armv7l|armv6l)
            if [ "$os" = "linux" ]; then
                [ "$(uname -m)" = "armv6l" ] && arch="arm32v6" || arch="arm32"
            else
                arch="arm64"
            fi
            ;;
        riscv64)
            if [ "$os" = "linux" ]; then
                arch="riscv64"
            else
                print_error "RISC-V only supported on Linux"
                exit 1
            fi
            ;;
        *)
            print_error "Unsupported architecture: $(uname -m)"
            exit 1
            ;;
    esac

    echo "${os}_${arch}"
}

# Check for potential system conflicts (Port 53, systemd-resolved, etc.)
check_conflicts() {
    local platform="$1"

    # Only check on Linux as that's where systemd-resolved is common
    if [[ "$platform" == *"linux"* ]]; then
        print_status "Checking for potential system conflicts..."

        # Check if port 53 is in use
        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":53 "; then
                print_warning "Port 53 is already in use on this system."

                # Check if it's systemd-resolved
                if ss -tulnp | grep -q "systemd-resolve\|resolved"; then
                    print_warning "systemd-resolved appears to be occupying port 53."
                    print_warning "This will prevent Newt's DNS Authority from starting on 0.0.0.0:53."
                    print_warning "To fix this, you can either:"
                    print_warning "  1. Disable systemd-resolved: sudo systemctl disable --now systemd-resolved"
                    print_warning "  2. Bind Newt to a specific IP: newt --dns-bind <IP>"
                    print_warning "  3. Disable DNS Authority if not needed: newt --disable-dns-authority"
                else
                    print_warning "Another process is using port 53. DNS Authority may fail to start."
                    print_warning "If you don't need this feature, you can disable it with: newt --disable-dns-authority"
                fi
            fi
        fi

        # Check for WireGuard kernel module (optional for Newt but recommended for high performance)
        if [ -f /proc/modules ] && ! grep -q "^wireguard" /proc/modules; then
            print_status "WireGuard kernel module not loaded. Newt will use userspace implementation (netstack)."
            print_status "For better performance, you can load it with: sudo modprobe wireguard"
        fi

        # Check privileges for port 53
        if [ "$EUID" -ne 0 ]; then
            print_warning "Newt is being installed as a non-root user."
            print_warning "Note: Binding to port 53 (DNS) typically requires root privileges (sudo)."
        fi
    fi
}

get_install_dir() {
    if [ "$1" = "windows" ]; then
        echo "$HOME/bin"
    elif echo "$PATH" | grep -q "/usr/local/bin" && [ -w "/usr/local/bin" ] 2>/dev/null; then
        echo "/usr/local/bin"
    else
        echo "$HOME/.local/bin"
    fi
}

install_newt() {
    local platform="$1"
    local install_dir="$2"
    local binary_name="newt_${platform}"
    local exe_suffix=""

    [[ "$platform" == *"windows"* ]] && { binary_name="${binary_name}.exe"; exe_suffix=".exe"; }

    local temp_file="/tmp/newt${exe_suffix}"
    local final_path="${install_dir}/newt${exe_suffix}"

    # For private repos with GITHUB_TOKEN, use the API assets endpoint
    # For public repos, use the direct download URL
    local download_url=""
    if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "${RELEASE_INFO:-}" ]; then
        # Extract the asset API URL for this binary from the release info
        # The JSON has "url": "...api..." a few lines before "name": "binary_name"
        local asset_url=$(echo "$RELEASE_INFO" | grep -B5 "\"name\": \"${binary_name}\"" | grep '"url":.*releases/assets' | head -1 | sed 's/.*"url": *"\([^"]*\)".*/\1/')
        if [ -n "$asset_url" ]; then
            download_url="$asset_url"
            print_status "Downloading newt via API: ${binary_name}"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL -H "$AUTH_HEADER" -H "Accept: application/octet-stream" -L "$download_url" -o "$temp_file"
            elif command -v wget >/dev/null 2>&1; then
                wget -q --header="$AUTH_HEADER" --header="Accept: application/octet-stream" "$download_url" -O "$temp_file"
            else
                print_error "Neither curl nor wget is available."
                exit 1
            fi
        fi
    fi

    # Fallback: direct download URL (works for public repos)
    if [ ! -f "$temp_file" ] || [ ! -s "$temp_file" ]; then
        download_url="${BASE_URL}/${binary_name}"
        print_status "Downloading newt from ${download_url}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} -L "$download_url" -o "$temp_file"
        elif command -v wget >/dev/null 2>&1; then
            wget -q ${AUTH_HEADER:+--header="$AUTH_HEADER"} "$download_url" -O "$temp_file"
        else
            print_error "Neither curl nor wget is available."
            exit 1
        fi
    fi

    mkdir -p "$install_dir"
    mv "$temp_file" "$final_path"
    chmod +x "$final_path"

    print_status "newt installed to ${final_path}"

    if ! echo "$PATH" | grep -q "$install_dir"; then
        print_warning "Add ${install_dir} to your PATH:"
        print_warning "  export PATH=\"${install_dir}:\$PATH\""
    fi
}

verify_installation() {
    local install_dir="$1"
    local exe_suffix=""
    [[ "$PLATFORM" == *"windows"* ]] && exe_suffix=".exe"

    local newt_path="${install_dir}/newt${exe_suffix}"

    if [ -f "$newt_path" ] && [ -x "$newt_path" ]; then
        print_status "Installation successful!"
        print_status "newt version: $("$newt_path" --version 2>/dev/null || echo "unknown")"
        return 0
    else
        print_error "Installation failed."
        return 1
    fi
}

main() {
    print_status "Installing newt from ${REPO}..."

    print_status "Fetching latest release info..."

    # Fetch release info in main scope so RELEASE_INFO is available to install_newt
    if command -v curl >/dev/null 2>&1; then
        RELEASE_INFO=$(curl -fsSL ${AUTH_HEADER:+-H "$AUTH_HEADER"} "$GITHUB_API_URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        RELEASE_INFO=$(wget -qO- ${AUTH_HEADER:+--header="$AUTH_HEADER"} "$GITHUB_API_URL" 2>/dev/null)
    else
        print_error "Neither curl nor wget is available."
        exit 1
    fi

    if [ -z "$RELEASE_INFO" ]; then
        print_error "Failed to fetch release info from ${REPO}"
        exit 1
    fi

    VERSION=$(echo "$RELEASE_INFO" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    if [ -z "$VERSION" ]; then
        print_error "Could not parse version from GitHub API response"
        exit 1
    fi
    VERSION=$(echo "$VERSION" | sed 's/^v//')
    print_status "Latest version: ${VERSION}"

    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

    PLATFORM=$(detect_platform)
    print_status "Detected platform: ${PLATFORM}"

    # Check for conflicts
    check_conflicts "$PLATFORM"

    local os_part="${PLATFORM%%_*}"
    INSTALL_DIR=$(get_install_dir "$os_part")
    print_status "Install directory: ${INSTALL_DIR}"

    install_newt "$PLATFORM" "$INSTALL_DIR"

    if verify_installation "$INSTALL_DIR"; then
        print_status "newt is ready! Run 'newt --help' to get started"
    else
        exit 1
    fi
}

main "$@"
