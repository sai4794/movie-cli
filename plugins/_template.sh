#!/usr/bin/env bash
# _template.sh — Plugin template for movie-cli
# Copy this file and implement the required functions.

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata (REQUIRED)
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="TemplatePlugin"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie")          # "movie", "series", or both
PLUGIN_REQUIRES=("curl" "jq")   # Dependencies beyond core
PLUGIN_AUTHOR="Your Name"
PLUGIN_DESCRIPTION="Brief description of this plugin"

# ═══════════════════════════════════════════════════════════════
# Required Functions
# ═══════════════════════════════════════════════════════════════

# Search for content
# Args: $1=query, $2=quality (480|720|1080|any)
# Output: JSON array to stdout
# Each item MUST have: id, title, type
# Each item MAY have: year, rating, poster
plugin_search() {
    local query="$1"
    local quality="${2:-720}"

    # TODO: Implement search
    # Example output:
    # echo '[{"id":"123","title":"Example (2020)","type":"movie","year":"2020","rating":"7.5"}]'
    echo '[]'
}

# Get video URL for playback
# Args: $1=id (from plugin_search), $2=quality
# Output: single URL line to stdout
plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"

    # TODO: Implement URL retrieval
    # Example output:
    # echo "https://example.com/video.m3u8"
    die_plugin "Not implemented"
}

# ═══════════════════════════════════════════════════════════════
# Optional Functions (implement as needed)
# ═══════════════════════════════════════════════════════════════

# List seasons for a series
# Args: $1=series_id
# Output: JSON array
plugin_list_seasons() {
    local series_id="$1"
    echo '[]'
}

# List episodes for a season
# Args: $1=series_id, $2=season_number
# Output: JSON array
plugin_list_episodes() {
    local series_id="$1"
    local season="$2"
    echo '[]'
}

# List available languages
# Args: $1=id
# Output: JSON array [{"code":"en","name":"English"}]
plugin_list_languages() {
    local id="$1"
    echo '[{"code":"en","name":"English"}]'
}

# Get URL for specific language
# Args: $1=id, $2=quality, $3=lang_code
# Output: URL string
plugin_get_url_for_language() {
    local id="$1"
    local quality="$2"
    local lang="$3"
    plugin_get_url "$id" "$quality"
}

# ═══════════════════════════════════════════════════════════════
# Lifecycle Hooks (optional)
# ═══════════════════════════════════════════════════════════════

# Called once when plugin is loaded
# Args: $1=config_dir
plugin_init() {
    local config_dir="$1"
    debug "Plugin $PLUGIN_NAME initialized"
}

# Called on exit
plugin_cleanup() {
    debug "Plugin $PLUGIN_NAME cleaned up"
}

# ═══════════════════════════════════════════════════════════════
# Health Check (optional)
# ═══════════════════════════════════════════════════════════════
# Exit codes: 0=healthy, 1=degraded, 2=down
plugin_health() {
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Plugin Info (optional)
# ═══════════════════════════════════════════════════════════════
# Output: JSON object to stdout
plugin_info() {
    printf '{"name":"%s","version":"%s","types":["%s"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION" "${PLUGIN_TYPES[0]}"
}
