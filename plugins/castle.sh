#!/usr/bin/env bash
# castle.sh — CastleTv plugin for movie-cli
# Uses api.hlowb.com with AES-128-CBC encrypted responses
# Key: ED0955EB04E67A1D9F3305B95454FED485261475 (from CNCVerse binary)

PLUGIN_NAME="CastleTv"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Castle TV movies and series (api.hlowb.com)"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_CT_BASE="https://api.hlowb.com"
_CT_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
_CT_CURL=(-sL --connect-timeout 8 --max-time 20 -A "$_CT_UA")
_CT_APK_KEY="ED0955EB04E67A1D9F3305B95454FED485261475"

# ═══════════════════════════════════════════════════════════════
# AES helpers (python3 subprocess)
# ═══════════════════════════════════════════════════════════════

# Get a fresh security key from the API
_ct_get_sk() {
    curl "${_CT_CURL[@]}" \
        -H "Referer: ${_CT_BASE}/" \
        "${_CT_BASE}/v0.1/system/getSecurityKey/1?channel=IndiaA&clientType=1&lang=en-US" 2>/dev/null \
        | jq -r '.data // ""' 2>/dev/null
}

# Decrypt an AES-128-CBC response using the security key
_ct_decrypt() {
    local cipher_b64="$1"
    local sk="$2"
    python3 -c "
import base64, json, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding as sym_padding
sk = sys.argv[1]
cipher_b64 = sys.argv[2]
key_bytes = (base64.b64decode(sk) + b'T!BgJB')[:16]
cb = base64.b64decode(cipher_b64)
d = Cipher(algorithms.AES(key_bytes), modes.CBC(key_bytes)).decryptor()
dec = d.update(cb) + d.finalize()
unpadder = sym_padding.PKCS7(128).unpadder()
result = (unpadder.update(dec) + unpadder.finalize()).decode()
print(result)
" "$sk" "$cipher_b64" 2>/dev/null
}

# Make an API GET request (get fresh key, fetch, decrypt)
_ct_api_get() {
    local url="$1"
    local sk
    sk=$(_ct_get_sk)
    [[ -z "$sk" ]] && return 1
    local raw
    raw=$(curl "${_CT_CURL[@]}" \
        -H "Referer: ${_CT_BASE}/" \
        -H "Accept: application/json" \
        "$url" 2>/dev/null)
    [[ -z "$raw" ]] && return 1
    # Check if response is JSON (raw error) or base64 (encrypted)
    if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$raw"
    else
        _ct_decrypt "$raw" "$sk"
    fi
}

# Make an API POST request (get fresh key, fetch, decrypt)
_ct_api_post() {
    local url="$1"
    local body="$2"
    local sk
    sk=$(_ct_get_sk)
    [[ -z "$sk" ]] && return 1
    local raw
    raw=$(curl "${_CT_CURL[@]}" \
        -H "Referer: ${_CT_BASE}/" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json; charset=utf-8" \
        -X POST -d "$body" \
        "$url" 2>/dev/null)
    [[ -z "$raw" ]] && return 1
    if printf '%s' "$raw" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$raw"
    else
        _ct_decrypt "$raw" "$sk"
    fi
}

# ═══════════════════════════════════════════════════════════════
# plugin_search
# ═══════════════════════════════════════════════════════════════
plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    local encoded
    encoded=$(urlencode "$query")
    local result
    result=$(_ct_api_get "${_CT_BASE}/film-api/v1.1.0/movie/searchByKeyword?channel=IndiaA&clientType=1&keyword=${encoded}&lang=en-US&mode=1&packageName=com.external.castle&page=1&size=20")
    [[ -z "$result" ]] && return 1
    printf '%s' "$result" | jq -c '
        [.data.rows[]? | {
            id: (.id | tostring),
            title: .title,
            type: (if .movieType == 1 then "series" else "movie" end),
            year: (.year // null | tostring),
            rating: (.score // null | tostring),
            poster: (.coverHorizontalImage // null),
            plugin: "CastleTv"
        }]
    ' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# plugin_list_seasons
# Castle API: each season is a separate "movie" entry with its own ID.
# We search for the series name to find all seasons.
# ═══════════════════════════════════════════════════════════════
plugin_list_seasons() {
    local series_id="$1"
    # Get the title from the series details
    local title
    title=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${series_id}&packageName=com.external.castle" 2>/dev/null \
        | jq -r '.data.title // ""' 2>/dev/null)
    [[ -z "$title" ]] && return 1

    # Search for the title to find all season entries
    local encoded
    encoded=$(urlencode "$title")
    local results
    results=$(_ct_api_get "${_CT_BASE}/film-api/v1.1.0/movie/searchByKeyword?channel=IndiaA&clientType=1&keyword=${encoded}&lang=en-US&mode=1&packageName=com.external.castle&page=1&size=20" 2>/dev/null)
    [[ -z "$results" ]] && return 1

    # Filter to entries with the same title (same series, different seasons)
    printf '%s' "$results" | jq -c --arg t "$title" '
        [.data.rows[]? | select(.title == $t)] | to_entries | map({
            season: (.key + 1),
            name: ("Season " + (.key + 1 | tostring)),
            id: (.value.id | tostring),
            eps: 0
        }) | sort_by(.season)
    ' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# plugin_list_episodes
# Castle API: each season is its own ID. episodes are flat (no season field).
# ═══════════════════════════════════════════════════════════════
plugin_list_episodes() {
    local series_id="$1"
    local season="$2"
    # For Castle, series_id IS the season ID (each season is separate)
    local result
    result=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${series_id}&packageName=com.external.castle")
    [[ -z "$result" ]] && return 1
    printf '%s' "$result" | jq -c --arg s "$season" '
        [.data.episodes[]? | {
            id: (.id | tostring),
            season: ($s | tonumber),
            episode: .number,
            name: .title
        }] | sort_by(.episode)
    ' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# plugin_get_url
# ═══════════════════════════════════════════════════════════════
plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    local movie_id="" episode_id=""

    # Parse id: could be "movieId" or "movieId:season:episode"
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r movie_id _s _e <<< "$id"
    else
        movie_id="$id"
    fi

    # If episode_id is set, we need to find it from the details
    if [[ -n "${_e:-}" ]]; then
        local result
        result=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${movie_id}&packageName=com.external.castle")
        [[ -z "$result" ]] && return 1
        episode_id=$(printf '%s' "$result" | jq -r --arg e "${_e:-1}" '
            [.data.episodes[]? | select(.number == ($e | tonumber))][0].id // ""
        ' 2>/dev/null)
    elif [[ -z "$episode_id" ]]; then
        # Movie: get first episode id from details
        local result
        result=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${movie_id}&packageName=com.external.castle")
        [[ -z "$result" ]] && return 1
        episode_id=$(printf '%s' "$result" | jq -r '.data.episodes[0].id // ""' 2>/dev/null)
    fi

    # getVideo2 request
    local body
    body=$(jq -nc \
        --arg mid "$movie_id" \
        --arg eid "$episode_id" \
        --arg key "$_CT_APK_KEY" \
        '{
            mode: "1",
            appMarket: "GuanWang",
            clientType: "1",
            woolUser: "false",
            apkSignKey: $key,
            androidVersion: "13",
            languageId: "",
            movieId: $mid,
            episodeId: $eid,
            isNewUser: "true",
            resolution: "2",
            packageName: "com.external.castle"
        }')

    local result
    result=$(_ct_api_post "${_CT_BASE}/film-api/v2.0.1/movie/getVideo2?clientType=1&packageName=com.external.castle&channel=IndiaA&lang=en-US" "$body")
    [[ -z "$result" ]] && return 1

    # Extract video URL
    local video_url
    video_url=$(printf '%s' "$result" | jq -r '.data.videoUrl // ""' 2>/dev/null)
    [[ -z "$video_url" ]] && return 1

    # Emit stream
    local qual="auto"
    case "$quality" in
        *360*) qual="360p";;
        *480*) qual="480p";;
        *720*) qual="720p";;
        *1080*) qual="1080p";;
    esac

    jq -nc --arg u "$video_url" --arg q "$qual" \
        '{quality: $q, url: $u, size: "unknown", provider: "CastleTv"}'
}

# ═══════════════════════════════════════════════════════════════
# plugin_health
# ═══════════════════════════════════════════════════════════════
plugin_health() {
    local sk
    sk=$(_ct_get_sk)
    [[ -n "$sk" ]] && return 0
    return 1
}

# ═══════════════════════════════════════════════════════════════
# plugin_info
# ═══════════════════════════════════════════════════════════════
plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}\n' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
