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

# Detect package manager and install missing deps
install_deps() {
    local to_install=()

    # Core: curl, jq, python3, openssl, socat
    for cmd in curl jq python3 openssl socat; do
        command -v "$cmd" &>/dev/null || to_install+=("$cmd")
    done

    # Player: mpv preferred
    local player_found=0
    for cmd in mpv vlc iina; do
        command -v "$cmd" &>/dev/null && player_found=1
    done
    (( player_found == 0 )) && to_install+=(mpv)

    # Optional: fzf
    command -v fzf &>/dev/null || to_install+=(fzf)

    (( ${#to_install[@]} == 0 )) && return 0

    # Detect package manager (Termux: pkg before apt-get, both exist)
    local pm=""
    if command -v pkg &>/dev/null; then pm="pkg"  # Termux
    elif command -v apt-get &>/dev/null; then pm="apt"
    elif command -v dnf &>/dev/null; then pm="dnf"
    elif command -v pacman &>/dev/null; then pm="pacman"
    elif command -v brew &>/dev/null; then pm="brew"
    fi

    if [[ -z "$pm" ]]; then
        warn "Cannot auto-install: ${to_install[*]}"
        warn "Install manually with your package manager."
        return 0
    fi

    info "Installing missing dependencies: ${to_install[*]}"
    case "$pm" in
        apt)    sudo apt-get update -qq && sudo apt-get install -y -qq "${to_install[@]}" ;;
        dnf)    sudo dnf install -y -q "${to_install[@]}" ;;
        pacman) sudo pacman -S --noconfirm "${to_install[@]}" ;;
        brew)
            # ponytail: mpv needs full Xcode on macOS, not just CLT
            local brew_list=() need_mpv=0
            for dep in "${to_install[@]}"; do
                [[ "$dep" == "mpv" ]] && { need_mpv=1; continue; }
                brew_list+=("$dep")
            done
            (( ${#brew_list[@]} > 0 )) && brew install "${brew_list[@]}"
            if (( need_mpv )); then
                if xcode-select -p &>/dev/null && [[ -d "/Applications/Xcode.app" ]]; then
                    brew install mpv
                elif xcode-select -p &>/dev/null; then
                    warn "mpv needs full Xcode.app (not just CLT)."
                    warn "Install Xcode from App Store, then: brew install mpv"
                else
                    warn "mpv needs Xcode. Install from App Store, then: brew install mpv"
                fi
            fi
            ;;
        pkg)    pkg install -y "${to_install[@]}" ;;
    esac
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

    # Check PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        warn "$INSTALL_DIR is not in your PATH."
        warn "Add this to your shell profile:"
        warn "  export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi

    # Check dependencies
    install_deps

    info "Done! Run: movie-cli --help"

    # ponytail: cleanup temp dir while still in scope (local var)
    rm -rf "$tmp_dir" 2>/dev/null
}

main "$@"
