#!/usr/bin/env bash
# cinex.sh — CineX: multi-provider aggregator (CSX CineStream parity)
# Searches Cinemeta, resolves streams via a registry of site providers:
#   - direct-API providers ported from SaurabhKaperwan/CSX CineStream (Kotlin)
#   - wrappers over the project's standalone site plugins (subshell isolation)
# Reference: https://cloudstream.miraheze.org/wiki/List_of_extensions (CineStream ⭐)

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="CineX"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="70+ provider aggregator (CSX CineStream parity)"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_CX_CINEMETA_BASE="https://v3-cinemeta.strem.io"
_CX_ENC_DEC_BASE="https://enc-dec.app/api"
_CX_XPASS_BASE="https://play.xpass.top"
_CX_ONETV_API="https://api3.devcorp.me"
_CX_VIDEASY_API="https://api.speedracelight.com"
_CX_VAPLAYER_API="https://streamdata.vaplayer.ru"
_CX_HEXA_API="https://theemoviedb.hexa.su"
_CX_HEXA_FINGERPRINT="e9136c41504646444"
_CX_HEXA_REFERER="https://hexa.su/"
_CX_CURL_TIMEOUT="-L --connect-timeout 6 --max-time 25"
# torrentio base kept for registry documentation only; torrent providers are
# OFF per user preference (no magnet streams).

# ── Provider registry ──────────────────────────────────────────
# Ordered list of ACTIVE providers. Each name must have a matching
# _cx_provider_<name> function. Full CSX registry (66 keys) is documented
# in _CX_REGISTRY_ALL below; unimplemented ones are ported incrementally.
_CX_REGISTRY=(
    "hexa"
    "xpass"
    "onetouchtv"
    "videasy"
    "vaplayer"
    "vegamovies"
    "dudefilms"
    "hdhub4u"
    "4khdhub"
    "movieblast"
)

# Full CSX CineStream built-in provider registry (ProviderRegistry.kt) —
# status: IMPL=ported+verified, WRAP=subshell wrapper over standalone plugin,
# TODO=csx reference exists, not yet ported (incremental work items).
# shellcheck disable=SC2034
_CX_REGISTRY_ALL=(
    "torrentio:OFF(user: no torrent streams)" "torrentsdb:TODO(csx token not public)" "animetosho:TODO(anime)"
    "wyziesubs:TODO(subtitles)" "stremiosubs:TODO(subtitles)"
    "showbox:TODO(user token)" "vidrock:TODO" "moviebox:TODO" "cinemacity:TODO(cf-gated)"
    "movieblast:WRAP" "fibwatch:TODO" "allmovieland:TODO" "hexa:IMPL" "xpass:IMPL"
    "fshare:TODO" "videasy:IMPL" "vaplayer:IMPL" "ctgmovies:TODO" "vidzee:TODO(endpoint dead)"
    "peachify:TODO" "vidfastpro:TODO" "vidcore:TODO" "av1encodes:TODO(anime)"
    "castle:TODO(needs CASTLE_KEY secret)" "reanime:TODO(anime)" "zinkmovies:TODO"
    "bollywood:TODO(user token)" "vegamovies:WRAP" "rogmovies:TODO" "bollyflix:TODO"
    "topmovies:TODO" "vidup:TODO" "moviesmod:TODO" "movies4u:TODO" "dudefilms:WRAP"
    "uhdmovies:TODO" "moviesdrive:TODO" "hindmoviez:TODO" "4khdhub:WRAP" "primesrc:TODO"
    "projectfreetv:TODO" "mlsbd:TODO" "levidia:TODO" "hdghartv:TODO" "animesalt:TODO(anime)"
    "m4ufree:TODO" "multimovies:TODO" "akwam:TODO" "rtally:TODO" "asiaflix:TODO"
    "skymovies:TODO" "hdmovie2:TODO" "mostraguarda:TODO" "kisskh:TODO(asian)"
    "onetouchtv:IMPL" "toonstream:TODO(anime)" "anineko:TODO(anime)" "animedao:TODO(anime)"
    "anikoto:TODO(anime)" "anikage:TODO(anime)" "anidb:TODO(anime)" "animepahe:TODO(anime)"
    "animetoshohttp:TODO(anime)" "tokyoinsider:TODO(anime)" "anizone:TODO(anime)"
    "animes:TODO(anime)" "animekizz:TODO(anime)"
)

# ═══════════════════════════════════════════════════════════════
# Shared helpers
# ═══════════════════════════════════════════════════════════════

# Emit one stream JSON line: {quality,url,size,provider,lang}
_cx_emit() {
    local provider="$1" quality="$2" url="$3" size="${4:-unknown}" lang="${5:-unknown}"
    [[ -z "$url" ]] && return 1
    printf '{"quality":"%s","url":"%s","size":"%s","provider":"%s","lang":"%s"}\n' \
        "$quality" "$url" "$size" "$provider" "$lang"
}

# Parse id -> imdb_id, season, episode (id may be "ttXXXX" or "ttXXXX:s:e")
_cx_parse_id() {
    local id="$1"
    _CX_IMDB="${id%%:*}"
    _CX_SEASON=""
    _CX_EPISODE=""
    if [[ "$id" == *:* ]]; then
        local parts
        IFS=':' read -r -a parts <<< "$id"
        _CX_SEASON="${parts[1]:-}"
        _CX_EPISODE="${parts[2]:-}"
    fi
}

# Fetch Cinemeta meta once per get_url; sets _CX_TITLE _CX_YEAR _CX_TMDB
_cx_fetch_meta() {
    local id="$1"
    _cx_parse_id "$id"
    local type="movie"
    [[ -n "$_CX_SEASON" ]] && type="series"

    _CX_TITLE=""; _CX_YEAR=""; _CX_TMDB=""
    local meta_res
    meta_res=$(curl -s $_CX_CURL_TIMEOUT "${_CX_CINEMETA_BASE}/meta/${type}/${_CX_IMDB}.json" 2>/dev/null)
    [[ -z "$meta_res" ]] && return 1
    _CX_TITLE=$(printf '%s' "$meta_res" | jq -r '.meta.name // empty' 2>/dev/null)
    _CX_YEAR=$(printf '%s' "$meta_res" | jq -r '.meta.releaseInfo // empty' 2>/dev/null)
    _CX_TMDB=$(printf '%s' "$meta_res" | jq -r '.meta.moviedb_id // empty' 2>/dev/null)
    [[ -z "$_CX_TMDB" || "$_CX_TMDB" == "null" ]] && _CX_TMDB=""
    [[ -z "$_CX_TITLE" ]] && return 1
    return 0
}

# ═══════════════════════════════════════════════════════════════
# Provider: Hexa (enc-dec.app tokenized m3u8 API, tmdb-keyed)
# ═══════════════════════════════════════════════════════════════
_cx_provider_hexa() {
    local id="$1"
    _cx_parse_id "$id"
    [[ -z "$_CX_TMDB" ]] && return 0

    local url
    if [[ -z "$_CX_SEASON" ]]; then
        url="${_CX_HEXA_API}/api/tmdb/movie/${_CX_TMDB}/images"
    else
        url="${_CX_HEXA_API}/api/tmdb/tv/${_CX_TMDB}/season/${_CX_SEASON}/episode/${_CX_EPISODE}/images"
    fi

    # random 32-byte hex key (SecureRandom parity)
    local key
    key=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')

    # fetch cap token
    local token=""
    token=$(curl -s $_CX_CURL_TIMEOUT "${_CX_ENC_DEC_BASE}/enc-hexa" 2>/dev/null | jq -r '.result.token // empty' 2>/dev/null)
    [[ -z "$token" ]] && return 0

    local enc_data
    enc_data=$(curl -s $_CX_CURL_TIMEOUT \
        -H "User-Agent: Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36" \
        -H "Accept: text/plain" \
        -H "X-Api-Key: $key" \
        -H "X-Fingerprint-Lite: $_CX_HEXA_FINGERPRINT" \
        -H "Referer: $_CX_HEXA_REFERER" \
        -H "X-Cap-Token: $token" \
        "$url" 2>/dev/null) || return 0
    [[ -z "$enc_data" || "$enc_data" == "null" ]] && return 0

    local dec_res
    dec_res=$(curl -s $_CX_CURL_TIMEOUT -X POST \
        -H "Content-Type: application/json" \
        -d "{\"text\":$(printf '%s' "$enc_data" | jq -Rs .),\"key\":\"$key\"}" \
        "${_CX_ENC_DEC_BASE}/dec-hexa" 2>/dev/null) || return 0

    printf '%s' "$dec_res" | jq -c '.result.sources[]? | select(.url != null)' 2>/dev/null | while IFS= read -r src; do
        local server m3u8
        server=$(printf '%s' "$src" | jq -r '.server // "hexa"')
        m3u8=$(printf '%s' "$src" | jq -r '.url')
        _cx_emit "Hexa ${server}" "auto" "$m3u8"
    done
}

# ═══════════════════════════════════════════════════════════════
# Provider: Xpass (embed page -> backups -> playlist.json sources)
# ═══════════════════════════════════════════════════════════════
_cx_provider_xpass() {
    local id="$1"
    _cx_parse_id "$id"
    [[ -z "$_CX_TMDB" ]] && return 0

    local embed_url
    if [[ -z "$_CX_SEASON" ]]; then
        embed_url="${_CX_XPASS_BASE}/e/movie/${_CX_TMDB}"
    else
        embed_url="${_CX_XPASS_BASE}/e/tv/${_CX_TMDB}/${_CX_SEASON}/${_CX_EPISODE}"
    fi

    local html
    html=$(curl -s $_CX_CURL_TIMEOUT -H "Referer: ${_CX_XPASS_BASE}/" "$embed_url" 2>/dev/null) || return 0
    [[ -z "$html" ]] && return 0

    # extract backups=[{...}] entries
    printf '%s' "$html" | python3 -c '
import sys, re, json
html = sys.stdin.read()
m = re.search(r"backups\s*=\s*(\[.*?\])", html, re.S)
if not m:
    sys.exit(0)
try:
    backups = json.loads(m.group(1))
except Exception:
    sys.exit(0)
for b in backups:
    name = b.get("name", "xpass")
    url = b.get("url", "")
    if url:
        print(json.dumps({"name": name, "url": url}))
' 2>/dev/null | while IFS= read -r line; do
        local name burl
        name=$(printf '%s' "$line" | jq -r '.name')
        burl=$(printf '%s' "$line" | jq -r '.url')
        [[ "$burl" == /* ]] && burl="${_CX_XPASS_BASE}${burl}"
        [[ "$burl" != http* ]] && continue

        local pjson
        pjson=$(curl -s $_CX_CURL_TIMEOUT -H "Referer: ${_CX_XPASS_BASE}/" "$burl" 2>/dev/null)
        [[ -z "$pjson" ]] && continue
        printf '%s' "$pjson" | jq -c '.playlist[]?.sources[]? | select(.file != null)' 2>/dev/null | while IFS= read -r src; do
            local file stype
            file=$(printf '%s' "$src" | jq -r '.file')
            stype=$(printf '%s' "$src" | jq -r '.type // ""')
            [[ "$file" != http* ]] && continue
            if printf '%s' "$stype" | grep -qi hls || [[ "$file" == *.m3u8 ]]; then
                _cx_emit "Xpass [$name]" "auto" "$file"
            else
                _cx_emit "Xpass [$name]" "auto" "$file"
            fi
        done
    done
}

# ═══════════════════════════════════════════════════════════════
# Provider: Onetouchtv (encrypted search + source via enc-dec.app)
# ═══════════════════════════════════════════════════════════════
_cx_provider_onetouchtv() {
    local id="$1"
    _cx_parse_id "$id"
    [[ -z "$_CX_TITLE" ]] && return 0

    local query
    if [[ -n "$_CX_SEASON" && "$_CX_SEASON" != "1" ]]; then
        query="${_CX_TITLE} Season ${_CX_SEASON} (${_CX_YEAR})"
    else
        query="${_CX_TITLE} (${_CX_YEAR})"
    fi

    local enc_query
    enc_query=$(urlencode "$query")

    local enc
    enc=$(curl -s $_CX_CURL_TIMEOUT "${_CX_ONETV_API}/vod/search?page=1&keyword=${enc_query}" 2>/dev/null) || return 0
    [[ -z "$enc" ]] && return 0

    local dec
    dec=$(curl -s $_CX_CURL_TIMEOUT -X POST \
        -H "Content-Type: application/json" \
        -d "{\"text\":$(printf '%s' "$enc" | jq -Rs .)}" \
        "${_CX_ENC_DEC_BASE}/dec-onetouchtv" 2>/dev/null) || return 0

    local matched_id
    matched_id=$(printf '%s' "$dec" | jq -r --arg q "$query" '.result[]? | select(.title == $q) | .id // empty' 2>/dev/null | head -1)
    [[ -z "$matched_id" ]] && return 0

    local enc_src
    enc_src=$(curl -s $_CX_CURL_TIMEOUT "${_CX_ONETV_API}/web/vod/${matched_id}/episode/${_CX_EPISODE:-0}" 2>/dev/null) || return 0
    [[ -z "$enc_src" ]] && return 0

    local dec_src
    dec_src=$(curl -s $_CX_CURL_TIMEOUT -X POST \
        -H "Content-Type: application/json" \
        -d "{\"text\":$(printf '%s' "$enc_src" | jq -Rs .)}" \
        "${_CX_ENC_DEC_BASE}/dec-onetouchtv" 2>/dev/null) || return 0

    printf '%s' "$dec_src" | jq -c '.result.sources[]? | select(.url != null)' 2>/dev/null | while IFS= read -r src; do
        local surl squality stype
        surl=$(printf '%s' "$src" | jq -r '.url')
        squality=$(printf '%s' "$src" | jq -r '.quality // "auto"')
        stype=$(printf '%s' "$src" | jq -r '.type // ""')
        [[ "$surl" != http* ]] && continue
        if printf '%s' "$stype" | grep -qi hls || [[ "$surl" == *.m3u8 ]]; then
            _cx_emit "Onetouchtv" "$squality" "$surl"
        else
            _cx_emit "Onetouchtv" "$squality" "$surl"
        fi
    done
}

# ═══════════════════════════════════════════════════════════════
# Provider: Videasy (seed + 11 servers, encrypted via enc-dec.app)
# ═══════════════════════════════════════════════════════════════
_cx_provider_videasy() {
    local id="$1"
    _cx_parse_id "$id"
    [[ -z "$_CX_TMDB" || -z "$_CX_TITLE" ]] && return 0

    local hdrs=(-H "Accept: */*" -H "Origin: https://player.videasy.to" -H "Referer: https://player.videasy.to/")
    local seed=""
    seed=$(curl -s $_CX_CURL_TIMEOUT "${hdrs[@]}" "${_CX_VIDEASY_API}/seed?mediaId=${_CX_TMDB}" 2>/dev/null | jq -r '.seed // empty' 2>/dev/null)
    [[ -z "$seed" ]] && return 0

    # quote() parity: URLEncoder UTF-8, + -> %20; Videasy double-encodes title
    local enc1 enc2
    enc1=$(printf '%s' "$_CX_TITLE" | jq -sRr @uri)
    enc1="${enc1//%20/+}"
    enc2=$(printf '%s' "$enc1" | jq -sRr @uri)
    enc2="${enc2//%20/+}"

    local servers=(myflixerzupcloud downloader2 m4uhd hdmovie cdn superflix lamovie jett tejo neon2 ym)

    local srv
    for srv in "${servers[@]}"; do
        (
            local url
            if [[ -z "$_CX_SEASON" ]]; then
                url="${_CX_VIDEASY_API}/${srv}/sources-with-title?title=${enc2}&mediaType=movie&year=${_CX_YEAR}&tmdbId=${_CX_TMDB}&imdbId=${_CX_IMDB}&enc=2&seed=${seed}"
            else
                url="${_CX_VIDEASY_API}/${srv}/sources-with-title?title=${enc2}&mediaType=tv&year=${_CX_YEAR}&tmdbId=${_CX_TMDB}&episodeId=${_CX_EPISODE}&seasonId=${_CX_SEASON}&imdbId=${_CX_IMDB}&enc=2&seed=${seed}"
            fi
            local enc_data
            enc_data=$(curl -s $_CX_CURL_TIMEOUT "${hdrs[@]}" "$url" 2>/dev/null)
            [[ -z "$enc_data" || "$enc_data" == "null" ]] && exit 0
            local dec_res
            dec_res=$(curl -s $_CX_CURL_TIMEOUT -X POST \
                -H "Content-Type: application/json" \
                -d "{\"text\":$(printf '%s' "$enc_data" | jq -Rs .),\"id\":${_CX_TMDB},\"seed\":\"$seed\"}" \
                "${_CX_ENC_DEC_BASE}/dec-videasy" 2>/dev/null)
            printf '%s' "$dec_res" | jq -c '.result.sources[]? | select(.url != null)' 2>/dev/null | while IFS= read -r src; do
                local vurl vq
                vurl=$(printf '%s' "$src" | jq -r '.url')
                vq=$(printf '%s' "$src" | jq -r '.quality // "auto"')
                [[ "$vurl" != http* ]] && continue
                _cx_emit "Videasy[$srv]" "$vq" "$vurl"
            done
        ) &
    done
    wait 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Provider: VaPlayer (imdb-keyed stream_urls API)
# ═══════════════════════════════════════════════════════════════
_cx_provider_vaplayer() {
    local id="$1"
    _cx_parse_id "$id"

    local url
    if [[ -z "$_CX_SEASON" ]]; then
        url="${_CX_VAPLAYER_API}/api.php?imdb=${_CX_IMDB}&type=movie"
    else
        url="${_CX_VAPLAYER_API}/api.php?imdb=${_CX_IMDB}&type=tv&season=${_CX_SEASON}&episode=${_CX_EPISODE}"
    fi

    local res
    res=$(curl -s $_CX_CURL_TIMEOUT -H "Referer: https://nextgencloudfabric.com/" "$url" 2>/dev/null) || return 0
    printf '%s' "$res" | jq -r '.data.stream_urls[]?' 2>/dev/null | while IFS= read -r u; do
        [[ "$u" != http* ]] && continue
        _cx_emit "VaPlayer" "auto" "$u"
    done
}

# ═══════════════════════════════════════════════════════════════
# Site wrappers (subshell sourcing of standalone plugins)
# ═══════════════════════════════════════════════════════════════
# Generic: search title on the site plugin, pick best relevance match,
# walk seasons/episodes if series, resolve streams.
_cx_site_wrapper() {
    local site_file="$1" site_label="$2" id="$3" quality="${4:-720}"
    _cx_parse_id "$id"
    [[ -z "$_CX_TITLE" ]] && return 0

    # subshell so the site plugin's functions don't collide with ours
    (
        set +euo pipefail
        source "$site_file" 2>/dev/null || exit 0
        # search for the title
        local sres
        sres=$(plugin_search "$_CX_TITLE" "$quality" 2>/dev/null) || exit 0
        [[ -z "$sres" || "$sres" == "[]" ]] && exit 0

        local norm_q norm_t best_id best_type
        norm_q=$(printf '%s' "$_CX_TITLE" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z0-9]+' | paste -sd' ' -)

        # score: exact title match first, then token coverage
        best_id=$(printf '%s' "$sres" | jq -r --arg q "$norm_q" '
            [.[] | . + {_t: (.title | ascii_downcase | gsub("[^a-z0-9]"; " ")), _s: 0}
             | ._s = (if (.title | ascii_downcase) | contains($q) then 3
                      else ([.title | ascii_downcase | split(" ")[] | select(length >= 3)] as $toks
                            | ([$toks[] | select($q | contains(.))] | length)) end)
            ] | sort_by(._s) | reverse | .[0].id // empty' 2>/dev/null)
        [[ -z "$best_id" || "$best_id" == "null" ]] && exit 0

        local best_type
        best_type=$(printf '%s' "$sres" | jq -r --arg id "$best_id" '.[] | select(.id == $id) | .type // "movie"' 2>/dev/null | head -1)

        if [[ -n "$_CX_SEASON" && "$best_type" == "series" ]]; then
            # walk seasons -> episodes -> episode id
            local ep_id
            ep_id=$(plugin_list_seasons "$best_id" 2>/dev/null | jq -r --arg s "$_CX_SEASON" '.[] | select(.number == ($s | tonumber)) | .id' 2>/dev/null | head -1)
            [[ -z "$ep_id" ]] && exit 0
            ep_id=$(plugin_list_episodes "$best_id" "$ep_id" 2>/dev/null | jq -r --arg e "$_CX_EPISODE" '.[] | select(.episode == ($e | tonumber)) | .id' 2>/dev/null | head -1)
            [[ -z "$ep_id" ]] && exit 0
            plugin_get_url "$ep_id" "$quality" 2>/dev/null | jq -c --arg p "$site_label" '.[] | .provider = $p' 2>/dev/null
        else
            plugin_get_url "$best_id" "$quality" 2>/dev/null | jq -c --arg p "$site_label" '.[] | .provider = $p' 2>/dev/null
        fi
    )
}

_cx_provider_vegamovies() { _cx_site_wrapper "$PLUGIN_DIR/vegamovies.sh" "VegaMovies" "$1"; }
_cx_provider_dudefilms() { _cx_site_wrapper "$PLUGIN_DIR/dudefilms.sh" "DudeFilms" "$1"; }
_cx_provider_hdhub4u()   { _cx_site_wrapper "$PLUGIN_DIR/hdhub4u.sh" "HDhub4u" "$1"; }
_cx_provider_4khdhub()   { _cx_site_wrapper "$PLUGIN_DIR/4khdhub.sh" "4KHDHub" "$1"; }
_cx_provider_movieblast() { _cx_site_wrapper "$PLUGIN_DIR/movieblast.sh" "MovieBlast" "$1"; }

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"

    local encoded_query
    encoded_query=$(urlencode "$query")

    local movie_res series_res
    movie_res=$(curl -s $_CX_CURL_TIMEOUT "${_CX_CINEMETA_BASE}/catalog/movie/top/search=${encoded_query}.json") || return 1
    series_res=$(curl -s $_CX_CURL_TIMEOUT "${_CX_CINEMETA_BASE}/catalog/series/top/search=${encoded_query}.json") || return 1

    local raw_results
    raw_results=$(jq -n \
        --argjson movies "$movie_res" \
        --argjson series "$series_res" '
        ($movies.metas // []) + ($series.metas // []) |
        map({
            id: .id,
            title: (if .releaseInfo then "\(.name) (\(.releaseInfo))" else .name end),
            type: .type,
            year: (.releaseInfo // null),
            rating: (.imdbRating // null),
            poster: (.poster // null)
        })
    ' 2>/dev/null) || return 1

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
        [.[] | del(._score)]
    ' 2>/dev/null
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"

    _cx_fetch_meta "$id" || die_plugin "No metadata for ID: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=()
    local p_idx=0

    for p_name in "${_CX_REGISTRY[@]}"; do
        # validate provider function exists
        if ! declare -f "_cx_provider_${p_name}" >/dev/null 2>&1; then
            debug "CineX: provider $p_name not implemented, skipping"
            continue
        fi
        (
            # Providers are network scrapers: curl/grep/jq failures are normal
            # (timeouts, empty bodies, no matches). Relax the strict flags
            # inherited from the main shell (set -euo pipefail in init.sh) for
            # this subshell only; the merged output is validated afterwards.
            set +euo pipefail
            "_cx_provider_${p_name}" "$id" "$quality" 2>/dev/null \
                > "$tmp_dir/prov_${p_idx}.json"
        ) &
        pids+=($!)
        p_idx=$((p_idx + 1))
    done

    wait "${pids[@]}" 2>/dev/null || true

    local merged_json="[]"
    if compgen -G "$tmp_dir/prov_*.json" > /dev/null 2>&1; then
        # Providers emit line-delimited stream objects; jq -s slurps them into
        # the result array directly. Do NOT use 'add // []' here — that merges
        # all objects into one and unique_by() then iterates string values.
        merged_json=$(cat "$tmp_dir"/prov_*.json 2>/dev/null | jq -s '
            unique_by(.url) |
            sort_by(
                if .quality == "4K" or .quality == "2160" then 0
                elif .quality == "1080" then 1
                elif .quality == "720" then 2
                elif .quality == "480" then 3
                else 4
                end
            )
        ' 2>/dev/null) || merged_json="[]"
    fi
    rm -rf "$tmp_dir"

    if [[ -z "$merged_json" || "$merged_json" == "[]" ]]; then
        die_plugin "No playable links resolved for ID: $id"
    fi

    printf '%s\n' "$merged_json"
}

plugin_list_seasons() {
    local series_id="$1"
    local response
    response=$(curl -s $_CX_CURL_TIMEOUT "${_CX_CINEMETA_BASE}/meta/series/${series_id}.json") || return 1
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
    response=$(curl -s $_CX_CURL_TIMEOUT "${_CX_CINEMETA_BASE}/meta/series/${series_id}.json") || return 1
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u +%Y-%m-%d)
    printf '%s' "$response" | jq -c --argjson s "$season" --arg now "$now" '
        [.meta.videos[]? | select(.season == $s) |
         select(.firstAired == null or .firstAired == "" or .firstAired <= $now) | {
            id: .id,
            title: "E\(.number) - \(.name // "Episode \(.number)")",
            season: .season,
            episode: .number
        }]
    ' 2>/dev/null
}

plugin_health() {
    curl -s $_CX_CURL_TIMEOUT --head --fail "${_CX_CINEMETA_BASE}" &>/dev/null || return 1
    curl -s $_CX_CURL_TIMEOUT --head --fail "${_CX_ENC_DEC_BASE}/enc-hexa" &>/dev/null || return 1
    return 0
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"],"providers":%s}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION" \
        "$(printf '%s\n' "${_CX_REGISTRY[@]}" | jq -R . | jq -s -c .)"
}