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

    # Relevance filter (canonical, same rule as dudefilms/vegamovies):
    #   keep iff (a) normalized query is a substring of normalized title,
    #   OR (b) EVERY significant token (>=3 chars) appears as a whole word.
    # Castle's searchByKeyword is fuzzy — without this, "all of us are dead"
    # dumps 20 unrelated movies/series (Dead of Winter, The Last of Us, ...).
    local qnorm qtokens
    qnorm=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')
    qtokens=$(printf '%s' "$query" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z0-9]{3,}' | tr '\n' ' ' | sed 's/ $//')
    [[ -z "$qtokens" ]] && qtokens="$qnorm"

    printf '%s' "$result" | jq -c --arg qnorm "$qnorm" --arg qtokens "$qtokens" '
        def norm: ascii_downcase | gsub("[^a-z0-9]"; "");
        def twords: ascii_downcase | gsub("[^a-z0-9]+"; " ") | split(" ");
        def keeps:
            ($qnorm != "" and (norm | contains($qnorm)))
            or
            ((twords) as $tw
             | all(($qtokens | split(" "))[];
                   . as $t | ($t != "" and ($tw | index($t)) != null)));
        [.data.rows[]?
         | select((.title // "") | keeps)
         | {id: (.id | tostring),
            title: .title,
            type: (if .movieType == 1 then "series" else "movie" end),
            year: (.year // null | tostring),
            rating: (.score // null | tostring),
            poster: (.coverHorizontalImage // null),
            plugin: "CastleTv"}]
    ' 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# plugin_list_seasons
# Castle API: each season is a separate "movie" entry with its own ID.
# .data.seasons[] is the authoritative season map (movieId + number).
# ═══════════════════════════════════════════════════════════════
plugin_list_seasons() {
    local series_id="$1"
    # Fetch details — .data.seasons holds the authoritative season map
    local detail
    detail=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${series_id}&packageName=com.external.castle")
    [[ -z "$detail" ]] && return 1

    local title
    title=$(printf '%s' "$detail" | jq -r '.data.title // ""' 2>/dev/null)
    [[ -z "$title" ]] && return 1

    # Preferred path: .data.seasons[] = [{movieId, number, description}]
    # CLI contract: seasons need .title, .id, .number (name/season kept
    # for back-compat with existing tests).
    local out
    out=$(printf '%s' "$detail" | jq -c --arg t "$title" '
        [.data.seasons[]?
           | select(.number != null)
           | {season: .number,
              number: .number,
              title: (.description // ("Season " + (.number|tostring))),
              name: (.description // ("Season " + (.number|tostring))),
              id: (.movieId | tostring),
              eps: 0}]
        | sort_by(.season)
    ' 2>/dev/null)

    # Fallback (no seasons map): search the title, then fetch each
    # same-title entry to read its explicit .data.seasonNumber.
    if [[ -z "$out" || "$(printf '%s' "$out" | jq 'length' 2>/dev/null)" == "0" ]]; then
        local encoded results ids acc=""
        encoded=$(urlencode "$title")
        results=$(_ct_api_get "${_CT_BASE}/film-api/v1.1.0/movie/searchByKeyword?channel=IndiaA&clientType=1&keyword=${encoded}&lang=en-US&mode=1&packageName=com.external.castle&page=1&size=20")
        [[ -z "$results" ]] && return 1
        ids=$(printf '%s' "$results" | jq -c --arg t "$title" \
            '[.data.rows[]? | select(.movieType == 1 and .title == $t) | .id]' 2>/dev/null)
        out="[]"
        local id
        for id in $(printf '%s' "$ids" | jq -r '.[]' 2>/dev/null); do
            local d sn
            d=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${id}&packageName=com.external.castle")
            sn=$(printf '%s' "$d" | jq -r '.data.seasonNumber // 0' 2>/dev/null)
            [[ -z "$sn" ]] && sn=0
            acc+=$(jq -nc --arg id "$id" --arg sn "$sn" --arg t "$title" \
                '{season: ($sn|tonumber), number: ($sn|tonumber),
                  title: ("Season " + $sn), name: ("Season " + $sn),
                  id: $id, eps: 0}')
            acc+=$'\n'
        done
        if [[ -n "$acc" ]]; then
            out=$(printf '%s' "$acc" | jq -sc 'sort_by(.season)' 2>/dev/null)
        fi
    fi

    printf '%s\n' "$out"
}

# ═══════════════════════════════════════════════════════════════
# plugin_list_episodes
# Castle API: each season is its own ID. The CLI passes the searched
# series id + the season number, so map season number -> season movieId
# via .data.seasons[] (or a title re-search fallback). Episode ids embed
# "season_id:season:episode_number" so plugin_get_url can resolve the
# movieId + episodeId without another lookup.
# ═══════════════════════════════════════════════════════════════
plugin_list_episodes() {
    local series_id="$1"
    local season="$2"

    local detail
    detail=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${series_id}&packageName=com.external.castle")
    [[ -z "$detail" ]] && return 1

    local season_id=""
    local current_sn
    current_sn=$(printf '%s' "$detail" | jq -r '.data.seasonNumber // ""' 2>/dev/null)
    if [[ -n "$current_sn" && "$current_sn" == "$season" ]]; then
        # The searched id IS this season's entry
        season_id="$series_id"
    else
        season_id=$(printf '%s' "$detail" | jq -r --arg s "$season" '
            [.data.seasons[]? | select(.number == ($s | tonumber))][0].movieId // ""
        ' 2>/dev/null)
        if [[ -z "$season_id" ]]; then
            # Fallback: re-search by title, match explicit seasonNumber
            local title sid sn encoded results
            title=$(printf '%s' "$detail" | jq -r '.data.title // ""' 2>/dev/null)
            if [[ -n "$title" ]]; then
                encoded=$(urlencode "$title")
                results=$(_ct_api_get "${_CT_BASE}/film-api/v1.1.0/movie/searchByKeyword?channel=IndiaA&clientType=1&keyword=${encoded}&lang=en-US&mode=1&packageName=com.external.castle&page=1&size=20")
                for sid in $(printf '%s' "$results" | jq -r --arg t "$title" \
                    '[.data.rows[]? | select(.title == $t) | .id][]' 2>/dev/null); do
                    local d2
                    d2=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${sid}&packageName=com.external.castle")
                    sn=$(printf '%s' "$d2" | jq -r '.data.seasonNumber // ""' 2>/dev/null)
                    if [[ -n "$sn" && "$sn" == "$season" ]]; then
                        season_id="$sid"
                        detail="$d2"
                        break
                    fi
                done
            fi
        fi
    fi
    [[ -z "$season_id" ]] && return 1

    # Need the season entry's own detail for its episodes
    if [[ "$season_id" != "$series_id" ]]; then
        local d3
        d3=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${season_id}&packageName=com.external.castle")
        [[ -z "$d3" ]] && return 1
        detail="$d3"
    fi

    printf '%s' "$detail" | jq -c --arg s "$season" --arg sid "$season_id" '
        [.data.episodes[]? | {
            id: ($sid + ":" + $s + ":" + (.number | tostring)),
            season: ($s | tonumber),
            episode: .number,
            title: .title,
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
    local movie_id="" episode_id="" detail_json=""

    # Parse id: could be "movieId" or "movieId:season:episode".
    # Strict: a malformed "123::" must not silently become episode 1.
    if [[ "$id" == *:*:* ]]; then
        [[ "$id" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || return 1
        IFS=':' read -r movie_id _s _e <<< "$id"
    else
        [[ "$id" =~ ^[0-9]+$ ]] || return 1
        movie_id="$id"
    fi

    # Fetch movie/episode details (needed for episode_id AND audio tracks)
    detail_json=$(_ct_api_get "${_CT_BASE}/film-api/v1.9.9/movie?channel=IndiaA&clientType=1&lang=en-US&movieId=${movie_id}&packageName=com.external.castle")
    [[ -z "$detail_json" ]] && return 1

    if [[ -n "${_e:-}" ]]; then
        episode_id=$(printf '%s' "$detail_json" | jq -r --arg e "${_e:-1}" '
            [.data.episodes[]? | select(.number == ($e | tonumber))][0].id // ""
        ' 2>/dev/null)
    else
        episode_id=$(printf '%s' "$detail_json" | jq -r '.data.episodes[0].id // ""' 2>/dev/null)
    fi
    [[ -z "$episode_id" ]] && return 1

    # Extract audio tracks from the episode detail.
    # Each track has a languageId (numeric) and languageName.
    # The default track uses languageId="" in the getVideo2 request;
    # tracks with existIndividualVideo=true have separate video files
    # accessible via their numeric languageId.
    local ep_index="${_e:-1}"
    local tracks_json
    tracks_json=$(printf '%s' "$detail_json" | jq -c --arg e "$ep_index" '
        [.data.episodes[]? | select(.number == ($e | tonumber))][0].tracks // []
    ' 2>/dev/null)
    [[ -z "$tracks_json" || "$tracks_json" == "null" ]] && tracks_json="[]"

    # Build list of (languageId, languageName) pairs to query.
    # Default track: languageId="" (always present).
    # Additional tracks: those with existIndividualVideo=true.
    local -a lang_ids=("") lang_names=()
    local default_lang
    default_lang=$(printf '%s' "$tracks_json" | jq -r '
        [.[] | select(.isDefault == true)][0].languageName // "Default"
    ' 2>/dev/null)
    lang_names+=("$default_lang")

    local _ct_tracks_tmp
    _ct_tracks_tmp=$(mktemp 2>/dev/null || mktemp -t castle_tracks) || return 1
    [[ -n "$_ct_tracks_tmp" ]] || return 1
    printf '%s' "$tracks_json" | jq -r '
        .[] | select(.existIndividualVideo == true and .isDefault != true) |
        "\(.languageId)\t\(.languageName)"
    ' 2>/dev/null > "$_ct_tracks_tmp" || true
    while IFS=$'\t' read -r lid lname; do
        [[ -z "$lid" ]] && continue
        lang_ids+=("$lid")
        lang_names+=("$lname")
    done < "$_ct_tracks_tmp"
    rm -f "$_ct_tracks_tmp" 2>/dev/null || true

    # Available resolutions from the episode's videos array (skip premium-only).
    # Fallback to 0,1,2 if parsing fails.
    local -a res_codes=()
    local -A res_labels=([0]="360p" [1]="480p" [2]="720p" [3]="1080p")
    local _ct_res_tmp
    _ct_res_tmp=$(mktemp 2>/dev/null || mktemp -t castle_res) || return 1
    [[ -n "$_ct_res_tmp" ]] || return 1
    printf '%s' "$detail_json" | jq -r --arg e "${ep_index}" '
        [.data.episodes[]? | select(.number == ($e | tonumber))][0].videos[]? |
        select(.premiumProPermission != true) | .resolution
    ' 2>/dev/null > "$_ct_res_tmp" || true
    while IFS= read -r rc; do
        [[ -n "$rc" ]] && res_codes+=("$rc")
    done < "$_ct_res_tmp"
    rm -f "$_ct_res_tmp" 2>/dev/null || true
    [[ ${#res_codes[@]} -eq 0 ]] && res_codes=(1 2)

    # Query every (language × resolution) combination in parallel
    local tmp_dir
    tmp_dir=$(mktemp -d) || return 1
    [[ -n "$tmp_dir" && -d "$tmp_dir" ]] || return 1
    local pids=() idx=0

    local li=0
    while (( li < ${#lang_ids[@]} )); do
        local lid="${lang_ids[$li]}"
        local lname="${lang_names[$li]}"
        for res_code in "${res_codes[@]}"; do
            (
                local body
                body=$(jq -nc \
                    --arg mid "$movie_id" \
                    --arg eid "$episode_id" \
                    --arg key "$_CT_APK_KEY" \
                    --arg res "$res_code" \
                    --arg lid "$lid" \
                    '{
                        mode: "1",
                        appMarket: "GuanWang",
                        clientType: "1",
                        woolUser: "false",
                        apkSignKey: $key,
                        androidVersion: "13",
                        languageId: $lid,
                        movieId: $mid,
                        episodeId: $eid,
                        isNewUser: "true",
                        resolution: $res,
                        packageName: "com.external.castle"
                    }')

                local res_result
                res_result=$(_ct_api_post "${_CT_BASE}/film-api/v2.0.1/movie/getVideo2?clientType=1&packageName=com.external.castle&channel=IndiaA&lang=en-US" "$body" 2>/dev/null)
                [[ -z "$res_result" ]] && exit 0

                local video_url
                video_url=$(printf '%s' "$res_result" | jq -r '.data.videoUrl // ""' 2>/dev/null)
                [[ -z "$video_url" ]] && exit 0

                local qual="${res_labels[$res_code]:-auto}"
                jq -nc --arg u "$video_url" --arg q "$qual" --arg l "$lname" \
                    '{quality: $q, url: $u, size: "unknown", provider: "CastleTv", language: $l}' \
                    > "$tmp_dir/stream_${idx}.json"
            ) &
            pids+=($!)
            idx=$((idx + 1))
        done
        li=$((li + 1))
    done

    (( ${#pids[@]} )) && wait "${pids[@]}" 2>/dev/null || true

    # Merge all results, deduplicate by URL
    local merged="[]"
    if compgen -G "$tmp_dir/stream_*.json" > /dev/null 2>&1; then
        merged=$(cat "$tmp_dir"/stream_*.json 2>/dev/null | jq -s 'unique_by(.url)' 2>/dev/null) || merged="[]"
    fi
    rm -rf "$tmp_dir"

    [[ -z "$merged" || "$merged" == "[]" ]] && return 1
    printf '%s\n' "$merged"
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
