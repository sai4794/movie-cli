#!/usr/bin/env bash
# install.sh — movie-cli installer
# Usage: curl -fsSL URL/install.sh | bash

set -euo pipefail

# ponytail: bash 4+ required (macOS ships 3.2)
if [[ ${BASH_VERSINFO[0]} -lt 4 ]]; then
    if [[ "$(uname)" == "Darwin" ]] && command -v brew &>/dev/null; then
        echo "[movie-cli] Installing bash 5 (you have $BASH_VERSION)..."
        brew install bash
        hash -r
        # Re-exec with brew bash if available (avoids curl|bash stdin issue)
        if [[ -x "/opt/homebrew/bin/bash" ]]; then
            exec /opt/homebrew/bin/bash "$0" "$@"
        elif command -v bash &>/dev/null && [[ "${BASH_VERSINFO[0]}" -ge 4 ]]; then
            exec bash "$0" "$@"
        fi
        echo "[movie-cli] WARNING: bash installed but not in PATH. Run: hash -r && bash $0"
        exit 1
    else
        echo "[movie-cli] ERROR: movie-cli requires bash 4+ (you have $BASH_VERSION)" >&2
        echo "[movie-cli] Install: brew install bash  (macOS) or apt install bash (Linux)" >&2
        exit 1
    fi
fi

REPO_URL="https://github.com/sai4794/movie-cli"
INSTALL_DIR="${HOME}/.local/bin"
SHARE_DIR="${HOME}/.local/share/movie-cli"
CONF_DIR="${HOME}/.config/movie-cli"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

info()  { printf "${GREEN}[movie-cli]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[movie-cli]${RESET} %s\n" "$*"; }
error() { printf "${RED}[movie-cli]${RESET} %s\n" "$*" >&2; }

# Detect if running on Termux
is_termux() {
    [[ -d "/data/data/com.termux" ]] || [[ -n "${TERMUX_VERSION:-}" ]]
}

# Get OS-specific package name
get_package_name() {
    local cmd="$1"
    local os_type="$2"
    local pm_type="$3"

    case "$os_type" in
        termux)
            case "$cmd" in
                openssl)    echo "openssl-tool" ;;
                python3)    echo "python" ;;
                *)          echo "$cmd" ;;
            esac
            ;;
        macos)
            case "$cmd" in
                python3)    echo "python3" ;;
                socat)      echo "socat" ;;
                *)          echo "$cmd" ;;
            esac
            ;;
        linux)
            case "$cmd" in
                python3)
                    case "$pm_type" in
                        apt)    echo "python3" ;;
                        dnf)    echo "python3" ;;
                        pacman) echo "python" ;;
                        *)      echo "python3" ;;
                    esac
                    ;;
                *)          echo "$cmd" ;;
            esac
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

# Verify a command exists
verify_command() {
    local cmd="$1"
    local package="${2:-$cmd}"
    if ! command -v "$cmd" &>/dev/null; then
        error "Missing: $cmd"
        error "Install with: pkg install $package (Termux) or apt install $package (Linux)"
        return 1
    fi
    return 0
}

# Detect package manager and install missing deps
install_deps() {
    local to_install=()
    local is_termux_env=0
    local pm_type=""

    # Detect OS
    local os_type="linux"
    if is_termux; then
        os_type="termux"
        is_termux_env=1
    elif [[ "$(uname)" == "Darwin" ]]; then
        os_type="macos"
    fi

    # Detect package manager
    local pm=""
    if command -v pkg &>/dev/null; then pm="pkg"; pm_type="pkg"       # Termux
    elif command -v apt-get &>/dev/null; then pm="apt-get"; pm_type="apt"
    elif command -v dnf &>/dev/null; then pm="dnf"; pm_type="dnf"
    elif command -v pacman &>/dev/null; then pm="pacman"; pm_type="pacman"
    elif command -v brew &>/dev/null; then pm="brew"; pm_type="brew"
    fi

    # Core dependencies (command names to check)
    local core_deps=(curl jq socat)
    if [[ "$os_type" == "termux" ]]; then
        core_deps+=(python openssl)
    else
        core_deps+=(python3 openssl)
    fi

    # Check each core dependency
    for cmd in "${core_deps[@]}"; do
        local pkg_name
        pkg_name=$(get_package_name "$cmd" "$os_type" "$pm_type")
        if ! command -v "$cmd" &>/dev/null; then
            to_install+=("$pkg_name")
        fi
    done

    # Optional: fzf
    command -v fzf &>/dev/null || to_install+=(fzf)

    (( ${#to_install[@]} == 0 )) && return 0

    if [[ -z "$pm" ]]; then
        warn "Cannot auto-install: ${to_install[*]}"
        warn "Install manually with your package manager."
        return 0
    fi

    info "Installing missing dependencies: ${to_install[*]}"
    case "$pm" in
        apt-get) sudo apt-get update -qq && sudo apt-get install -y -qq "${to_install[@]}" ;;
        dnf)     sudo dnf install -y -q "${to_install[@]}" ;;
        pacman)  sudo pacman -S --noconfirm "${to_install[@]}" ;;
        brew)
            (( ${#to_install[@]} > 0 )) && brew install "${to_install[@]}"
            ;;
        pkg)     pkg install -y "${to_install[@]}" ;;
    esac

    # Verify all dependencies after installation
    local failed=0
    for cmd in "${core_deps[@]}"; do
        local pkg_name
        pkg_name=$(get_package_name "$cmd" "$os_type" "$pm_type")
        if ! command -v "$cmd" &>/dev/null; then
            error "Failed to install: $cmd"
            error "Package: $pkg_name"
            error "Try: pkg install $pkg_name (Termux) or apt install $pkg_name (Linux)"
            failed=1
        fi
    done

    # Verify player (manual prerequisite - not auto-installed)
    local player_ok=0
    for cmd in mpv vlc iina; do
        command -v "$cmd" &>/dev/null && player_ok=1
    done
    if (( player_ok == 0 )); then
        warn "No media player found. Install one manually:"
        warn "  mpv:  sudo apt install mpv  |  brew install mpv  |  pkg install mpv"
        warn "  vlc:  sudo apt install vlc  |  brew install vlc"
    fi

    # Verify fzf
    if ! command -v fzf &>/dev/null; then
        warn "fzf not installed (optional). Install: pkg install fzf (Termux) or apt install fzf (Linux)"
    fi

    (( failed )) && exit 1
    return 0
}

# Update PATH in shell profile
update_path() {
    local install_dir="$1"
    local shell_profile=""

    # Determine which shell profile to update
    if [[ -n "${SHELL:-}" ]]; then
        case "$(basename "$SHELL")" in
            bash) shell_profile="$HOME/.bashrc" ;;
            zsh)  shell_profile="$HOME/.zshrc" ;;
            *)    shell_profile="$HOME/.bashrc" ;;
        esac
    else
        shell_profile="$HOME/.bashrc"
    fi

    # Check if already in PATH
    if [[ ":$PATH:" == *":$install_dir:"* ]]; then
        return 0
    fi

    # Check if already in profile (avoid duplicates)
    if [[ -f "$shell_profile" ]] && grep -qF "$install_dir" "$shell_profile"; then
        info "PATH already configured in $shell_profile"
        info "Run: source $shell_profile"
        return 0
    fi

    # Append to profile
    {
        echo ""
        echo "# movie-cli PATH"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    } >> "$shell_profile"

    info "Updated PATH in $shell_profile"
    info "Run: source $shell_profile"
    return 0
}

# Post-install verification
verify_installation() {
    local failed=0
    local is_termux_env=0

    if is_termux; then
        is_termux_env=1
    fi

    info "Verifying installation..."

    # Verify movie-cli
    if [[ -x "$INSTALL_DIR/movie-cli" ]]; then
        info "  ✓ movie-cli"
    else
        error "  ✗ movie-cli not found at $INSTALL_DIR/movie-cli"
        failed=1
    fi

    # Verify jq
    if command -v jq &>/dev/null; then
        info "  ✓ jq"
    else
        error "  ✗ jq not found"
        failed=1
    fi

    # Verify python (python3 on Linux/macOS, python on Termux)
    local python_cmd="python3"
    if (( is_termux_env )); then
        python_cmd="python"
    fi
    if command -v "$python_cmd" &>/dev/null; then
        info "  ✓ $python_cmd"
    else
        error "  ✗ $python_cmd not found"
        failed=1
    fi

    # Verify openssl
    if command -v openssl &>/dev/null; then
        info "  ✓ openssl"
    else
        error "  ✗ openssl not found"
        error "  Install: pkg install openssl-tool (Termux) or apt install openssl (Linux)"
        failed=1
    fi

    # Verify socat
    if command -v socat &>/dev/null; then
        info "  ✓ socat"
    else
        error "  ✗ socat not found"
        failed=1
    fi

    # Verify mpv (manual prerequisite)
    local player_ok=0
    for cmd in mpv vlc iina; do
        if command -v "$cmd" &>/dev/null; then
            info "  ✓ $cmd"
            player_ok=1
            break
        fi
    done
    if (( player_ok == 0 )); then
        warn "  ⚠ No media player found (install mpv, vlc, or iina manually)"
    fi

    # Verify fzf (optional)
    if command -v fzf &>/dev/null; then
        info "  ✓ fzf"
    else
        warn "  ⚠ fzf not found (optional)"
    fi

    (( failed )) && exit 1
    return 0
}

# Main install
main() {
    info "Installing movie-cli..."

    # Create directories
    mkdir -p "$INSTALL_DIR" "$SHARE_DIR" "$CONF_DIR"

    # Download and extract
    local tmp_dir
    tmp_dir=$(mktemp -d)

    info "Downloading..."
    curl -fsSL "$REPO_URL/archive/refs/heads/main.tar.gz" -o "$tmp_dir/release.tar.gz"

    info "Extracting..."
    tar xzf "$tmp_dir/release.tar.gz" -C "$tmp_dir"

    # Dynamically locate the extracted directory (e.g. movie-cli-main, movie-cli-0.1.0)
    local extracted_dir
    extracted_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [[ -n "$extracted_dir" ]] || { error "Extraction failed: no root directory found"; exit 1; }

    # Install files (rm first — cp -r nests instead of overwriting if target exists)
    cp "$extracted_dir/movie-cli" "$INSTALL_DIR/movie-cli"
    chmod +x "$INSTALL_DIR/movie-cli"
    rm -rf "${SHARE_DIR:?}/lib" "${SHARE_DIR:?}/plugins" "${SHARE_DIR:?}/config"
    cp -r "$extracted_dir/lib" "$SHARE_DIR/lib"
    cp -r "$extracted_dir/plugins" "$SHARE_DIR/plugins"
    cp -r "$extracted_dir/config" "$SHARE_DIR/config"

    # Update script to use SHARE_DIR portably (GNU vs BSD sed)
    if sed --version 2>/dev/null | grep -q GNU; then
        sed -i "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$SHARE_DIR\"|" "$INSTALL_DIR/movie-cli"
    else
        sed -i "" "s|SCRIPT_DIR=.*|SCRIPT_DIR=\"$SHARE_DIR\"|" "$INSTALL_DIR/movie-cli"
    fi

    # Create user config if not exists
    if [[ ! -f "$CONF_DIR/movie-cli.conf" ]]; then
        cp "$SHARE_DIR/config/default.conf" "$CONF_DIR/movie-cli.conf"
        chmod 600 "$CONF_DIR/movie-cli.conf"
    fi

    info "Installed to $INSTALL_DIR/movie-cli"
    info "Config at $CONF_DIR/movie-cli.conf"

    # Update PATH if needed
    update_path "$INSTALL_DIR"

    # Install dependencies
    install_deps

    # Post-install verification
    verify_installation

    info "Done! Run: movie-cli --help"

    # ponytail: cleanup temp dir while still in scope (local var)
    rm -rf "$tmp_dir" 2>/dev/null
}

main "$@"
