#!/usr/bin/env bash
# uninstall.sh — movie-cli uninstaller

set -euo pipefail

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

confirm() {
    local prompt="${1:-Continue?}"
    printf '%s [y/N] ' "$prompt"
    read -r answer < /dev/tty
    [[ "$answer" =~ ^[Yy]$ ]]
}

main() {
    info "Uninstalling movie-cli..."

    # Remove executable
    if [[ -f "$INSTALL_DIR/movie-cli" ]]; then
        rm -f "$INSTALL_DIR/movie-cli"
        info "Removed $INSTALL_DIR/movie-cli"
    fi

    # Remove shared library and resource directory
    if [[ -d "$SHARE_DIR" ]]; then
        rm -rf "$SHARE_DIR"
        info "Removed library directory: $SHARE_DIR"
    fi

    # Optionally remove configuration and watch history
    if [[ -d "$CONF_DIR" ]]; then
        if confirm "Do you want to delete all configuration and watch history directories?"; then
            rm -rf "$CONF_DIR"
            info "Removed configuration and history: $CONF_DIR"
        else
            warn "Preserved configuration at $CONF_DIR"
        fi
    fi

    info "Uninstallation complete!"
}

main "$@"
