#!/usr/bin/env bash
# 4khdhub.sh — 4KHDHub plugin for movie-cli
# Movies + series from 4khdhub.one (via hubcloud/hubdrive mirror chain)
# Reverse-engineered from the CloudStream FourKHDHub extension (phisher98 repo)
# Resolution chain: site detail page → hubcloud.ist/drive/ID or hubdrive.tips/file/ID
#   → resolver page (gamerxyt.com/hubcloud.php) → direct .mkv (workers.dev / fsl-buckets)
#   or pixel.hubcloud.cx → dl.php?link=video-downloads.googleusercontent.com

[[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"
[[ -f "${LIB_DIR:-}/cinemeta.sh" ]] && source "${LIB_DIR}/cinemeta.sh"

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="4KHDHub"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="4K movies and series from 4KHDHub (HubCloud/HubDrive mirror chain)"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_4KH_BASE="https://4khdhub.one"
_4KH_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
_4KH_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_4KH_UA")
_4KH_ALLOW_HOSTS=""
# Live domain list — same source the CloudStream FourKHDHub extension uses
# (phisher98/TVVVV/domains.json). Auto-rotation: sites move domains to dodge
# blocking; when the redirect dies, a hardcoded BASE_URL kills the plugin.
_4KH_DOMAINS_URL="https://raw.githubusercontent.com/phisher98/TVVVV/refs/heads/main/domains.json"
_4KH_DOMAINS_CACHE_KEY="4khdhub_domains"
_4KH_BASE_USER_SET=0   # 1 = user set BASE_URL in conf (wins over auto-rotation)

# Stream-candidate policy as DATA (algorithm lives in lib/pluginsdk.sh)
_4KH_REJECT_GLOBS='*tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*hdhub4u.ms*|*googlesyndication*'
_4KH_FAMILY_GLOBS='*workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*'
_4KH_PIXEL_GLOBS='*pixel.hubcloud.cx*|*gpdl.hubcloud.cx*'

_load_4kh_config() {
    sdk_conf_load "$CONF_DIR/4khdhub.conf" KH BASE_URL ALLOW_HOSTS
    [[ -n "${KH_BASE_URL+x}" && -n "${KH_BASE_URL}" ]] && { _4KH_BASE="$KH_BASE_URL"; _4KH_BASE_USER_SET=1; }
    [[ -n "${KH_ALLOW_HOSTS+x}" ]] && _4KH_ALLOW_HOSTS="$KH_ALLOW_HOSTS"
    # No baked-in Referer on this site's requests — SDK mirrors that.
    sdk_http "$_4KH_UA"
}

# Auto domain rotation (CloudStream-style): fetch the live domain list once a
# day, use the returned domain unless the user pinned BASE_URL in conf.
_4kh_load_domains() {
    [[ "$_4KH_BASE_USER_SET" == "1" ]] && return 0
    local dom
    dom=$(sdk_rotate_domain "$_4KH_DOMAINS_CACHE_KEY" "$_4KH_DOMAINS_URL" \
        "4khdhub" "$_4KH_BASE" "4KHDHub" "$_4KH_UA") || return 0
    [[ -z "$dom" ]] && return 0
    _4KH_BASE="$dom"
}

# Fuzzy host matching for resolver links (CloudStream-style: match broadly,
# let verify_streams filter garbage). See lib/pluginsdk.sh sdk_is_stream_candidate.
_4kh_is_stream_candidate() {
    sdk_is_stream_candidate "$1" "$_4KH_ALLOW_HOSTS" "$_4KH_REJECT_GLOBS" "$_4KH_FAMILY_GLOBS"
}

_4kh_quality() {
    # Quality from filename: 2160p/4K → 4K (standalone token — "DS4K"/"S4K"
    # release tags must NOT match), 1080p → 1080, etc.
    sdk_quality_token "$1"
}

_4kh_stream_json() {
    # Percent-encode the URL: resolver pages emit raw spaces/brackets in
    # filenames which curl's globbing chokes on (rc=3).
    sdk_stream_json_encoded "4khdhub" "$(sdk_quality_token "$1")" "$1"
}

# ═══════════════════════════════════════════════════════════════
# Resolver walk: hubcloud drive page → resolver page → direct links
# ═══════════════════════════════════════════════════════════════

# Resolve one hubcloud.*/drive/ID page into candidate stream URLs.
# Follows HubCloud.kt logic: drive page → #download href → resolver → btn links.
_4kh_resolve_drive() {
    sdk_resolve_drive "$1" _4kh_is_stream_candidate 1 "$_4KH_PIXEL_GLOBS"
}

# Resolve any supported mirror URL to candidate stream URLs
_4kh_resolve_link() {
    local url="$1"
    case "$url" in
        *hubdrive*|*hubcloud*)
            _4kh_resolve_drive "$url"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

# Parse movie cards: <a href="/slug/" class="movie-card" ...> ... <div class="movie-card-title">TITLE</div>
# With a candidate title, only fuzzy-matched cards are emitted.
_4kh_parse_movie_cards() {
    local html_page="$1" ctitle="${2:-}" cyear="${3:-}"
    printf '%s' "$html_page" | python3 -c '
import sys, re, json
html = sys.stdin.read()
ctitle = sys.argv[1] if len(sys.argv) > 1 else ""
cyear = sys.argv[2] if len(sys.argv) > 2 else ""
ctnorm = re.sub(r"[^a-z0-9]", "", ctitle.lower()) if ctitle else ""
out = []
for m in re.finditer(r"<a href=\"(/[^\"]+)\"[^>]*class=\"movie-card\"[^>]*>(.*?)</a>", html, re.S):
    slug, inner = m.group(1), m.group(2)
    title_m = re.search(r"movie-card-title[^>]*>([^<]+)", inner)
    if not title_m:
        continue
    title = title_m.group(1).strip()
    if ctnorm:
        tnorm = re.sub(r"[^a-z0-9]", "", title.lower())
        if ctnorm not in tnorm and tnorm not in ctnorm:
            continue
    typ = "series" if "-series-" in slug else "movie"
    item = {"id": slug.strip("/"), "title": title, "type": typ}
    if cyear:
        item["year"] = cyear
    out.append(item)
print(json.dumps(out))
' "$ctitle" "$cyear" 2>/dev/null || printf '[]'
}

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_4kh_config
    _4kh_load_domains

    local encoded_query
    encoded_query=$(urlencode "$query")

    local html
    html=$(curl "${_4KH_CURL[@]}" "${_4KH_BASE}/?s=${encoded_query}" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    local wp_results
    wp_results=$(_4kh_parse_movie_cards "$html")

    # Cinemeta fallback (shared orchestrator): re-search the site's WP ?s=
    # endpoint per canonical title when the primary search is sparse.
    cinemeta_search_fallback "$query" "$wp_results" _4kh_research_site
}

# Cinemeta research callback: WP site re-search by canonical title+year.
_4kh_research_site() {
    local cname="$1" cyear="$2"
    local site_html
    site_html=$(curl "${_4KH_CURL[@]}" "${_4KH_BASE}/?s=$(urlencode "${cname} ${cyear}")" 2>/dev/null || true)
    [[ -z "$site_html" ]] && return 0
    _4kh_parse_movie_cards "$site_html" "$cname" "$cyear"
}

# Fan-out worker: resolve ONE mirror link into stream JSON objects.
_4kh_get_url_worker() {
    local link="$1"
    local streams
    streams=$(_4kh_resolve_link "$link") || return 0
    [[ -z "$streams" ]] && return 0
    local su
    while IFS= read -r su; do
        [[ -z "$su" ]] && continue
        # Skip SAMPLE/trailer preview files (uploaders ship a 5-min
        # "SAMPLE-*.mkv" next to the real movie; it outranks it at
        # the same resolution in sort_streams)
        [[ "${su,,}" == *sample* ]] && continue
        _4kh_stream_json "$su"
    done <<< "$streams"
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_4kh_config
    _4kh_load_domains

    local series_id="" season="" episode=""
    # Episode ID convention: series_id:season:episode
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi

    local detail_url
    if [[ -n "$series_id" ]]; then
        detail_url="${_4KH_BASE}/${series_id}/"
    else
        detail_url="${_4KH_BASE}/${id}/"
    fi

    local html
    html=$(curl "${_4KH_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "4KHDHub detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty 4KHDHub detail page"

    # Extract mirror links. For a series episode, only links inside the
    # episode-download-item whose file title matches SxxEyy.
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
        for u in re.findall(r"href=\"(https://(?:hubcloud|hubdrive)[^\"]+)\"", block):
            print(u)
' "$season" "$episode" 2>/dev/null || true)
    else
        mirror_links=$(printf '%s' "$html" | grep -oE 'href="https://(hubcloud|hubdrive)[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    fi

    [[ -z "$mirror_links" ]] && die_plugin "No mirror links found on 4KHDHub page for: $id"

    # Resolve all mirror links (parallel — each is 2-3 HTTP hops)
    local -a _links=()
    mapfile -t _links <<< "$mirror_links"
    local merged
    merged=$(sdk_fanout _4kh_get_url_worker "${_links[@]}")
    [[ -z "$merged" || "$merged" == "[]" ]] && die_plugin "No playable links resolved for: $id"
    printf '%s\n' "$merged"
}

plugin_list_seasons() {
    local series_id="$1"
    _load_4kh_config
    _4kh_load_domains

    local html
    html=$(curl "${_4KH_CURL[@]}" "${_4KH_BASE}/${series_id}/" 2>/dev/null) || return 1

    # Parse season blocks: <div class="episode-number pr-4">S05</div>
    printf '%s' "$html" | python3 -c '
import sys, re, json
html = sys.stdin.read()
seen = {}
for m in re.finditer(r"episode-number[^>]*>\s*S(\d+)", html):
    n = int(m.group(1))
    if n not in seen:
        seen[n] = True
out = [{"id": str(n), "title": "Season %d" % n, "number": n} for n in sorted(seen)]
print(json.dumps(out))
' 2>/dev/null
}

plugin_list_episodes() {
    local series_id="$1"
    local season="$2"
    _load_4kh_config
    _4kh_load_domains

    local html
    html=$(curl "${_4KH_CURL[@]}" "${_4KH_BASE}/${series_id}/" 2>/dev/null) || return 1

    # Parse episode-download-item blocks within the given season; dedupe by episode number
    printf '%s' "$html" | python3 -c '
import sys, re, json
html = sys.stdin.read()
series_id, season = sys.argv[1], sys.argv[2]
pat = re.compile(r"S%02dE(\d{1,2})" % int(season))
seen = {}
for m in re.finditer(r"episode-download-item(.*?)(?=episode-download-item|$)", html, re.S):
    block = m.group(1)
    em = pat.search(block)
    if not em:
        continue
    ep = int(em.group(1))
    if ep in seen:
        continue
    title_m = re.search(r"episode-file-title[^>]*>\s*([^<]+)", block)
    title = title_m.group(1).strip() if title_m else "Episode %d" % ep
    seen[ep] = {"id": "%s:%d:%d" % (series_id, int(season), ep),
                "title": "E%02d - %s" % (ep, title[:80]),
                "season": int(season), "episode": ep}
out = [seen[k] for k in sorted(seen)]
print(json.dumps(out))
' "$series_id" "$season" 2>/dev/null
}

plugin_health() {
    _load_4kh_config
    _4kh_load_domains
    curl -s --connect-timeout 8 --max-time 15 -o /dev/null -w '%{http_code}' \
        -A "$_4KH_UA" "${_4KH_BASE}/?s=test" 2>/dev/null | grep -qE '^200$'
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
