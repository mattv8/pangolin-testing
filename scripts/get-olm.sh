#!/bin/bash

# Get OLM (Fork) - Cross-platform installation script
# Installs OLM with DNS Authority features from mattv8/olm releases
# Usage: curl -fsSL https://raw.githubusercontent.com/mattv8/pangolin-testing/main/scripts/get-olm.sh | bash
#
# The upstream script (fosrl/olm/get-olm.sh) uses the same structure.
# This fork version defaults to mattv8/olm releases but can be overridden:
#   OLM_REPO=fosrl/olm curl -fsSL .../get-olm.sh | bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# GitHub repository info - binaries are released on the testing repo
REPO="${OLM_REPO:-mattv8/pangolin-testing}"
GITHUB_API_URL="https://api.github.com/repos/${REPO}/releases/latest"

print_status()  { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

get_latest_version() {
    local latest_info

    if command -v curl >/dev/null 2>&1; then
        latest_info=$(curl -fsSL "$GITHUB_API_URL" 2>/dev/null)
    elif command -v wget >/dev/null 2>&1; then
        latest_info=$(wget -qO- "$GITHUB_API_URL" 2>/dev/null)
    else
        print_error "Neither curl nor wget is available." >&2
        exit 1
    fi

    if [ -z "$latest_info" ]; then
        print_error "Failed to fetch latest version from ${REPO}" >&2
        exit 1
    fi

    local version=$(echo "$latest_info" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')

    if [ -z "$version" ]; then
        print_error "Could not parse version from GitHub API response" >&2
        exit 1
    fi

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

get_install_dir() {
    local platform="$1"

    if [[ "$platform" == *"windows"* ]]; then
        echo "$HOME/bin"
    elif [ -d "/usr/local/bin" ]; then
        echo "/usr/local/bin"
    elif [ -d "/usr/bin" ]; then
        echo "/usr/bin"
    else
        echo "$HOME/.local/bin"
    fi
}

need_sudo() {
    local install_dir="$1"
    if [[ "$install_dir" == "/usr/local/bin" || "$install_dir" == "/usr/bin" ]]; then
        [ ! -w "$install_dir" ] 2>/dev/null && return 0
    fi
    return 1
}

install_olm() {
    local platform="$1"
    local install_dir="$2"
    local binary_name="olm_${platform}"
    local exe_suffix=""

    [[ "$platform" == *"windows"* ]] && { binary_name="${binary_name}.exe"; exe_suffix=".exe"; }

    local download_url="${BASE_URL}/${binary_name}"
    local temp_file="/tmp/olm${exe_suffix}"
    local final_path="${install_dir}/olm${exe_suffix}"

    print_status "Downloading olm from ${download_url}"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$download_url" -o "$temp_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$download_url" -O "$temp_file"
    else
        print_error "Neither curl nor wget is available."
        exit 1
    fi

    local use_sudo=""
    if need_sudo "$install_dir"; then
        print_status "Administrator privileges required for system-wide installation"
        command -v sudo >/dev/null 2>&1 || { print_error "sudo required but not available"; exit 1; }
        use_sudo="sudo"
    fi

    if [ -n "$use_sudo" ]; then
        $use_sudo mkdir -p "$install_dir"
        $use_sudo mv "$temp_file" "$final_path"
        $use_sudo chmod +x "$final_path"
    else
        mkdir -p "$install_dir"
        mv "$temp_file" "$final_path"
        chmod +x "$final_path"
    fi

    print_status "olm installed to ${final_path}"

    if [[ "$install_dir" != "/usr/local/bin" && "$install_dir" != "/usr/bin" ]]; then
        if ! echo "$PATH" | grep -q "$install_dir"; then
            print_warning "Add ${install_dir} to your PATH:"
            print_warning "  export PATH=\"${install_dir}:\$PATH\""
        fi
    fi
}

verify_installation() {
    local install_dir="$1"
    local exe_suffix=""
    [[ "$PLATFORM" == *"windows"* ]] && exe_suffix=".exe"

    local olm_path="${install_dir}/olm${exe_suffix}"

    if [ -f "$olm_path" ] && [ -x "$olm_path" ]; then
        print_status "Installation successful!"
        print_status "olm version: $("$olm_path" --version 2>/dev/null || echo "unknown")"
        return 0
    else
        print_error "Installation failed."
        return 1
    fi
}

main() {
    print_status "Installing olm from ${REPO}..."

    print_status "Fetching latest version..."
    VERSION=$(get_latest_version)
    print_status "Latest version: ${VERSION}"

    BASE_URL="https://github.com/${REPO}/releases/download/${VERSION}"

    PLATFORM=$(detect_platform)
    print_status "Detected platform: ${PLATFORM}"

    INSTALL_DIR=$(get_install_dir "$PLATFORM")
    print_status "Install directory: ${INSTALL_DIR}"

    if [[ "$INSTALL_DIR" == "/usr/local/bin" || "$INSTALL_DIR" == "/usr/bin" ]]; then
        print_status "Installing system-wide for sudo access"
    fi

    install_olm "$PLATFORM" "$INSTALL_DIR"

    if verify_installation "$INSTALL_DIR"; then
        print_status "olm is ready! Run 'olm --help' or 'sudo olm --help' to get started"
    else
        exit 1
    fi
}

main "$@"
