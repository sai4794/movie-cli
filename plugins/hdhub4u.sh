#!/usr/bin/env bash
# hdhub4u.sh — HDhub4u plugin for movie-cli
# Movies + series from new5.hdhub4u.cl (Hindi/English content)
# Reverse-engineered from the CloudStream HDhub4u extension (phisher98 repo)
# Search: Typesense JSON API (search.pingora.fyi) — GET with query params
#   (POST is 403'd; wp-json REST API is disabled for guests)
# Resolution: detail page → hubdrive.tips/file/ID → hubcloud.cx/drive/ID
#   → resolver (gamerxyt.com/hubcloud.php) → direct .mkv (fsl-buckets / workers.dev)
#   Known dead hosts (skipped): hdstream4u.com (morencius "Downloads disabled"),
#   hubcdn.sbs (bonuscaf ad shortener), gadgetsweb.xyz (shortener chain)

[[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"
[[ -f "${LIB_DIR:-}/cinemeta.sh" ]] && source "${LIB_DIR}/cinemeta.sh"

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
_H4U_BASE="https://new5.hdhub4u.cl"
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

# Stream-candidate policy as DATA (algorithm lives in lib/pluginsdk.sh)
_H4U_REJECT_GLOBS='*tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*hdhub4u.ms*|*googlesyndication*'
_H4U_FAMILY_GLOBS='*workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*'
_H4U_PIXEL_GLOBS='*pixel.hubcloud*|*gpdl.hubcloud*'

# Rebuild curl arrays — Referer depends on the current base.
# _SDK_CURL mirrors _H4U_CURL so SDK resolvers send identical requests.
_h4u_rebuild_curl() {
    _H4U_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_H4U_UA" -H "Referer: ${_H4U_BASE}/")
    sdk_http "$_H4U_UA" "${_H4U_BASE}/"
}

_load_h4u_config() {
    sdk_conf_load "$CONF_DIR/hdhub4u.conf" H4U BASE_URL SEARCH_URL ALLOW_HOSTS
    [[ -n "${H4U_BASE_URL+x}" && -n "${H4U_BASE_URL}" ]] && { _H4U_BASE="$H4U_BASE_URL"; _H4U_BASE_USER_SET=1; }
    [[ -n "${H4U_SEARCH_URL+x}" && -n "${H4U_SEARCH_URL}" ]] && _H4U_SEARCH="$H4U_SEARCH_URL"
    [[ -n "${H4U_ALLOW_HOSTS+x}" ]] && _H4U_ALLOW_HOSTS="$H4U_ALLOW_HOSTS"
    _h4u_rebuild_curl
}

# Auto domain rotation (CloudStream-style): fetch the live domain list once a
# day, use the returned domain unless the user pinned BASE_URL in conf.
_h4u_load_domains() {
    [[ "$_H4U_BASE_USER_SET" == "1" ]] && return 0
    local dom
    dom=$(sdk_rotate_domain "$_H4U_DOMAINS_CACHE_KEY" "$_H4U_DOMAINS_URL" \
        "HDHUB4u" "$_H4U_BASE" "HDhub4u" "$_H4U_UA") || return 0
    [[ -z "$dom" ]] && return 0
    _H4U_BASE="$dom"
    _h4u_rebuild_curl
}

# Fuzzy host matching for resolver links (CloudStream-style: match broadly,
# let verify_streams filter garbage). See lib/pluginsdk.sh sdk_is_stream_candidate.
_h4u_is_stream_candidate() {
    sdk_is_stream_candidate "$1" "$_H4U_ALLOW_HOSTS" "$_H4U_REJECT_GLOBS" "$_H4U_FAMILY_GLOBS"
}

_h4u_quality() {
    sdk_quality_token "$1"
}

_h4u_stream_json() {
    sdk_stream_json_encoded "hdhub4u" "$(sdk_quality_token "$1")" "$1"
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
    sdk_resolve_drive "$1" _h4u_is_stream_candidate 1 "$_H4U_PIXEL_GLOBS"
}

# Resolve any supported mirror URL to candidate stream URLs
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

# ─── JS-gate resolution (2026-08 site redesign) ──────────────────────
# Movie download buttons now point at an ad-gate (?id=<b64>) that JS-
# redirects to the real links page. The gate page embeds a token in a
# localStorage setter: s('o','<b64>',...). Decoding the token yields the
# destination URL without executing any JavaScript:
#   b64d -> b64d -> ROT13 -> b64d -> JSON{l,w,o} -> atob(o)
# (The ROT13 step is the gate's "pen" Caesar cipher; verified against the
#  deobfuscated gate script.)

# Resolve one gate URL to its final destination. Prints the URL; returns
# non-zero on failure.
_h4u_resolve_gate() {
    local gate_url="$1"
    local page
    page=$(curl "${_H4U_CURL[@]}" "$gate_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1
    printf '%s' "$page" | python3 -c '
import sys, re, base64, codecs, json
h = sys.stdin.read()
m = re.search(r"s\(.o.,.([A-Za-z0-9+/=]+).", h)
if not m:
    sys.exit(1)
tok = m.group(1)
def b64d(s):
    s += "=" * (-len(s) % 4)
    return base64.b64decode(s).decode("latin-1")
try:
    l2 = b64d(b64d(tok))
    l3 = codecs.decode(l2, "rot_13")
    data = json.loads(b64d(l3))
    print(b64d(data["o"]))
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# hblinks.co archive page -> hubdrive/hubcloud mirror links (one per line).
_h4u_resolve_hblinks() {
    local archive_url="$1"
    local page
    page=$(curl "${_H4U_CURL[@]}" "$archive_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1
    printf '%s' "$page" | grep -oE 'href="https://(hubdrive|hubcloud)[^"]+"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

# Typesense search request (GET with query params — POST → 403).
# Args: query, limit, [full]. FULL=1 sends the primary-search parameter set
# (weights/highlight/cache); the Cinemeta-fallback re-search historically
# used a minimal set and keeps sending exactly that.
# Prints raw response body.
_h4u_typesense_query() {
    local q="$1" limit="${2:-15}" full="${3:-0}"
    local -a cmd=(curl -s --connect-timeout 8 --max-time 25
        -A "$_H4U_UA"
        -H "Referer: ${_H4U_BASE}/"
        -G "$_H4U_SEARCH"
        --data-urlencode "q=$q"
        --data-urlencode "query_by=post_title,category,stars,director,imdb_id"
        --data-urlencode "sort_by=sort_by_date:desc"
        --data-urlencode "limit=$limit")
    if [[ "$full" == "1" ]]; then
        cmd+=(--data-urlencode "query_by_weights=4,2,2,2,4"
            --data-urlencode "highlight_fields=none"
            --data-urlencode "use_cache=true"
            --data-urlencode "page=1")
    fi
    "${cmd[@]}" 2>/dev/null || true
}

# Typesense hit → standard result object (full title cleaner).
_h4u_typesense_results() {
    printf '%s' "$1" | jq -c '
        [.hits[]?.document |
        {
            id: ((.permalink // "") | sub("^https?://[^/]+"; "") | gsub("^/"; "") | gsub("/$"; "")),
            title: (.post_title
                | sub("^Download "; "")
                | gsub("\\[[^\\]]*\\]"; " ")
                | gsub("\\{[^}]*\\}"; " ")
                | sub("\\s*(4K|[0-9]+p)\\s*.*$"; "")
                | gsub("\\s*(?:\\bDual Audio\\b|\\bMulti Audio\\b|\\bWEB-? ?DL\\b|\\bWEBRip\\b|\\bBluRay\\b|\\bHDTS\\b|\\bHDTC\\b|\\bHDCAM\\b|\\bCAMRip\\b|\\bPREHD\\b|\\bx264\\b|\\bx265\\b|\\b10Bit\\b|\\bHEVC\\b|\\bESub[s]?\\b|\\bFull Movie\\b|\\bWeb Series\\b|\\bWEBSeries\\b|\\bAnime Series\\b|\\bSeries\\b|\\bHindi Dubbed\\b|\\bHindi\\b|\\bEnglish\\b|\\bTelugu\\b|\\bTamil\\b|\\bKannada\\b|\\bMalayalam\\b|\\bPunjabi\\b|\\bDubbed\\b|\\bORG\\b|\\bMovie\\b|\\bHQ\\b|\\bHD\\b|\\bNF\\b|\\bLiNE\\b|\\bDS\\b|\\bUNCUT\\b|\\bTRUE\\b|\\biMAX\\b|\\bV[0-9]+\\b|\\bNetFlix\\b|\\bNetflix\\b|\\bAmazon Prime\\b|\\bPrime Video\\b|\\bHotstar\\b|\\bDisney\\+? ?Hotstar\\b|\\bJioHotstar\\b|\\bJioCinema\\b|\\bJio\\b|\\bMX Player\\b|\\bSonyLiv\\b|\\bZee5\\b|\\bApple TV\\b|\\bHBO Max\\b|\\bHBO Original\\b|\\bHBO\\b)\\s*"; " "; "i")
                | gsub("\\(\\s*\\)"; "")
                | gsub("\\s*:\\s*$"; "")
                | gsub("\\s*[–]\\s*"; " ")
                | gsub("\\s+"; " ")
                | gsub("\\s+$"; "")
                | gsub("^[-–|]+|[-–|]+$"; "")
                | rtrimstr(" -–|") | ltrimstr(" -–|")
                | gsub("\\s+"; " ")
                | gsub("\\s+$"; "")),
            type: (if (.post_title | test("TVSeries|Season [0-9]"; "i")) then "series" else "movie" end),
            year: (if (.post_title | test("\\((19|20)[0-9]{2}\\)")) then (.post_title | capture("\\((?<year>(19|20)[0-9]{2})\\)").year) else null end),
            rating: null,
            poster: .post_thumbnail
        }]
    ' 2>/dev/null || printf '[]'
}

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_h4u_config
    _h4u_load_domains

    local response
    response=$(_h4u_typesense_query "$query" 15 1) || return 1
    [[ -z "$response" ]] && return 1

    local wp_results
    wp_results=$(_h4u_typesense_results "$response")

    # Cinemeta fallback (shared orchestrator): re-query Typesense per
    # canonical title when the primary search is sparse.
    cinemeta_search_fallback "$query" "$wp_results" _h4u_research_site
}

# Cinemeta research callback: Typesense re-search with simplified cleaner.
_h4u_research_site() {
    local cname="$1" cyear="$2"
    local search_resp
    search_resp=$(_h4u_typesense_query "${cname} ${cyear}" 5)
    [[ -z "$search_resp" ]] && return 0
    printf '%s' "$search_resp" | jq -c '
        [.hits[]?.document | {
            id: ((.permalink // "") | sub("^https?://[^/]+"; "") | gsub("^/"; "") | gsub("/$"; "")),
            title: (.post_title | sub("^Download "; "") | gsub("\\[[^\\]]*\\]"; " ") | gsub("\\{[^}]*\\}"; " ") | sub("\\s*(4K|[0-9]+p)\\s*.*$"; "") | gsub("\\s+"; " ") | gsub("\\s+$"; "")),
            type: (if (.post_title | test("TVSeries|Season [0-9]"; "i")) then "series" else "movie" end),
            year: .year,
            rating: null,
            poster: .post_thumbnail
        }]
    ' 2>/dev/null || true
}

# Fan-out worker: resolve ONE mirror link into stream JSON objects.
_h4u_get_url_worker() {
    local link="$1"
    local streams
    streams=$(_h4u_resolve_link "$link") || return 0
    [[ -z "$streams" ]] && return 0
    local su
    while IFS= read -r su; do
        [[ -z "$su" ]] && continue
        # Skip SAMPLE/trailer preview files (uploaders ship a 5-min
        # "SAMPLE-*.mkv" next to the real movie; it outranks it at
        # the same resolution in sort_streams)
        [[ "${su,,}" == *sample* ]] && continue
        _h4u_stream_json "$su"
    done <<< "$streams"
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
        [[ "$episode" =~ ^[0-9]+$ ]] || die_plugin "Invalid episode id: $id"
        mirror_links=$(printf '%s' "$html" | python3 -c '
import sys, re
html = sys.stdin.read()
episode = int(sys.argv[1])
# Accept zero-padded (E01) AND unpadded (E1) labels — plugin_list_episodes
# matches E(\d{1,2}); a get_url that only matched E%02d returned no links
# on pages that label episodes unpadded.
pat = re.compile(r"E0*%d\s*(?:&#8211;|&ndash;|&mdash;|-)?\s*<a href=\"(https://(?:hubdrive|hubcloud)[^\"]+)\"" % episode)
for m in pat.finditer(html):
    print(m.group(1))
' "$episode" 2>/dev/null || true)
    else
        mirror_links=$(printf '%s' "$html" | grep -oE 'href="https://(hubdrive|hubcloud)[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)

        # 2026-08 redesign: movie posts route download buttons through a JS
        # ad-gate (?id=<b64>) instead of direct hubdrive/hubcloud links.
        # No direct links + gate buttons present → resolve each gate to its
        # links page (hblinks.co archive) and collect the mirrors there.
        if [[ -z "$mirror_links" ]]; then
            local gate_urls
            gate_urls=$(printf '%s' "$html" | grep -oE 'href="https://[a-z0-9.-]+/\?id=[A-Za-z0-9+/=]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
            if [[ -n "$gate_urls" ]]; then
                local gate dest
                while IFS= read -r gate; do
                    [[ -z "$gate" ]] && continue
                    dest=$(_h4u_resolve_gate "$gate") || continue
                    [[ -z "$dest" ]] && continue
                    debug "Gate resolved: $gate -> $dest"
                    case "$dest" in
                        *hblinks*)
                            local hbl
                            hbl=$(_h4u_resolve_hblinks "$dest") || continue
                            [[ -n "$hbl" ]] && mirror_links="${mirror_links:+$mirror_links$'\n'}$hbl"
                            ;;
                        *hubdrive*|*hubcloud*)
                            mirror_links="${mirror_links:+$mirror_links$'\n'}$dest"
                            ;;
                    esac
                done <<< "$gate_urls"
                [[ -n "$mirror_links" ]] && mirror_links=$(printf '%s\n' "$mirror_links" | sort -u)
            fi
        fi
    fi

    [[ -z "$mirror_links" ]] && die_plugin "No resolvable mirror links on HDhub4u page for: $id"

    local -a _links=()
    mapfile -t _links <<< "$mirror_links"
    local merged
    merged=$(sdk_fanout _h4u_get_url_worker "${_links[@]}")
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
    # NOTE: no `| head -1` mid-pipeline — page-sized input + early-exit head
    # SIGPIPEs the producer under pipefail (same race class as grep -q).
    # Consume everything, then take the first line from the small result.
    local season
    season=$(grep -oiE 'Season[[:space:]]*[0-9]+' <<< "$html" | grep -oE '[0-9]+' 2>/dev/null || true)
    [[ -n "$season" ]] && season=$(printf '%s\n' "$season" | awk 'NR==1{print}')
    [[ -z "$season" ]] && season="1"
    # Base-10: "Season 08/09" would emit number:08 (invalid JSON).
    [[ "$season" =~ ^[0-9]+$ ]] && season=$((10#$season)) || season=1

    printf '[{"id":"%d","title":"Season %d","number":%d}]\n' "$season" "$season" "$season"
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
