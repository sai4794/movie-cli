#!/usr/bin/env bash
# movieblast.sh — MovieBlast API plugin for movie-cli
# Search + play movies and series from MovieBlast

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="MovieBlast"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies and series from MovieBlast API"

# ═══════════════════════════════════════════════════════════════
# API Configuration
# ═══════════════════════════════════════════════════════════════
_MB_BASE_URL="https://app.cloud-mb.xyz"

# Hardcoded defaults (from Cloudstream MovieBlast extension — public source)
# Override via $CONF_DIR/movieblast.conf if needed
_MB_HMAC_SECRET="GJ8reydarI7Jqat9rvbAJKNQ9gY4DoEQF2H5nfuI1gi"
_MB_HASH256="86dc03244adddbi3222b"
_MB_PACKAGENAME="com.movieblast"
_MB_SIGNATURE="Y29tLm1vdmllYmxhc3Q="
_MB_DEFAULT_TOKEN="jdvhhjv255vghhgdhvfch2565656jhdcghfdf"

_load_mb_config() {
    local conf_file="$CONF_DIR/movieblast.conf"
    [[ -f "$conf_file" ]] || return 0  # ponytail: no config = use defaults

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        local key="${line%%=*}"
        local value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        [[ -z "$key" ]] && continue

        case "$key" in
            HMAC_SECRET)    _MB_HMAC_SECRET="$value" ;;
            HASH256)        _MB_HASH256="$value" ;;
            PACKAGENAME)    _MB_PACKAGENAME="$value" ;;
            SIGNATURE)      _MB_SIGNATURE="$value" ;;
        esac
    done < "$conf_file"

    # Verify all required values are loaded
    [[ -n "$_MB_HMAC_SECRET" && -n "$_MB_HASH256" && -n "$_MB_PACKAGENAME" && -n "$_MB_SIGNATURE" ]]
}

_MB_HEADERS=()

# ═══════════════════════════════════════════════════════════════
# Token Management (Tiered Resolution)
# ═══════════════════════════════════════════════════════════════
_MB_TOKEN=""

_load_token() {
    # 1. Environment variable
    if [[ -n "${MOVIEBLAST_TOKEN:-}" ]]; then
        _MB_TOKEN="$MOVIEBLAST_TOKEN"
        debug "Token from env var"
        return 0
    fi

    # 2. Config file
    local conf_file="$CONF_DIR/movieblast.conf"
    if [[ -f "$conf_file" ]]; then
        _MB_TOKEN=$(grep -E '^TOKEN=' "$conf_file" 2>/dev/null | cut -d= -f2 | tr -d '"' | tr -d "'")
        if [[ -n "$_MB_TOKEN" ]]; then
            debug "Token from config file"
            return 0
        fi
    fi

    # 3. Hardcoded default (Cloudstream extension source)
    _MB_TOKEN="$_MB_DEFAULT_TOKEN"
    debug "Token from built-in default"
}

# ═══════════════════════════════════════════════════════════════
# URL Signing (HMAC-SHA256)
# ═══════════════════════════════════════════════════════════════
_mb_sign_url() {
    local url="$1"
    # Add https:// if missing
    [[ "$url" =~ ^https?:// ]] || url="https://$url"

    local path_part
    path_part=$(printf '%s' "$url" | sed 's|https\?://[^/]*||')

    local timestamp
    timestamp=$(date +%s)

    # Load config if not already loaded
    [[ -n "$_MB_HMAC_SECRET" ]] || _load_mb_config

    local signature
    signature=$(printf '%s%s' "$path_part" "$timestamp" | \
        openssl dgst -sha256 -hmac "$_MB_HMAC_SECRET" -binary | \
        base64)

    local encoded_sig
    encoded_sig=$(urlencode "$signature")

    printf '%s?verify=%s-%s' "$url" "$timestamp" "$encoded_sig"
}

# ═══════════════════════════════════════════════════════════════
# API Call Helper
# ═══════════════════════════════════════════════════════════════
_mb_api() {
    local endpoint="$1"

    # Load config and build headers
    _load_mb_config

    _MB_HEADERS=(
        -H "hash256: $_MB_HASH256"
        -H "packagename: $_MB_PACKAGENAME"
        -H "signature: $_MB_SIGNATURE"
        -H "User-Agent: MovieBlast"
    )

    local url="${_MB_BASE_URL}${endpoint}/${_MB_TOKEN}"

    local response
    response=$(api_curl "${_MB_HEADERS[@]}" "$url" 2>/dev/null) || {
        die_network "MovieBlast API request failed: $endpoint"
    }

    # Validate JSON
    printf '%s' "$response" | jq . &>/dev/null || {
        die_plugin "MovieBlast returned invalid JSON"
    }

    printf '%s' "$response"
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"

    # Load token
    _load_token

    # URL-encode query
    local encoded_query
    encoded_query=$(urlencode "$query")

    # Call API
    local response
    response=$(_mb_api "/api/search/${encoded_query}")

    # Transform to standard schema
    printf '%s' "$response" | jq -c '.search[]? | {
        id: (.id | tostring),
        title: (if .release_date then "\(.name) (\(.release_date[:4]))" else .name end),
        type: (if .type == "serie" then "series" else .type end),
        year: (.release_date // null | if . then .[:4] else null end),
        rating: (.vote_average // null | if . then (. | tostring) else null end),
        poster: (.poster_path // null)
    }' 2>/dev/null | jq -s '.'
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"

    # Load token
    _load_token

    local response
    local series_id="" ep_season="" ep_episode=""

    # Parse encoded episode ID: "series_id:season:episode" for series
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id ep_season ep_episode <<< "$id"
    fi

    if [[ -n "$series_id" ]]; then
        # Series episode — fetch from series endpoint and filter
        response=$(_mb_api "/api/series/show/${series_id}" 2>/dev/null)
        if printf '%s' "$response" | jq -e '.seasons' &>/dev/null; then
            qualities_json=$(printf '%s' "$response" | jq -c --arg s "$ep_season" --arg e "$ep_episode" '
                [.seasons[]? |
                select(.season_number == ($s | tonumber)) |
                .episodes[]? |
                select(.episode_number == ($e | tonumber)) |
                .videos[]? |
                {
                    quality: .server,
                    url: .link,
                    size: "unknown",
                    provider: "movieblast"
                }]
            ' 2>/dev/null)
        fi
    else
        # Movie — fetch from media detail endpoint
        response=$(_mb_api "/api/media/detail/${id}" 2>/dev/null)
        if printf '%s' "$response" | jq -e '.videos' &>/dev/null; then
            qualities_json=$(printf '%s' "$response" | jq -c '
                .videos // [] |
                sort_by(if .server | test("1080") then 0 elif .server | test("720") then 1 else 2 end) |
                map({
                    quality: .server,
                    url: .link,
                    size: "unknown",
                    provider: "movieblast"
                })
            ' 2>/dev/null)
        fi
    fi

    [[ -z "$qualities_json" || "$qualities_json" == "[]" ]] && die_plugin "No video sources found for id: $id"

    # Sign all URLs and return as JSON array
    local -a signed_streams=()
    while IFS= read -r obj; do
        local raw_url
        raw_url=$(printf '%s' "$obj" | jq -r '.url' 2>/dev/null)
        local signed_url
        signed_url=$(_mb_sign_url "$raw_url")
        local signed_obj
        signed_obj=$(printf '%s' "$obj" | jq -c --arg u "$signed_url" '.url = $u' 2>/dev/null)
        signed_streams+=("$signed_obj")
    done < <(printf '%s' "$qualities_json" | jq -c '.[]' 2>/dev/null)

    # Return as JSON array
    printf '['
    local first=1
    for s in "${signed_streams[@]}"; do
        (( first == 0 )) && printf ','
        printf '%s' "$s"
        first=0
    done
    printf ']\n'
}

# Re-sign a URL at playback time (HMAC signatures expire)
plugin_sign_url() {
    local url="$1"
    # Strip existing verify param if present, then re-sign
    local clean_url
    clean_url=$(printf '%s' "$url" | sed 's/?verify=.*//')
    _mb_sign_url "$clean_url"
}

plugin_list_seasons() {
    local series_id="$1"
    _load_token || return 1

    local response
    response=$(_mb_api "/api/series/show/${series_id}")

    printf '%s' "$response" | jq -c '.seasons[]? | {
        id: (.season_number | tostring),
        title: "Season \(.season_number)",
        number: .season_number
    }' 2>/dev/null | jq -s '.'
}

plugin_list_episodes() {
    local series_id="$1"
    local season="$2"
    _load_token || return 1

    # Episodes are nested inside the series show endpoint
    local response
    response=$(_mb_api "/api/series/show/${series_id}")

    printf '%s' "$response" | jq -c --arg s "$season" --arg sid "$series_id" '
        .seasons[]? |
        select(.season_number == ($s | tonumber)) |
        .season_number as $sn |
        .episodes[]? |
        {
            id: ($sid + ":" + ($sn | tostring) + ":" + (.episode_number | tostring)),
            title: ("E\(.episode_number) - \(.name // "Episode \(.episode_number)")"),
            season: $sn,
            episode: .episode_number
        }
    ' 2>/dev/null | jq -s '.'
}

plugin_health() {
    _load_token || return 2

    local status
    status=$(api_curl "${_MB_HEADERS[@]}" "${_MB_BASE_URL}/api/search/test/${_MB_TOKEN}" 2>/dev/null | \
        jq -r '.search | length' 2>/dev/null) || return 2

    [[ "$status" -gt 0 ]] 2>/dev/null && return 0 || return 1
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
