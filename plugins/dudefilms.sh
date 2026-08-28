#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# DudeFilms plugin for movie-cli
# WordPress movie site (dudefilms.casa, rotates) — Bollywood/South
# Indian/multi-audio content. Search via ?s=, detail page → 
# dflinks.online/archives/... link pages → hubcloud drive chain
# (the same hubcloud → gamerxyt.com/hubcloud.php resolver → R2/
# workers.dev direct chain the hdhub4u/4khdhub plugins implement).
#
# Chain (all verified live):
#   search:  /?s=<query>                → WordPress post links
#   detail:  /<slug>/                   → dflinks.online/archives/N
#   archive: dflinks.online/archives/N  → hubcloud.*/drive/ID + 
#                                         dl.*.workers.dev/...mkv + gdlink/file
#   hubcloud drive → gamerxyt resolver → r2/workers.dev direct streams
#
# Domain rotation: phisher98/tvvvv/domains.json (key "dudefilms").
# ═══════════════════════════════════════════════════════════════

[[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"
[[ -f "${LIB_DIR:-}/cinemeta.sh" ]] && source "${LIB_DIR}/cinemeta.sh"

PLUGIN_NAME="DudeFilms"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies from DudeFilms (hubcloud drive chain)"

_DF_BASE="https://dudefilms.casa"
_DF_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
_DF_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_DF_UA")
_DF_ALLOW_HOSTS=""
# Live domain list — same source the phisher CloudStream extensions use
_DF_DOMAINS_URL="https://raw.githubusercontent.com/phisher98/tvvvv/refs/heads/main/domains.json"
_DF_DOMAINS_CACHE_KEY="dudefilms_domains"
_DF_BASE_USER_SET=0   # 1 = user set BASE_URL in conf (wins over auto-rotation)

# Stream-candidate policy as DATA (algorithm lives in lib/pluginsdk.sh)
_DF_REJECT_GLOBS='*tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*googlesyndication*|*winexch*|*effectivecpm*|*profitableratecpm*|*a-ads*|*khelostar*'
_DF_FAMILY_GLOBS='*workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*|*gdlink*|*filepress*|*gofile*|*d0000d*|*drop.download*|*dood*|*driveapp*|*gdtot*'
_DF_PIXEL_GLOBS='*pixel.hubcloud.cx*|*gpdl.hubcloud.cx*'

_load_df_config() {
    sdk_conf_load "$CONF_DIR/dudefilms.conf" DF BASE_URL ALLOW_HOSTS
    [[ -n "${DF_BASE_URL+x}" && -n "${DF_BASE_URL}" ]] && { _DF_BASE="$DF_BASE_URL"; _DF_BASE_USER_SET=1; }
    [[ -n "${DF_ALLOW_HOSTS+x}" ]] && _DF_ALLOW_HOSTS="$DF_ALLOW_HOSTS"
    sdk_http "$_DF_UA"
}

# Auto domain rotation: fetch the live domain list once a day
_df_load_domains() {
    [[ "$_DF_BASE_USER_SET" == "1" ]] && return 0
    local dom
    dom=$(sdk_rotate_domain "$_DF_DOMAINS_CACHE_KEY" "$_DF_DOMAINS_URL" \
        "dudefilms" "$_DF_BASE" "DudeFilms" "$_DF_UA") || return 0
    [[ -z "$dom" ]] && return 0
    _DF_BASE="$dom"
}

# Fuzzy host matching — same policy as hdhub4u: match broadly,
# let verify_streams filter garbage.
_df_is_stream_candidate() {
    sdk_is_stream_candidate "$1" "$_DF_ALLOW_HOSTS" "$_DF_REJECT_GLOBS" "$_DF_FAMILY_GLOBS"
}

_df_quality() {
    sdk_quality_suffix "$1"
}

_df_stream_json() {
    sdk_stream_json_encoded "dudefilms" "$(sdk_quality_suffix "$1")" "$1"
}

# Archive hops can be flaky — fetch with one retry before giving up
_df_fetch_retry() {
    local url="$1"
    local page
    page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$url" 2>/dev/null || true)
    if [[ -z "$page" ]]; then
        sleep 1
        page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$url" 2>/dev/null || true)
    fi
    printf '%s' "$page"
}

# Any hubcloud-family link → drive chain (SDK-backed)
_df_resolve_drive() {
    sdk_resolve_drive "$1" _df_is_stream_candidate 1 "$_DF_PIXEL_GLOBS"
}

_df_resolve_hubcloud() {
    local url="$1"
    case "$url" in
        *hubdrive*)
            # hubdrive file page → hubcloud drive link inside
            local page hc_url
            page=$(curl "${_DF_CURL[@]}" "$url" 2>/dev/null) || return 1
            [[ -z "$page" ]] && return 1
            hc_url=$(printf '%s' "$page" | grep -oE 'href="https://hubcloud[^"]*/drive/[^"]+"' | head -1 | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
            [[ -z "$hc_url" ]] && return 1
            _df_resolve_drive "$hc_url"
            ;;
        *hubcloud*)
            _df_resolve_drive "$url"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# Archive page (dflinks.online/archives/N) → candidate URLs
# ═══════════════════════════════════════════════════════════════
_df_resolve_archive() {
    local arch_url="$1"
    local page

    page=$(_df_fetch_retry "$arch_url")
    [[ -z "$page" ]] && return 1

    # All external download links, resolved per family
    printf '%s' "$page" | grep -oE 'href="https?://[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        case "$link" in
            *hubcloud*|*hubdrive*)
                _df_resolve_hubcloud "$link"
                ;;
            *)
                if _df_is_stream_candidate "$link"; then
                    printf '%s\n' "$link"
                fi
                ;;
        esac
    done
}

# Resolve ONE episode (Nth maxbutton-ep anchor) from an archive page.
# Archive pages list per-episode buttons: <a class="...maxbutton-ep..."
# href="hubcloud-drive"><span class='mb-text'>Episode 01</span></a>
_df_resolve_archive_episode() {
    local arch_url="$1"
    local want_ep="$2"
    local page

    page=$(_df_fetch_retry "$arch_url")
    [[ -z "$page" ]] && return 1

    # Extract the anchor for the wanted episode number (zero-padded label)
    local target
    target=$(printf '%02d' "$want_ep" 2>/dev/null || printf '%s' "$want_ep")
    local ep_url
    # NOTE: consume-then-slice, no `| head -1` — archive pages can carry
    # multiple blocks per episode label (hubdrive + other mirrors), and an
    # early-exit head SIGPIPEs grep under pipefail → intermittent miss.
    ep_url=$(printf '%s' "$page" | grep -oE "<a[^>]*class=\"[^\"]*maxbutton-ep[^\"]*\"[^>]*href=\"[^\"]+\"[^>]*><span[^>]*>Episode[[:space:]]*${target}[[:space:]]*</span>" | grep -oE 'href="[^\"]+"' | sed -E 's/.*href="([^\"]+)".*/\1/' | awk 'NR==1{print}' 2>/dev/null || true)
    [[ -z "$ep_url" ]] && return 1

    # Resolve per host family (hubcloud drive chain, or direct candidate)
    case "$ep_url" in
        *hubcloud*|*hubdrive*)
            _df_resolve_hubcloud "$ep_url"
            ;;
        *)
            if _df_is_stream_candidate "$ep_url"; then
                printf '%s\n' "$ep_url"
            fi
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════
# Plugin API (v5)
# ═══════════════════════════════════════════════════════════════

# Parse a WP search page into result JSON. Used by plugin_search AND the
# Cinemeta fallback re-search (commit 9a21514 wrapped this pipeline in a
# variable and never printed it — dudefilms search returned nothing).
_df_parse_search_page() {
    local html_page="$1"
    local q="$2"
    printf '%s' "$html_page" | python3 -c '
import sys, re, html as h
page = sys.stdin.read()
query = sys.argv[1].lower()
out = []

def norm(s):
    # lowercase, drop non-alphanumerics: "K.G.F" -> "kgf", "4k hd" -> "4khd"
    return re.sub(r"[^a-z0-9]", "", s.lower())

# significant query tokens (len >= 3 after normalization); fall back to the
# whole normalized query if no token qualifies
qtokens = [t for t in re.split(r"[^a-z0-9]+", query) if len(t) >= 3]
if not qtokens:
    qtokens = [re.sub(r"[^a-z0-9]", "", query)]
qnorm = norm(query)

# article entries: <a href=".../slug/">Title</a> inside article/h2 blocks
for m in re.finditer(r"<a href=\"(https?://[^\"]+/[a-z0-9-]+/)\"[^>]*>([^<]{5,150})</a>", page):
    url, title = m.group(1), h.unescape(m.group(2)).strip()
    if any(x in url for x in ("/tag/", "/category/", "/page/", "/author/", "feed", "#", "?s=")):
        continue
    if not re.search(r"download|movie|season|series|\b\d{4}\b", url + " " + title, re.I):
        continue
    tnorm = norm(title)
    # relevance: the full normalized query must appear as a substring of the
    # normalized title (catches "all of us are dead" -> "allofusaredead..."),
    # OR every significant query token must appear as a WHOLE WORD in the
    # title (substring matching would let "dead" match "deadstream"; a
    # single-token match like "dead" in "Darby and the Dead" is never
    # sufficient for a multi-word query).
    twords_lower = re.split(r"[^a-z0-9]+", title.lower())
    if qnorm and qnorm in tnorm:
        pass
    elif not all(any(t == w for w in twords_lower) for t in qtokens):
        continue
    slug = url.rstrip("/").rsplit("/", 1)[-1]
    tvtype = "series" if re.search(r"season|series|s\d{2}|e\d{2}", title, re.I) else "movie"
    year = ""
    ym = re.search(r"\((\d{4})\)|(19|20)\d{2}", title)
    if ym:
        year = ym.group(1) or ym.group(0)
    # Clean SEO title -> simple "Name (Year)" (match MovieBlast style)
    ctitle = re.sub(r"^Download\s+", "", title, flags=re.I)
    ctitle = re.sub(r"\[[^\]]*\]", " ", ctitle)
    ctitle = re.sub(r"\{[^}]*\}", " ", ctitle)
    ctitle = re.sub(r"\s*(4K|[0-9]+p)\s*.*$", "", ctitle, flags=re.I)
    ctitle = re.sub(r"\s*(?:\bDual Audio\b|\bMulti Audio\b|\bWEB-? ?DL\b|\bWEBRip\b|\bBluRay\b|\bHDTS\b|\bHDTC\b|\bHDCAM\b|\bCAMRip\b|\bPREHD\b|\bx264\b|\bx265\b|\b10Bit\b|\bHEVC\b|\bESub[s]?\b|\bFull Movie\b|\bWeb Series\b|\bWEBSeries\b|\bAnime Series\b|\bHindi Dubbed\b|\bHindi\b|\bEnglish\b|\bTelugu\b|\bTamil\b|\bKannada\b|\bMalayalam\b|\bPunjabi\b|\bDubbed\b|\bORG\b|\bMovie\b|\bHQ\b|\bV[0-9]+\b|\bNetFlix\b|\bNetflix\b|\bAmazon Prime\b|\bPrime Video\b|\bHotstar\b|\bDisney\+? ?Hotstar\b|\bJioCinema\b|\bJio\b|\bMX Player\b|\bSonyLiv\b|\bZee5\b|\bApple TV\b|\bHBO Max\b|\bHBO Original\b|\bHBO\b)\s*", " ", ctitle, flags=re.I)
    ctitle = re.sub(r"\s+", " ", ctitle)
    ctitle = ctitle.strip(" -–|")
    ctitle = re.sub(r"\s+", " ", ctitle).strip()
    out.append({"id": slug, "title": ctitle, "type": tvtype, "year": year, "rating": None, "poster": None})
# dedupe by id
seen = set()
dedup = []
for o in out:
    if o["id"] not in seen:
        seen.add(o["id"])
        dedup.append(o)
print(__import__("json").dumps(dedup))
' "$q" 2>/dev/null || printf '[]'
}

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_df_config
    _df_load_domains

    local html
    html=$(curl "${_DF_CURL[@]}" -G "${_DF_BASE}/" --data-urlencode "s=$query" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # WordPress search results: article links + titles with relevance filter.
    local wp_results
    wp_results=$(_df_parse_search_page "$html" "$query")

    # Cinemeta fallback (shared orchestrator): when the WP site search
    # returns sparse results (title mismatch between the user query and the
    # site title), re-search the site by canonical title+year.
    cinemeta_search_fallback "$query" "$wp_results" _df_research_site
}

# Cinemeta research callback: WP ?s= re-search by canonical title+year.
_df_research_site() {
    local cname="$1" cyear="$2"
    local site_html cres
    site_html=$(curl "${_DF_CURL[@]}" -G "${_DF_BASE}/" --data-urlencode "s=${cname} ${cyear}" 2>/dev/null || true)
    [[ -z "$site_html" ]] && return 0
    _df_parse_search_page "$site_html" "${cname} ${cyear}"
}

# Fan-out worker: resolve ONE archive page into stream JSON objects.
_df_get_url_worker() {
    local link="$1"
    local streams=""
    if [[ -n "${DF_WORKER_EPISODE:-}" ]]; then
        # Per-episode: pick the Nth maxbutton-ep anchor from the archive
        streams=$(_df_resolve_archive_episode "$link" "$DF_WORKER_EPISODE") || true
        # Season packs have no per-episode markers — fall back to all
        # archive download links (hubcloud, driveapp, etc.)
        [[ -z "$streams" ]] && streams=$(_df_resolve_archive "$link") || true
    else
        streams=$(_df_resolve_archive "$link") || true
    fi
    [[ -z "$streams" ]] && return 0
    local su
    while IFS= read -r su; do
        [[ -z "$su" ]] && continue
        [[ "${su,,}" == *sample* ]] && continue
        _df_stream_json "$su"
    done <<< "$streams"
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_df_config
    _df_load_domains

    # Series episode id "series:season:episode" — resolve ONLY that episode's
    # link from each archive (archives list per-episode maxbutton-ep anchors)
    local series_id="" season="" episode=""
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi
    local detail_id="$id"
    [[ -n "$series_id" ]] && detail_id="$series_id"

    local detail_url="${_DF_BASE}/${detail_id}/"
    local html
    html=$(curl "${_DF_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "DudeFilms detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty DudeFilms detail page"

    # Archive link pages (dflinks.online/archives/N), grouped by season:
    # each archive belongs to the nearest preceding "Season N" heading.
    local arch_links
    if [[ -n "$season" ]]; then
        arch_links=$(printf '%s' "$html" | python3 -c '
import sys, re
page = sys.stdin.read()
want = int(sys.argv[1])
# walk through, tracking the last "Season N" heading before each archive link
# NOTE: dflinks TLD rotates (online → cc → ...); match any dflinks host.
links = re.findall(r"https://dflinks\.[a-z]+/archives/\d+", page)
# find positions of season headings and archive links
seasons = [(m.start(), int(m.group(1))) for m in re.finditer(r"Season\s*(\d+)", page, re.I)]
for l in links:
    lpos = page.find(l)
    cur = 1
    for spos, snum in seasons:
        if spos < lpos:
            cur = snum
        else:
            break
    if cur == want:
        print(l)
' "$season" 2>/dev/null | sort -u || true)
    else
        arch_links=$(printf '%s' "$html" | grep -oE 'href="https?://dflinks\.[a-z]+/archives/[0-9]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    fi
    [[ -z "$arch_links" ]] && die_plugin "No archive links on DudeFilms page for: $id"

    DF_WORKER_EPISODE="$episode"
    local -a _links=()
    mapfile -t _links <<< "$arch_links"
    local merged
    merged=$(sdk_fanout _df_get_url_worker "${_links[@]}")
    unset DF_WORKER_EPISODE

    [[ -z "$merged" || "$merged" == "[]" ]] && die_plugin "No playable links resolved for: $id"
    printf '%s\n' "$merged"
}

plugin_list_seasons() {
    local series_id="$1"
    _load_df_config
    _df_load_domains

    local html
    html=$(curl "${_DF_CURL[@]}" "${_DF_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # Parse ALL "Season N" headings from the page (dedupe, ascending).
    # Multi-season posts (e.g. "Season 1-2") have one heading per season.
    local seasons_json
    seasons_json=$(printf '%s' "$html" | grep -oiE 'Season[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | jq -c '[.[] | {id: (.|tostring), title: ("Season " + (.|tostring)), number: .}]' 2>/dev/null || true)

    # Fallback: title range like "Season 1-2" or "Season 1 – 2"
    if [[ -z "$seasons_json" || "$seasons_json" == "[]" ]]; then
        local range
        range=$(printf '%s' "$html" | grep -oiE 'Season[[:space:]]*[0-9]+[[:space:]]*[-–][[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -2 | tr '\n' ' ')
        local s1 s2
        s1=$(printf '%s' "$range" | awk '{print $1}')
        s2=$(printf '%s' "$range" | awk '{print $2}')
        # Force base-10 (same octal trap as list_episodes: "09" aborts
        # arithmetic). Also required for the -gt test below, which is
        # arithmetic evaluation too.
        [[ "$s1" =~ ^[0-9]+$ ]] && s1=$((10#$s1)) || s1=""
        [[ "$s2" =~ ^[0-9]+$ ]] && s2=$((10#$s2)) || s2=""
        if [[ -n "$s1" && -n "$s2" && "$s2" -gt "$s1" ]]; then
            # Batched JSONL → one jq pass (was one fork per season)
            local lines="" i
            for (( i = s1; i <= s2; i++ )); do
                lines+="$(jq -nc --argjson n "$i" '{"id": ($n|tostring), "title": ("Season " + ($n|tostring)), "number": $n}')"$'\n'
            done
            seasons_json=$(jq -s '.' <<< "$lines")
        fi
    fi

    [[ -z "$seasons_json" || "$seasons_json" == "[]" ]] && seasons_json='[{"id":"1","title":"Season 1","number":1}]'
    printf '%s\n' "$seasons_json"
}

plugin_list_episodes() {
    local series_id="$1"
    local season_number="${2:-1}"
    _load_df_config
    _df_load_domains

    # Fetch the detail page → archive pages → count maxbutton-ep anchors
    # (each = one episode; e.g. HOTD S3 has "Episode 01".."Episode 07")
    local html arch_links ep_count
    html=$(curl "${_DF_CURL[@]}" "${_DF_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    arch_links=$(printf '%s' "$html" | grep -oE 'href="https?://dflinks\.[a-z]+/archives/[0-9]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    ep_count=0
    if [[ -n "$arch_links" ]]; then
        local first_arch
        first_arch=$(printf '%s\n' "$arch_links" | head -1)
        local arch_page
        arch_page=$(_df_fetch_retry "$first_arch")
        ep_count=$(printf '%s' "$arch_page" | grep -oE 'Episode[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 2>/dev/null || echo 0)
        [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count=$(printf '%s' "$arch_page" | grep -cE 'maxbutton-ep' 2>/dev/null || true)
    fi
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count="1"
    # Force base-10: episode labels like "Episode 09" yield "09", which bash
    # arithmetic reads as OCTAL (invalid → "value too great for base" error,
    # the for-loop aborts and list_episodes emits []). 10# strips the leading
    # zero. Guard non-numeric junk too.
    [[ "$ep_count" =~ ^[0-9]+$ ]] && ep_count=$((10#$ep_count)) || ep_count=1
    (( ep_count < 1 )) && ep_count=1

    # Emit one episode entry per found episode — batched JSONL, one jq pass
    local lines="" i
    for (( i = 1; i <= ep_count; i++ )); do
        lines+="$(jq -nc --arg id "${series_id}:${season_number}:${i}" --arg t "Episode $i" --argjson n "$i" --argjson s "$season_number" \
            '{"id": $id, "title": $t, "number": $n, "episode": $n, "season": $s}')"$'\n'
    done
    jq -s '.' <<< "$lines"
}

plugin_health() {
    _load_df_config
    _df_load_domains
    local code
    code=$(curl -s --connect-timeout 8 --max-time 15 -A "$_DF_UA" -o /dev/null -w '%{http_code}' "${_DF_BASE}/" 2>/dev/null || echo 000)
    [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}\n' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
