#!/usr/bin/env bash
# errors.sh — Error handling, logging, retry logic
# Source AFTER init.sh

# ═══════════════════════════════════════════════════════════════
# Internal Logger
# ═══════════════════════════════════════════════════════════════
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date_iso 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")
    printf '[%s] [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Fatal Error Functions (exit with specific code)
# ═══════════════════════════════════════════════════════════════
die_user() {
    _log "ERROR" "$*"
    printf '%s\n' "[movie-cli] ERROR: $*" >&2
    exit 1
}

die_network() {
    _log "ERROR" "$*"
    printf '%s\n' "[movie-cli] ERROR: $*" >&2
    exit 2
}

die_plugin() {
    _log "ERROR" "$*"
    printf '%s\n' "[movie-cli] ERROR: $*" >&2
    exit 3
}

die_player() {
    _log "ERROR" "$*"
    printf '%s\n' "[movie-cli] ERROR: $*" >&2
    exit 4
}

die_deps() {
    _log "ERROR" "$*"
    printf '%s\n' "[movie-cli] ERROR: $*" >&2
    exit 5
}

# ═══════════════════════════════════════════════════════════════
# Non-Fatal Output
# ═══════════════════════════════════════════════════════════════
warn() {
    [[ "${QUIET:-0}" == "1" ]] && return 0
    _log "WARN" "$*"
    printf '%s\n' "[movie-cli] WARN: $*" >&2
}

info() {
    [[ "${VERBOSE:-0}" == "1" ]] || return 0
    [[ "${QUIET:-0}" == "1" ]] && return 0
    _log "INFO" "$*"
    printf '%s\n' "[movie-cli] $*" >&2
}

debug() {
    [[ "${DEBUG:-0}" == "1" ]] || return 0
    [[ "${QUIET:-0}" == "1" ]] && return 0
    _log "DEBUG" "$*"
    printf '%s\n' "[DEBUG] $*" >&2
}

# ═══════════════════════════════════════════════════════════════
# Retry with Exponential Backoff
# ═══════════════════════════════════════════════════════════════
retry() {
    local max="${1:-3}"
    local delay="${2:-2}"
    shift 2

    # Ensure delay is integer for arithmetic
    delay=${delay%.*}
    [[ -z "$delay" ]] && delay=1
    (( delay < 1 )) && delay=1

    local attempt=1
    while (( attempt <= max )); do
        if "$@"; then
            return 0
        fi

        # Last attempt — don't wait, just fail
        (( attempt == max )) && break

        warn "Attempt $attempt/$max failed, retrying in ${delay}s..."
        sleep "$delay" || return 130  # interrupted by signal
        (( attempt++ ))
        (( delay *= 2 ))
        (( delay > 60 )) && delay=60  # cap at 60s
    done

    return 1
}

# ═══════════════════════════════════════════════════════════════
# Safe Curl Wrapper (HTTPS only)
# ════════════════════════════════════════════════════════════════
api_curl() {
    curl -sSL \
        --connect-timeout 10 \
        --max-time 30 \
        --proto '=https' \
        --tlsv1.2 \
        -H "User-Agent: movie-cli/$VERSION" \
        "$@"
}


