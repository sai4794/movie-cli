#!/usr/bin/env bash
# init.sh — Initialization, globals, traps, portability wrappers
# Source this FIRST in movie-cli

set -euo pipefail
umask 077

# ═══════════════════════════════════════════════════════════════
# Globals
# ═══════════════════════════════════════════════════════════════
VERSION="0.1.0"
HOST_API_VERSION="5"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
PLUGIN_DIR="$SCRIPT_DIR/plugins"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/movie-cli"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/movie-cli"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/movie-cli"
LOG_FILE="$DATA_DIR/movie-cli.log"
HISTORY_FILE="$DATA_DIR/history.jsonl"

# Runtime state
TMPFILE=""
SOCKET_DIR=""
MPV_PID=""
_spinner_pid=""
VERBOSE="${VERBOSE:-0}"
DEBUG="${DEBUG:-0}"
QUIET="${QUIET:-0}"
NO_COLOR="${NO_COLOR:-0}"

# ═══════════════════════════════════════════════════════════════
# Trap Handlers
# ═══════════════════════════════════════════════════════════════
cleanup() {
    rm -f "$TMPFILE" 2>/dev/null
    # Do NOT kill mpv — it's disowned and should survive script exit
    # Kill background spinner if running
    if [[ -n "${_spinner_pid:-}" ]]; then
        kill "$_spinner_pid" 2>/dev/null
        wait "$_spinner_pid" 2>/dev/null || true
    fi
    # Remove mpv IPC socket dir
    [[ -n "${SOCKET_DIR:-}" ]] && rm -rf "$SOCKET_DIR" 2>/dev/null
    rm -f "${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-mpv-$$" 2>/dev/null
    rm -f "${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-script-$$.lua" 2>/dev/null
}
if [[ -z "${BATS_TEST_FILENAME:-}" ]]; then
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP
fi

# ═══════════════════════════════════════════════════════════════
# Ensure directories exist
# ═══════════════════════════════════════════════════════════════
init_dirs() {
    mkdir -p "$CONF_DIR" "$CACHE_DIR" "$DATA_DIR" "${XDG_RUNTIME_DIR:-$HOME/.runtime}"
}

# ═══════════════════════════════════════════════════════════════
# Portability Wrappers
# ═══════════════════════════════════════════════════════════════

# Portable file modification time (seconds since epoch)
file_mtime() {
    local file="$1"
    [[ -f "$file" ]] || { echo 0; return; }
    # Try GNU stat first, then BSD stat
    local mt
    mt=$(stat -c %Y "$file" 2>/dev/null) || \
    mt=$(stat -f %m "$file" 2>/dev/null) || \
    mt=0
    echo "$mt"
}

# Portable SHA256 hash (file or stdin)
sha256_sum() {
    if [[ -n "${1:-}" ]] && [[ -f "$1" ]]; then
        sha256sum "$1" 2>/dev/null | cut -d' ' -f1 || \
        shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
    else
        # Read from stdin
        sha256sum 2>/dev/null | cut -d' ' -f1 || \
        shasum -a 256 2>/dev/null | cut -d' ' -f1
    fi
}

# Portable SHA256 verify
sha256_check() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$@"
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$@"
    else
        return 1
    fi
}

# Portable date (ISO 8601 with timezone)
date_iso() {
    date -Iseconds 2>/dev/null || \
    date +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || \
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Portable date (ISO 8601 with timezone)
date_iso() {
    date -Iseconds 2>/dev/null || \
    date +"%Y-%m-%dT%H:%M:%S%z" 2>/dev/null || \
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# URL-encode a string (safe against injection)
urlencode() {
    printf '%s' "$1" | jq -sRr @uri 2>/dev/null || \
    python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))" 2>/dev/null || \
    printf '%s' "$1"
}


