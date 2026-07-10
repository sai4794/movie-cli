#!/usr/bin/env bash
# config.sh — Safe configuration loading (key=value, NOT source)
# Source AFTER errors.sh

# ═══════════════════════════════════════════════════════════════
# Default Configuration
# ═══════════════════════════════════════════════════════════════
# These are the defaults. User config and CLI flags override them.

CONF_PLAYER="${PLAYER:-mpv}"
CONF_QUALITY="${QUALITY:-720}"
CONF_PLUGIN="${PLUGIN:-auto}"
CONF_VERBOSE="${VERBOSE:-0}"
CONF_DEBUG="${DEBUG:-0}"
CONF_QUIET="${QUIET:-0}"
CONF_NO_COLOR="${NO_COLOR:-0}"

# Mark which variables were set by environment (to preserve priority)
# Only mark if the value is non-zero (user explicitly set it)
[[ "${PLAYER:-}" != "mpv" ]] && PLAYER_SET=1
[[ "${QUALITY:-}" != "720" ]] && QUALITY_SET=1
[[ "${PLUGIN:-}" != "auto" ]] && PLUGIN_SET=1
[[ "${VERBOSE:-0}" == "1" ]] && VERBOSE_SET=1
[[ "${DEBUG:-0}" == "1" ]] && DEBUG_SET=1
[[ "${QUIET:-0}" == "1" ]] && QUIET_SET=1
[[ "${NO_COLOR:-0}" == "1" ]] && NO_COLOR_SET=1

# Valid configuration keys (whitelist)
_VALID_KEYS="PLAYER QUALITY PLUGIN VERBOSE DEBUG QUIET NO_COLOR UI_BACKEND SYNCPLAY_HOST SYNCPLAY_ROOM"

# ═══════════════════════════════════════════════════════════════
# Safe Config Loader — key=value parser (NO shell execution)
# ═══════════════════════════════════════════════════════════════
load_config_file() {
    local conf_file="$1"
    [[ -f "$conf_file" ]] || return 0

    debug "Loading config: $conf_file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse key=value (handle spaces around =)
        local key="${line%%=*}"
        local value="${line#*=}"

        # Trim whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        # Trim whitespace from value
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # Remove surrounding quotes from value
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        # Skip if key is empty after trim
        [[ -z "$key" ]] && continue

        # Validate key against allowlist
        if [[ " $_VALID_KEYS " == *" $key "* ]]; then
            # Config file provides defaults — do NOT override env vars.
            # Priority: CLI flags > env vars > config file > built-in defaults
            case "$key" in
                PLAYER)    [[ -z "${PLAYER_SET:-}" ]] && CONF_PLAYER="$value" ;;
                QUALITY)   [[ -z "${QUALITY_SET:-}" ]] && CONF_QUALITY="$value" ;;
                PLUGIN)    [[ -z "${PLUGIN_SET:-}" ]] && CONF_PLUGIN="$value" ;;
                VERBOSE)   [[ -z "${VERBOSE_SET:-}" ]] && CONF_VERBOSE="$value" ;;
                DEBUG)     [[ -z "${DEBUG_SET:-}" ]] && CONF_DEBUG="$value" ;;
                QUIET)     [[ -z "${QUIET_SET:-}" ]] && CONF_QUIET="$value" ;;
                NO_COLOR)  [[ -z "${NO_COLOR_SET:-}" ]] && CONF_NO_COLOR="$value" ;;
                UI_BACKEND) CONF_UI_BACKEND="$value" ;;
                SYNCPLAY_HOST) CONF_SYNCPLAY_HOST="$value" ;;
                SYNCPLAY_ROOM) CONF_SYNCPLAY_ROOM="$value" ;;
            esac
            debug "Config: $key=$value"
        else
            warn "Unknown config key: $key (in $conf_file)"
        fi
    done < "$conf_file"
}

# ═══════════════════════════════════════════════════════════════
# Load Config Chain (priority: CLI > env > user config > defaults)
# ═══════════════════════════════════════════════════════════════
load_all_config() {
    # 1. Defaults already set at top of file
    # 2. User config file
    load_config_file "$CONF_DIR/movie-cli.conf"
    # 3. Plugin-specific config (if exists)
    # load_config_file "$CONF_DIR/movieblast.conf"  # Phase 2

    # 4. CLI flags override everything (parsed in main script)
    # CLI flags are applied AFTER this function via parse_args()

    # Export final values for child processes
    export PLAYER="$CONF_PLAYER"
    export QUALITY="$CONF_QUALITY"
    export PLUGIN="$CONF_PLUGIN"
    export VERBOSE="$CONF_VERBOSE"
    export DEBUG="$CONF_DEBUG"
    export QUIET="$CONF_QUIET"
    export NO_COLOR="$CONF_NO_COLOR"
}

# ═══════════════════════════════════════════════════════════════
# Create Default Config File
# ═══════════════════════════════════════════════════════════════
create_default_config() {
    local conf_file="$CONF_DIR/movie-cli.conf"
    [[ -f "$conf_file" ]] && return 0

    mkdir -p "$CONF_DIR"
    cat > "$conf_file" << 'EOF'
# movie-cli configuration
# Priority: CLI flags > env vars > this file > built-in defaults

# Player: mpv, vlc, iina
PLAYER=mpv

# Default quality: 480, 720, 1080
QUALITY=720

# Plugin: auto (try all), or specific name
PLUGIN=auto

# UI backend: fzf, rofi, dmenu
# UI_BACKEND=fzf

# Verbose output (0 or 1)
VERBOSE=0

# Debug output (0 or 1)
DEBUG=0
EOF
    chmod 600 "$conf_file"
}
