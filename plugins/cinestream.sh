#!/usr/bin/env bash
# cinestream.sh — CineStream plugin for movie-cli
# Searches Cinemeta and resolves links via Vidlink or PlayImdb

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="CineStream"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies and series resolved via Cinemeta, Vidlink, and PlayImdb"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_CINEMETA_BASE="https://v3-cinemeta.strem.io"
_VIDLINK_BASE="https://vidlink.pro"
_ENC_DEC_BASE="https://enc-dec.app"
_CURL_TIMEOUT="-L --connect-timeout 10 --max-time 30"
_CONF_CINESTREAM="$CONF_DIR/cinestream.conf"
STREMIO_ADDONS=""

_load_cinestream_config() {
    [[ -f "$_CONF_CINESTREAM" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$line" == STREMIO_ADDONS=* ]]; then
            STREMIO_ADDONS="${line#*=}"
            STREMIO_ADDONS="${STREMIO_ADDONS#\"}"
            STREMIO_ADDONS="${STREMIO_ADDONS%\"}"
            STREMIO_ADDONS="${STREMIO_ADDONS#\'}"
            STREMIO_ADDONS="${STREMIO_ADDONS%\'}"
        fi
    done < "$_CONF_CINESTREAM"
}


# ═══════════════════════════════════════════════════════════════
# Helper Functions
# ═══════════════════════════════════════════════════════════════

_resolve_playimdb() {
    local id="$1"
    local imdb_id season episode
    
    if [[ "$id" == *:* ]]; then
        local parts
        IFS=':' read -r -a parts <<< "$id"
        imdb_id="${parts[0]}"
        season="${parts[1]}"
        episode="${parts[2]}"
    else
        imdb_id="$id"
        season=""
        episode=""
    fi

    local embed_url
    if [[ -z "$season" ]]; then
        embed_url="https://streamimdb.me/embed/${imdb_id}"
    else
        embed_url="https://streamimdb.me/embed/tv?imdb=${imdb_id}&season=${season}&episode=${episode}"
    fi

    local iframe_url
    iframe_url=$(curl -s $_CURL_TIMEOUT -H "User-Agent: Mozilla/5.0" "$embed_url" | python3 -c '
import sys, re
match = re.search(r"<iframe\s+id=\"player_iframe\"\s+src=\"([^\"]+)\"", sys.stdin.read())
print(match.group(1) if match else "")
' 2>/dev/null)

    if [[ -z "$iframe_url" ]]; then
        return 1
    fi

    if [[ "$iframe_url" == //* ]]; then
        iframe_url="https:${iframe_url}"
    fi

    local iframe_domain
    # ponytail: sed -E, not grep -oP (macOS compat)
    iframe_domain=$(printf '%s' "$iframe_url" | sed -E 's|^(https?://[^/]+).*|\1|')

    local iframe_html
    iframe_html=$(curl -s $_CURL_TIMEOUT -H "Referer: https://streamimdb.me/" -H "User-Agent: Mozilla/5.0" "$iframe_url" 2>/dev/null)

    local prorcp_src
    prorcp_src=$(python3 -c '
import sys, re
match = re.search(r"src\s*:\s*[\x27\x22]([^\x27\x22]+)[\x27\x22]", sys.stdin.read(), re.I)
print(match.group(1) if match else "")
' <<< "$iframe_html" 2>/dev/null)

    if [[ -z "$prorcp_src" ]]; then
        return 1
    fi

    local cloud_url="${iframe_domain}${prorcp_src}"
    local cloud_html
    cloud_html=$(curl -s $_CURL_TIMEOUT -H "Referer: $iframe_url" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" "$cloud_url" 2>/dev/null)

    local request_json
    request_json=$(python3 -c '
import sys, re, json
html = sys.stdin.read()
match = re.search(r"<div\s+id=\"([^\"]+)\"[^>]*style=\"[^\"]*display\s*:\s*none;?[^\"]*\"[^>]*>([a-zA-Z0-9:\/.,{}_=+ -]+)</div>", html, re.I)
if match:
    print(json.dumps({"text": match.group(2).strip(), "div_id": match.group(1).strip()}))
else:
    sys.exit(1)
' <<< "$cloud_html" 2>/dev/null) || return 1

    local dec_res decrypted_url
    dec_res=$(curl -s $_CURL_TIMEOUT -X POST \
        -H "Content-Type: application/json" \
        -d "$request_json" \
        "https://enc-dec.app/api/dec-cloudnestra" 2>/dev/null)

    decrypted_url=$(printf '%s' "$dec_res" | jq -r '.result[0] // empty' 2>/dev/null)

    if [[ -n "$decrypted_url" && "$decrypted_url" != "null" ]]; then
        local stream_host
        stream_host=$(printf '%s' "$decrypted_url" | sed -E 's|^https?://([^/]+).*|\1|')
        
        local stream_token
        stream_token=$(curl -s $_CURL_TIMEOUT -H "Referer: ${iframe_domain}/" "https://${stream_host}/generate.php" 2>/dev/null)
        
        if [[ -n "$stream_token" && "$stream_token" != "null" ]]; then
            local final_url
            final_url="${decrypted_url/__TOKEN__/$stream_token}"
            printf '%s\n' "$final_url"
            return 0
        fi
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"

    local encoded_query
    encoded_query=$(urlencode "$query")

    # Fetch movie & series search results from Cinemeta concurrently
    local movie_res series_res
    movie_res=$(curl -s $_CURL_TIMEOUT "${_CINEMETA_BASE}/catalog/movie/top/search=${encoded_query}.json") || return 1
    series_res=$(curl -s $_CURL_TIMEOUT "${_CINEMETA_BASE}/catalog/series/top/search=${encoded_query}.json") || return 1

    # Merge and transform to the standard movie-cli JSON schema
    # Properties required: id, title, type
    # Properties optional: year, rating, poster
    local raw_results
    raw_results=$(jq -n \
        --argjson movies "$movie_res" \
        --argjson series "$series_res" '
        ($movies.metas // []) + ($series.metas // []) |
        map({
            id: .id,
            title: (if .releaseInfo then "\(.name) (\(.releaseInfo))" else .name end),
            _name: .name,
            type: .type,
            year: (.releaseInfo // null),
            rating: (.imdbRating // null),
            poster: (.poster // null)
        })
    ' 2>/dev/null) || return 1

# Score and sort by relevance — keep only results with score > 0
    # Strip year suffix " (YYYY)" and non-alphanumerics before matching,
    # so "K.G.F: Chapter 1 (2018)" matches "kgf"
    printf '%s' "$raw_results" | jq -c --arg q "$query" '
        [.[] | . + {_score: (
            (.title | split(" (")[0] | gsub("[^a-zA-Z0-9]"; "") | ascii_downcase) as $t |
            ($q | gsub("[^a-zA-Z0-9]"; "") | ascii_downcase) as $q |
            if $t == $q then 100
            elif ($t | startswith($q)) then 90
            elif ($q | startswith($t)) then 80
            elif ($t | test("\\b" + $q + "\\b")) then 70
            elif ($t | contains($q)) then 60
            else 0
            end
        )}] |
        [.[] | select(._score > 0)] |
        sort_by(._score) | reverse |
        [.[] | del(._score, ._name)]
    ' 2>/dev/null
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"

    local type="movie"
    if [[ "$id" == *:* ]]; then
        type="series"
    fi

    local imdb_id="${id%%:*}"

    # 1. Fetch TMDB ID from Cinemeta details API
    local meta_res tmdb_id=""
    meta_res=$(curl -s $_CURL_TIMEOUT "${_CINEMETA_BASE}/meta/${type}/${imdb_id}.json")
    if printf '%s' "$meta_res" | jq -e . >/dev/null 2>&1; then
        tmdb_id=$(printf '%s' "$meta_res" | jq -r '.meta.moviedb_id // empty')
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)

    # Array to track running background job PIDs
    local pids=()

    # 2. Query configured Stremio Addon URLs (run in background)
    local -a addon_list=()
    # Built-in default addons (free, zero-config)
    # ponytail: superflix removed (404 since 2025). Add back when reachable.
    addon_list+=("https://desiflix.stremioaddon.workers.dev")
    addon_list+=("https://addon-osvh.onrender.com")


    # Load custom Stremio Addon configurations from settings
    _load_cinestream_config
    if [[ -n "${STREMIO_ADDONS:-}" ]]; then
        local -a custom_list=()
        IFS=',' read -r -a custom_list <<< "$STREMIO_ADDONS"
        for custom_url in "${custom_list[@]}"; do
            addon_list+=("$custom_url")
        done
    fi

    local addon_idx=0
    for addon_url in "${addon_list[@]}"; do
        # Trim whitespace from addon_url
        addon_url="${addon_url#"${addon_url%%[![:space:]]*}"}"
        addon_url="${addon_url%"${addon_url##*[![:space:]]}"}"
        [[ -z "$addon_url" ]] && continue

        # Strip trailing /manifest.json if present
        addon_url="${addon_url%/manifest.json}"

        (
            local addon_api="${addon_url}/stream/${type}/${id}.json"
            local addon_res
            addon_res=$(curl -s $_CURL_TIMEOUT "$addon_api")
            if printf '%s' "$addon_res" | jq -e .streams >/dev/null 2>&1; then
                printf '%s' "$addon_res" | jq -c '
                    [ .streams[] | select(.url != null) |
                      (.title // .description // "") as $t | {
                        quality: (if ($t | test("(?i)1080p|1080")) then "1080" elif ($t | test("(?i)720p|720")) then "720" elif ($t | test("(?i)480p|480")) then "480" elif ($t | test("(?i)4k|2160p|2160")) then "4K" else "auto" end),
                        url: .url,
                        size: (try (($t | match("[0-9]+(?:\\.[0-9]+)?\\s*(?:GB|MB|gb|mb)"; "i") | .string) // "unknown") catch "unknown"),
                        provider: ((.name // "Addon") | gsub("\\n"; " ")),
                        lang: (if ($t | test("(?i)telugu|\\bTel\\b")) then "telugu"
                               elif ($t | test("(?i)hindi|bollywood")) then "hindi"
                               elif ($t | test("(?i)\\btamil\\b")) then "tamil"
                               elif ($t | test("(?i)kannada")) then "kannada"
                               elif ($t | test("(?i)malayalam")) then "malayalam"
                               elif ($t | test("(?i)english")) then "english"
                               else "unknown" end)
                    } ]
                ' 2>/dev/null > "$tmp_dir/addon_${addon_idx}.json"
            fi
        ) &
        pids+=($!)
        addon_idx=$((addon_idx + 1))
    done

    # 3. Vidlink provider (run in background)
    if [[ -n "$tmdb_id" && "$tmdb_id" != "null" ]]; then
        (
            local enc_res enc_token=""
            enc_res=$(curl -s $_CURL_TIMEOUT "${_ENC_DEC_BASE}/api/enc-vidlink?text=${tmdb_id}")
            if printf '%s' "$enc_res" | jq -e . >/dev/null 2>&1; then
                enc_token=$(printf '%s' "$enc_res" | jq -r '.result // empty')
            fi

            if [[ -n "$enc_token" && "$enc_token" != "null" ]]; then
                local api_url
                if [[ "$id" == *:* ]]; then
                    local parts
                    IFS=':' read -r -a parts <<< "$id"
                    api_url="${_VIDLINK_BASE}/api/b/tv/${enc_token}/${parts[1]}/${parts[2]}"
                else
                    api_url="${_VIDLINK_BASE}/api/b/movie/${enc_token}"
                fi

                local response
                response=$(curl -s $_CURL_TIMEOUT \
                    -H "Referer: ${_VIDLINK_BASE}/" \
                    -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36" \
                    "$api_url")
                
                if printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
                    printf '%s' "$response" | jq -r '
                        .stream // empty |
                        if .qualities != null and (.qualities | length) > 0 then
                            .qualities |
                            to_entries |
                            map({
                                quality: .key,
                                url: .value.url,
                                size: (.value.size // "0" | tonumber / 1048576 | floor | tostring + " MB"),
                                provider: "VidLink"
                            }) |
                            sort_by(.quality | tonumber) |
                            reverse
                        elif .playlist != null and .playlist != "" then
                            [{
                                quality: "auto",
                                url: .playlist,
                                size: "unknown",
                                provider: "VidLink"
                            }]
                        else
                            []
                        end
                    ' 2>/dev/null > "$tmp_dir/vidlink.json"
                fi
            fi
        ) &
        pids+=($!)

    fi

    # 5. PlayImdb fallback/provider (run in background)
    (
        local video_url
        video_url=$(_resolve_playimdb "$id")
        if [[ -n "$video_url" && "$video_url" != "null" ]]; then
            printf '[{"quality":"auto","url":"%s","size":"unknown","provider":"playimdb"}]\n' "$video_url" > "$tmp_dir/playimdb.json"
        fi
    ) &
    pids+=($!)

    # Wait for all background jobs to finish
    wait "${pids[@]}" 2>/dev/null || true

    # Merge all JSON outputs and sort by language relevance
    # ponytail: known languages first, unknown last
    local merged_json="[]"
    for f in "$tmp_dir"/*.json; do
        [[ -f "$f" ]] || continue
        local content
        content=$(cat "$f")
        if [[ -n "$content" && "$content" != "[]" ]]; then
            merged_json=$(printf '%s\n%s' "$merged_json" "$content" | jq -s 'add' 2>/dev/null || echo "$merged_json")
        fi
    done
    rm -rf "$tmp_dir"

    # Sort: known languages first (telugu > hindi > tamil > kannada > malayalam > english), unknown last
    merged_json=$(printf '%s' "$merged_json" | jq '
        sort_by(
            if .lang == "unknown" then 1
            elif .lang == "english" then 2
            else 0
            end
        )
    ' 2>/dev/null || echo "$merged_json")

    if [[ -z "$merged_json" || "$merged_json" == "[]" ]]; then
        die_plugin "No playable links resolved for ID: $id"
    fi

    printf '%s\n' "$merged_json"
}

plugin_list_seasons() {
    local series_id="$1"

    local response
    response=$(curl -s $_CURL_TIMEOUT "${_CINEMETA_BASE}/meta/series/${series_id}.json") || return 1

    # Extract unique season numbers (excluding season 0 / specials)
    printf '%s' "$response" | jq -c '
        [.meta.videos[]? | select(.season != null and .season != 0) | .season] |
        unique |
        map({
            id: (. | tostring),
            title: "Season \(.)",
            number: .
        })
    ' 2>/dev/null
}

plugin_list_episodes() {
    local series_id="$1"
    local season="$2"

    local response
    response=$(curl -s $_CURL_TIMEOUT "${_CINEMETA_BASE}/meta/series/${series_id}.json") || return 1

    # Filter episodes for the specified season
    printf '%s' "$response" | jq -c --argjson s "$season" '
        [.meta.videos[]? | select(.season == $s) | {
            id: .id,
            title: "E\(.number) - \(.name // "Episode \(.number)")",
            season: .season,
            episode: .number
        }]
    ' 2>/dev/null
}

plugin_health() {
    # Verify Cinemeta and enc-dec.app connectivity
    curl -s $_CURL_TIMEOUT --head --fail "${_CINEMETA_BASE}" &>/dev/null || return 1
    curl -s $_CURL_TIMEOUT --head --fail "${_ENC_DEC_BASE}/api/enc-vidlink?text=27205" &>/dev/null || return 1
    return 0
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
