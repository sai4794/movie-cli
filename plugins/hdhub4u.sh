#!/usr/bin/env bash
# hdhub4u.sh — HDhub4u plugin for movie-cli
# Movies + series from new4.hdhub4u.cl (Hindi/English content)
# Reverse-engineered from the CloudStream HDhub4u extension (phisher98 repo)
# Search: Typesense JSON API (search.pingora.fyi) — GET with query params
#   (POST is 403'd; wp-json REST API is disabled for guests)
# Resolution: detail page → hubdrive.tips/file/ID → hubcloud.cx/drive/ID
#   → resolver (gamerxyt.com/hubcloud.php) → direct .mkv (fsl-buckets / workers.dev)
#   Known dead hosts (skipped): hdstream4u.com (morencius "Downloads disabled"),
#   hubcdn.sbs (bonuscaf ad shortener), gadgetsweb.xyz (shortener chain)

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="HDhub4u"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies and series from HDhub4u (Hindi/English, via HubDrive/HubCloud)"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_H4U_BASE="https://new4.hdhub4u.cl"
_H4U_SEARCH="https://search.pingora.fyi/collections/post/documents/search"
_H4U_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
_H4U_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_H4U_UA" -H "Referer: ${_H4U_BASE}/")

_load_h4u_config() {
    local conf_file="$CONF_DIR/hdhub4u.conf"
    [[ -f "$conf_file" ]] || return 0
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
            BASE_URL) _H4U_BASE="$value" ;;
            SEARCH_URL) _H4U_SEARCH="$value" ;;
        esac
    done < "$conf_file"
}

# ═══════════════════════════════════════════════════════════════
# Resolver walk: hubdrive file page → hubcloud drive → resolver → direct links
# ═══════════════════════════════════════════════════════════════

# hubdrive.*/file/ID page embeds a link to the hubcloud drive page
_h4u_resolve_hubdrive() {
    local file_url="$1"
    local page hc_url

    page=$(curl "${_H4U_CURL[@]}" "$file_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    hc_url=$(printf '%s' "$page" | grep -oE 'href="https://hubcloud[^"]*/drive/[^"]+"' | head -1 | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
    [[ -z "$hc_url" ]] && return 1

    _h4u_resolve_drive "$hc_url"
}

# hubcloud.*/drive/ID → #download href → resolver page → direct links
_h4u_resolve_drive() {
    local drive_url="$1"
    local page href base

    page=$(curl "${_H4U_CURL[@]}" "$drive_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    if [[ "$drive_url" == *"hubcloud.php"* ]]; then
        href="$drive_url"
    else
        href=$(printf '%s' "$page" | grep -oE 'id="download" href="[^"]+"' | head -1 | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
        [[ -z "$href" ]] && return 1
        if [[ "$href" != http* ]]; then
            base=$(printf '%s' "$drive_url" | sed -E 's|^(https?://[^/]+).*|\1|')
            href="${base}/${href#/}"
        fi
    fi

    _h4u_resolve_resolver "$href"
}

_h4u_resolve_resolver() {
    local resolver_url="$1"
    local page

    page=$(curl "${_H4U_CURL[@]}" "$resolver_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    printf '%s' "$page" | grep -oE '<a[^>]*href="https?://[^"]+"[^>]*class="[^"]*btn[^"]*"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        case "$link" in
            *pixel.hubcloud.cx*)
                _h4u_resolve_pixel "$link"
                ;;
            *pixeldrain*)
                # pixeldrain.dev/u/ID → API form /api/file/ID?download (HubCloud.kt logic)
                if [[ "$link" == *"/api/file/"* || "$link" == *"download"* ]]; then
                    printf '%s\n' "$link"
                else
                    local pd_base pd_id
                    pd_base=$(printf '%s' "$link" | sed -E 's|^(https?://[^/]+).*|\1|')
                    pd_id="${link##*/}"
                    printf '%s\n' "${pd_base}/api/file/${pd_id}?download"
                fi
                ;;
            *workers.dev*|*fsl-buckets*|*filescdn*|*aiplexmedia*|*.mkv*|*.mp4*)
                printf '%s\n' "$link"
                ;;
            *tg/go*|*snvhost*|*one.one.one.one*|*google.com*|*hubcloud.cx/drive*|*tinyurl*|*t.me*|*HDhub4u.ms*)
                ;;
        esac
    done
}

_h4u_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final

    page=$(curl "${_H4U_CURL[@]}" "$pixel_url" 2>/dev/null) || return 1
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' ]*dl\.php\?link=[^"'"'"' ]+' | head -1 2>/dev/null || true)
    [[ -z "$dl_url" ]] && return 1
    final=$(printf '%s' "$dl_url" | sed -E 's/.*link=//' | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || true)
    [[ -z "$final" ]] && return 1
    printf '%s\n' "$final"
}

_h4u_resolve_link() {
    local url="$1"
    case "$url" in
        *hubdrive*)
            _h4u_resolve_hubdrive "$url"
            ;;
        *hubcloud*)
            _h4u_resolve_drive "$url"
            ;;
    esac
}

_h4u_quality() {
    local s="$1"
    if [[ "$s" =~ (2160[pP]|(^|[^a-zA-Z0-9])4[Kk]([^a-zA-Z0-9]|$)) ]]; then printf '4K'
    elif [[ "$s" =~ (1440[pP]|2[Kk]) ]]; then printf '1440'
    elif [[ "$s" =~ 1080[pP] ]]; then printf '1080'
    elif [[ "$s" =~ 720[pP] ]]; then printf '720'
    elif [[ "$s" =~ 480[pP] ]]; then printf '480'
    elif [[ "$s" =~ 360[pP] ]]; then printf '360'
    else printf 'auto'
    fi
}

_h4u_stream_json() {
    local url="$1"
    local enc qual
    enc=$(printf '%s' "$url" | python3 -c '
import sys, urllib.parse
# brackets/spaces/plus must be encoded — curl globbing breaks on raw [] and rc=3
print(urllib.parse.quote(sys.stdin.read().strip(), safe=":/?&=%,.+-_()~"))
' 2>/dev/null || printf '%s' "$url")
    qual=$(_h4u_quality "$url")
    jq -nc --arg u "$enc" --arg q "$qual" '{quality: $q, url: $u, size: "unknown", provider: "hdhub4u"}'
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_h4u_config

    # Typesense search API — GET with query params (POST → 403)
    local response
    response=$(curl -s --connect-timeout 8 --max-time 25 \
        -A "$_H4U_UA" \
        -H "Referer: ${_H4U_BASE}/" \
        -G "$_H4U_SEARCH" \
        --data-urlencode "q=$query" \
        --data-urlencode "query_by=post_title,category,stars,director,imdb_id" \
        --data-urlencode "query_by_weights=4,2,2,2,4" \
        --data-urlencode "sort_by=sort_by_date:desc" \
        --data-urlencode "limit=15" \
        --data-urlencode "highlight_fields=none" \
        --data-urlencode "use_cache=true" \
        --data-urlencode "page=1" 2>/dev/null) || return 1
    [[ -z "$response" ]] && return 1

    printf '%s' "$response" | jq -c '
        [.hits[]?.document |
        {
            id: (.permalink | sub("^https?://[^/]+"; "") | gsub("^/"; "") | gsub("/$"; "")),
            title: .post_title,
            type: (if (.post_title | test("TVSeries|Season [0-9]"; "i")) then "series" else "movie" end),
            year: (if (.post_title | test("\\((19|20)[0-9]{2}\\)")) then (.post_title | capture("\\((?<year>(19|20)[0-9]{2})\\)").year) else null end),
            rating: null,
            poster: .post_thumbnail
        }]
    ' 2>/dev/null
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_h4u_config

    local series_id="" season="" episode=""
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi

    local detail_url="${_H4U_BASE}/${id}/"
    local html
    html=$(curl "${_H4U_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "HDhub4u detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty HDhub4u detail page"

    # Extract mirror links — only hubdrive/hubcloud hosts are resolvable
    # (hdstream4u → morencius "Downloads disabled", hubcdn.sbs → ad shortener)
    local mirror_links
    if [[ -n "$series_id" ]]; then
        mirror_links=$(printf '%s' "$html" | python3 -c '
import sys, re
html = sys.stdin.read()
season, episode = sys.argv[1], sys.argv[2]
pat = re.compile(r"S%02dE%02d" % (int(season), int(episode)))
for m in re.finditer(r"episode-download-item(.*?)(?=episode-download-item|$)", html, re.S):
    block = m.group(1)
    if pat.search(block):
        for u in re.findall(r"href=\"(https://(?:hubdrive|hubcloud)[^\"]+)\"", block):
            print(u)
' "$season" "$episode" 2>/dev/null || true)
    else
        mirror_links=$(printf '%s' "$html" | grep -oE 'href="https://(hubdrive|hubcloud)[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    fi

    [[ -z "$mirror_links" ]] && die_plugin "No resolvable mirror links on HDhub4u page for: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local streams=""
            streams=$(_h4u_resolve_link "$link" 2>/dev/null || true)
            if [[ -n "$streams" ]]; then
                printf '%s\n' "$streams" | while IFS= read -r su; do
                    [[ -z "$su" ]] && continue
                    # Skip SAMPLE/trailer preview files (uploaders ship a 5-min
                    # "SAMPLE-*.mkv" next to the real movie; it outranks it at
                    # the same resolution in sort_streams)
                    [[ "${su,,}" == *sample* ]] && continue
                    _h4u_stream_json "$su"
                done > "$tmp_dir/out_${idx}.json"
            fi
        ) &
        pids+=($!)
        idx=$((idx + 1))
    done <<< "$mirror_links"

    wait "${pids[@]}" 2>/dev/null || true

    local merged="[]"
    if compgen -G "$tmp_dir/out_*.json" > /dev/null 2>&1; then
        merged=$(cat "$tmp_dir"/out_*.json 2>/dev/null | jq -s '.' 2>/dev/null) || merged="[]"
    fi
    rm -rf "$tmp_dir"

    [[ -z "$merged" || "$merged" == "[]" ]] && die_plugin "No playable links resolved for: $id"
    printf '%s\n' "$merged"
}

plugin_health() {
    _load_h4u_config
    curl -s --connect-timeout 8 --max-time 15 -o /dev/null -w '%{http_code}' \
        -A "$_H4U_UA" -H "Referer: ${_H4U_BASE}/" \
        -G "$_H4U_SEARCH" --data-urlencode "q=test" \
        --data-urlencode "query_by=post_title" --data-urlencode "limit=1" 2>/dev/null | grep -qE '^200$'
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
