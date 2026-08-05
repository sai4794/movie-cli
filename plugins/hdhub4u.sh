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
_H4U_ALLOW_HOSTS=""
# Live domain list — same source the CloudStream HDhub4u extension uses
# (phisher98/TVVVV/domains.json). Auto-rotation: sites move domains to dodge
# blocking; when the redirect dies, a hardcoded BASE_URL kills the plugin.
_H4U_DOMAINS_URL="https://raw.githubusercontent.com/phisher98/TVVVV/refs/heads/main/domains.json"
_H4U_DOMAINS_CACHE_KEY="hdhub4u_domains"
_H4U_BASE_USER_SET=0   # 1 = user set BASE_URL in conf (wins over auto-rotation)

# Rebuild the curl array — Referer depends on the current base
_h4u_rebuild_curl() {
    _H4U_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_H4U_UA" -H "Referer: ${_H4U_BASE}/")
}

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
            BASE_URL) _H4U_BASE="$value"; _H4U_BASE_USER_SET=1 ;;
            SEARCH_URL) _H4U_SEARCH="$value" ;;
            ALLOW_HOSTS) _H4U_ALLOW_HOSTS="$value" ;;
        esac
    done < "$conf_file"
    _h4u_rebuild_curl
}

# Auto domain rotation (CloudStream-style): fetch the live domain list once a
# day, use the returned domain unless the user pinned BASE_URL in conf.
_h4u_load_domains() {
    [[ "$_H4U_BASE_USER_SET" == "1" ]] && return 0

    local cached=""
    if declare -f cache_get >/dev/null 2>&1; then
        cached=$(cache_get "$_H4U_DOMAINS_CACHE_KEY" 86400 2>/dev/null || true)
    fi
    if [[ -z "$cached" ]]; then
        cached=$(curl -s --connect-timeout 6 --max-time 15 -A "$_H4U_UA" "$_H4U_DOMAINS_URL" 2>/dev/null || true)
        if [[ -n "$cached" ]] && printf '%s' "$cached" | jq -e . >/dev/null 2>&1; then
            if declare -f cache_set >/dev/null 2>&1; then
                cache_set "$_H4U_DOMAINS_CACHE_KEY" "$cached" || true
            fi
        else
            cached=""
        fi
    fi
    [[ -z "$cached" ]] && return 0

    local dom
    dom=$(printf '%s' "$cached" | jq -r '.["HDHUB4u"] // empty' 2>/dev/null || true)
    [[ -z "$dom" || "$dom" == "null" ]] && return 0
    dom="${dom%/}"
    if [[ "$dom" != "$_H4U_BASE" ]]; then
        debug "HDhub4u domain rotated: $_H4U_BASE → $dom"
        _H4U_BASE="$dom"
        _h4u_rebuild_curl
    fi
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

# Fuzzy host matching for resolver links (CloudStream-style: match broadly,
# let verify_streams filter garbage). Accepts a link as a stream candidate if:
#   1. host contains a known file-host family (substring match handles rotated
#      subdomains: workers.dev, r2.cloudflarestorage, fsl*, pixeldrain,
#      hubcloud, hubdrive, filescdn, aiplex, googleusercontent), OR
#   2. URL looks like a direct media file (.mkv/.mp4/.m3u8/.webm/.ts/.flv), OR
#   3. host matches a user-configured ALLOW_HOSTS token (comma-separated
#      substrings in $CONF_DIR/hdhub4u.conf — add new hosts without editing
#      the plugin).
# Hard rejects: telegram, ad, navigation, and shortener links.
_h4u_is_stream_candidate() {
    local link="$1"
    local lower
    lower=$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')

    # Hard rejects — these are never streams
    case "$lower" in
        *tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*hdhub4u.ms*|*googlesyndication*)
            return 1 ;;
    esac

    # User-configured host allowlist wins over everything
    if [[ -n "$_H4U_ALLOW_HOSTS" ]]; then
        local host allow
        host=$(printf '%s' "$lower" | sed -E 's|^https?://([^/]+).*|\1|')
        local -a allow_arr=()
        IFS=',' read -r -a allow_arr <<< "$_H4U_ALLOW_HOSTS"
        for allow in "${allow_arr[@]}"; do
            allow="${allow,,}"
            [[ -n "$allow" && "$host" == *"$allow"* ]] && return 0
        done
    fi

    # Known file-host families (substring match = fuzzy across rotated hosts)
    case "$lower" in
        *workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*)
            return 0 ;;
    esac

    # Direct media URL heuristic — video extension anywhere in the URL
    case "$lower" in
        *.mkv*|*.mp4*|*.webm*|*.m3u8*|*.flv*|*.mov*|*.avi*|*.ts*)
            return 0 ;;
    esac

    return 1
}

_h4u_resolve_resolver() {
    local resolver_url="$1"
    local page

    page=$(curl "${_H4U_CURL[@]}" "$resolver_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    printf '%s' "$page" | grep -oE '<a[^>]*href="https?://[^"]+"[^>]*class="[^"]*btn[^"]*"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        case "$link" in
            *pixel.hubcloud.cx*|*gpdl.hubcloud.cx*)
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
            *)
                # Fuzzy match — no exact host allowlist; unknown-but-plausible
                # mirrors are accepted here and filtered by verify_streams later
                if _h4u_is_stream_candidate "$link"; then
                    printf '%s\n' "$link"
                fi
                ;;
        esac
    done
}

_h4u_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final url_eff

    # Follow the redirect chain: pixel/gpdl → pixel.*.workers.dev → dl.php?link=...
    # The final URL itself carries the link param (gpdl chain lands on dl.php);
    # the page body references it too (pixel chain). Check both.
    page=$(curl "${_H4U_CURL[@]}" -o /tmp/h4u_pixel_body.$$ -w '%{url_effective}' "$pixel_url" 2>/dev/null || true)
    url_eff="$page"
    page=$(cat /tmp/h4u_pixel_body.$$ 2>/dev/null || true)
    rm -f /tmp/h4u_pixel_body.$$
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' ]*dl\.php\?link=[^"'"'"' ]+' | head -1 2>/dev/null || true)
    if [[ -z "$dl_url" && "$url_eff" == *"dl.php?link="* ]]; then
        dl_url="$url_eff"
    fi
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
    _h4u_load_domains

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
    _h4u_load_domains

    local series_id="" season="" episode=""
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi

    local detail_url
    if [[ -n "$series_id" ]]; then
        detail_url="${_H4U_BASE}/${series_id}/"
    else
        detail_url="${_H4U_BASE}/${id}/"
    fi
    local html
    html=$(curl "${_H4U_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "HDhub4u detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty HDhub4u detail page"

    # Extract mirror links — only hubdrive/hubcloud hosts are resolvable
    # (hdstream4u → morencius "Downloads disabled", hubcdn.sbs → ad shortener)
    local mirror_links
    if [[ -n "$series_id" ]]; then
        # Series episode id "series:season:episode" — the post page lists
        # single-episode links as "E01 – <a href=hubdrive...>". Select only
        # the anchor for the requested episode number.
        mirror_links=$(printf '%s' "$html" | python3 -c '
import sys, re
html = sys.stdin.read()
episode = int(sys.argv[1])
pat = re.compile(r"E%02d\s*(?:&#8211;|&ndash;|&mdash;|-)?\s*<a href=\"(https://(?:hubdrive|hubcloud)[^\"]+)\"" % episode)
for m in pat.finditer(html):
    print(m.group(1))
' "$episode" 2>/dev/null || true)
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

plugin_list_seasons() {
    local series_id="$1"
    _load_h4u_config
    _h4u_load_domains

    local html
    html=$(curl "${_H4U_CURL[@]}" "${_H4U_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # Season-pack post (e.g. "All of Us Are Dead (Season 1) ... ALL Episodes").
    # Extract the season number from the title; fall back to 1.
    local season
    season=$(printf '%s' "$html" | grep -oiE 'Season [0-9]+' | head -1 | grep -oE '[0-9]+' 2>/dev/null || true)
    [[ -z "$season" ]] && season="1"

    printf '[{"id":"%s","title":"Season %s","number":%s}]\n' "$season" "$season" "$season"
}

plugin_list_episodes() {
    local series_id="$1"
    local season="$2"
    _load_h4u_config
    _h4u_load_domains

    local html
    html=$(curl "${_H4U_CURL[@]}" "${_H4U_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # Single-episode links: "E01 – <a href=hubdrive...>". One link per episode.
    printf '%s' "$html" | python3 -c '
import sys, re, json
html = sys.stdin.read()
series_id, season = sys.argv[1], sys.argv[2]
out = []
for m in re.finditer(r"E(\d{1,2})\s*(?:&#8211;|&ndash;|&mdash;|-)?\s*<a href=\"https://(?:hubdrive|hubcloud)[^\"]+\"", html):
    ep = int(m.group(1))
    out.append({"id": "%s:%s:%d" % (series_id, season, ep),
                "title": "Episode %d" % ep,
                "season": int(season), "episode": ep})
# Dedupe by episode number, sort ascending
seen = {}
for e in out:
    seen[e["episode"]] = e
result = [seen[k] for k in sorted(seen)]
print(json.dumps(result))
' "$series_id" "$season" 2>/dev/null || printf '[]'
}

plugin_health() {
    _load_h4u_config
    _h4u_load_domains
    curl -s --connect-timeout 8 --max-time 15 -o /dev/null -w '%{http_code}' \
        -A "$_H4U_UA" -H "Referer: ${_H4U_BASE}/" \
        -G "$_H4U_SEARCH" --data-urlencode "q=test" \
        --data-urlencode "query_by=post_title" --data-urlencode "limit=1" 2>/dev/null | grep -qE '^200$'
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
