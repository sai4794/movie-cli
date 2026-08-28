#!/usr/bin/env bash
# movies4u.sh — Movies4u plugin for movie-cli
# WordPress site (movies4u.clinic family) with the m4ulinks.site link-farm
# chain: post page → m4ulinks.site/number/N → hubcloud/video|drive + gdlink +
# gdflix buttons → resolver (sportverse/gamerxyt hubcloud.php) → direct links
# Reference: phisher98 CloudStream extension "Movies4u" (v11), decompiled.

[[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"
[[ -f "${LIB_DIR:-}/cinemeta.sh" ]] && source "${LIB_DIR}/cinemeta.sh"

# ═══════════════════════════════════════════════════════════════
# Plugin Metadata
# ═══════════════════════════════════════════════════════════════
PLUGIN_NAME="Movies4u"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies from Movies4u (m4ulinks → hubcloud/gdlink/gdflix chain)"

# ═══════════════════════════════════════════════════════════════
# Configuration
# ═══════════════════════════════════════════════════════════════
_M4U_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
_M4U_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_M4U_UA")
_M4U_ALLOW_HOSTS=""
_M4U_BASE="https://new3.movies4u.clinic"
_M4U_DOMAINS_URL="https://raw.githubusercontent.com/phisher98/tvvvv/refs/heads/main/domains.json"
_M4U_DOMAINS_CACHE_KEY="movies4u_domains"
_M4U_BASE_USER_SET=0

# Stream-candidate policy as DATA (algorithm lives in lib/pluginsdk.sh)
_M4U_REJECT_GLOBS='*tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*hubcloud.cx/video*|*googlesyndication*|*winexch*|*effectivecpm*|*profitableratecpm*|*a-ads*|*khelostar*|*drivebot*|*filesgram*|*tgredirect*|*multiup*|*royaljeet*|*bit.ly*'
_M4U_FAMILY_GLOBS='*workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*|*gdlink*|*filepress*|*gofile*|*d0000d*|*drop.download*|*dood*|*driveapp*|*gdtot*|*gpdl*|*filesdl*'
# Resolver pixel routing is per-site data: Movies4u routes ANY *gpdl* link
# to the redirector resolver, not just gpdl.hubcloud.cx.
_M4U_PIXEL_GLOBS='*pixel.hubcloud.cx*|*gpdl*'

_load_m4u_config() {
    sdk_conf_load "$CONF_DIR/movies4u.conf" M4U BASE_URL ALLOW_HOSTS
    [[ -n "${M4U_BASE_URL+x}" && -n "${M4U_BASE_URL}" ]] && { _M4U_BASE="$M4U_BASE_URL"; _M4U_BASE_USER_SET=1; }
    [[ -n "${M4U_ALLOW_HOSTS+x}" ]] && _M4U_ALLOW_HOSTS="$M4U_ALLOW_HOSTS"
}

# Auto domain rotation — same source the phisher CloudStream extensions use
_m4u_load_domains() {
    [[ "$_M4U_BASE_USER_SET" == "1" ]] && return 0
    local dom
    dom=$(sdk_rotate_domain "$_M4U_DOMAINS_CACHE_KEY" "$_M4U_DOMAINS_URL" \
        "movies4u" "$_M4U_BASE" "Movies4u" "$_M4U_UA") || return 0
    [[ -z "$dom" ]] && return 0
    _M4U_BASE="$dom"
}

# ═══════════════════════════════════════════════════════════════
# Stream candidate policy (same philosophy as dudefilms/hdhub4u)
# ═══════════════════════════════════════════════════════════════
_m4u_is_stream_candidate() {
    sdk_is_stream_candidate "$1" "$_M4U_ALLOW_HOSTS" "$_M4U_REJECT_GLOBS" "$_M4U_FAMILY_GLOBS"
}

# NOTE: kept plugin-local on purpose — this ladder emits bare-number labels
# ("1080", "4K") unlike the SDK flavors, and quality strings surface
# verbatim in stream-selection labels.
_m4u_quality() {
    local url="$1"
    local lower
    lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *2160*|*4k*) printf '4K' ;;
        *1440*) printf '1440' ;;
        *1080*) printf '1080' ;;
        *720*) printf '720' ;;
        *480*) printf '480' ;;
        *360*) printf '360' ;;
        *) printf 'auto' ;;
    esac
}

_m4u_stream_json() {
    # Movies4u URLs are used verbatim (no percent-encoding), matching CSX.
    # $3 = optional explicit quality (vcloud new-chain emits it from the page
    # <title> since the opaque R2 URL carries no quality token).
    local url="$1" referer="${2:-}" q="${3:-}"
    [[ -z "$q" ]] && q=$(_m4u_quality "$url")
    sdk_stream_json "movies4u" "$q" "$url" "$referer"
}

# ═══════════════════════════════════════════════════════════════
# Resolvers (SDK-backed: pixel/drive/resolver walks are shared code)
# ═══════════════════════════════════════════════════════════════

# hubcloud video page → resolver href (sportverse hubcloud.php) → direct links
_m4u_resolve_video() {
    local video_url="$1"
    local page href
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$video_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    # Legacy chain (pre-2026-08): page carried a hubcloud.php resolver href.
    href=$(printf '%s' "$page" | grep -oE 'href="https?://[^"]*hubcloud\.php[^"]*"' | head -1 | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
    if [[ -n "$href" ]]; then
        # Resolver pages accept ALL anchors (btn_only=0) on this site.
        sdk_resolve_resolver "$href" _m4u_is_stream_candidate 0 "$_M4U_PIXEL_GLOBS" "${_M4U_BASE}/"
        return $?
    fi

    # New chain (2026-08): the vcloud page embeds a double-base64 token via
    # atob(atob(...)) that decodes to a tokenized URL; fetching that page
    # yields a second page that embeds the direct R2 stream inside an Android
    # intent (createIntentURL({host: ...})). No JS execution needed — both
    # steps are plain fetch + regex. The direct R2 link needs no Referer.
    local token_url direct
    token_url=$(printf '%s' "$page" | python3 -c '
import sys, re, base64
h = sys.stdin.read()
m = re.search(r"atob\(atob\(.([A-Za-z0-9+/=]+).\)\)", h)
if not m:
    sys.exit(0)
t = m.group(1)
t += "=" * (-len(t) % 4)
l1 = base64.b64decode(t).decode("latin-1")
l1 += "=" * (-len(l1) % 4)
print(base64.b64decode(l1).decode("latin-1"))
' 2>/dev/null)
    [[ -z "$token_url" ]] && return 1

    local page2
    page2=$(curl "${_M4U_CURL[@]}" -H "Referer: ${video_url}" "$token_url" 2>/dev/null) || return 1
    [[ -z "$page2" ]] && return 1

    direct=$(printf '%s' "$page2" | python3 -c '
import sys, re
h = sys.stdin.read()
m = re.search(r"host:\s*.(https?://[^ ]+?).\s*,\s*scheme", h)
if m:
    print(m.group(1))
    sys.exit(0)
m = re.search(r"(https?://[a-z0-9.-]*(?:r2\.dev|workers\.dev)[^\" ]*)", h)
if m:
    print(m.group(1))
' 2>/dev/null)
    [[ -z "$direct" ]] && return 1

    # The R2 URL is opaque (no quality token). Recover the quality from the
    # page <title> (the filename, e.g. "...480p.WEB-DL...mkv") and emit it
    # tab-separated so the worker can label the stream. The worker falls back
    # to URL-derived quality for lines without a tab.
    local title q
    title=$(printf '%s' "$page2" | grep -oE '<title>[^<]*' | head -1 | sed 's/<title>//' 2>/dev/null || true)
    q=$(_m4u_quality "$title")
    printf '%s\t%s\n' "$direct" "$q"
}

# gdlink.dev/file/ID → Instant DL (busycdn) direct link; gates dropped.
# 2026-08: gdlink.dev now serves an instant.busycdn.xyz link that redirects to
# fastdl-one.pages.dev/?url=<video-downloads.googleusercontent.com/...>. The
# googleusercontent URL IS a playable stream (HTTP 200 + MKV magic) — the old
# "busycdn → googleusercontent = not playable" assumption is stale. Follow the
# chain and emit the googleusercontent URL (verify_streams still filters any
# that are actually HTML by magic bytes).
_m4u_resolve_gdlink() {
    local url="$1"
    local page
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    # Quality from the gdlink page <title> (e.g. "...S01E01...480p...mkv") —
    # the googleusercontent URL is opaque and carries no quality token.
    local title q
    title=$(printf '%s' "$page" | grep -oE '<title>[^<]*</title>' | head -1 | sed -E 's/<\/?title>//g')
    q=$(_m4u_quality "$title")

    local busycdn final gu
    busycdn=$(printf '%s' "$page" | grep -oE 'https://instant\.busycdn\.xyz/[^"'"'"' <>]*' | head -1)
    if [[ -n "$busycdn" ]]; then
        final=$(curl -so /dev/null -w '%{url_effective}' -L --connect-timeout 8 --max-time 15 "$busycdn" 2>/dev/null || true)
        if [[ "$final" == *"url="* ]]; then
            gu=$(python3 -c '
import sys, urllib.parse
u = sys.argv[1]
q = urllib.parse.parse_qs(urllib.parse.urlparse(u).query)
print(q.get("url", [""])[0])
' "$final" 2>/dev/null || true)
            if [[ -n "$gu" && "$gu" == *googleusercontent* ]]; then
                printf '%s\t%s\n' "$gu" "$q"
                return 0
            fi
        fi
        # busycdn resolved straight to a playable candidate
        if [[ -n "$final" ]] && _m4u_is_stream_candidate "$final"; then
            printf '%s\t%s\n' "$final" "$q"
            return 0
        fi
    fi

    # Fallback: original behavior — extract stream candidates from hrefs
    printf '%s' "$page" | grep -oE 'href="https?://[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        if _m4u_is_stream_candidate "$link"; then
            printf '%s\t%s\n' "$link" "$q"
        fi
    done
}

# gdflix.dev/file/ID → Instant DL (busycdn) direct link; gates dropped
_m4u_resolve_gdflix() {
    _m4u_resolve_gdlink "$1"
}

# m4ulinks.site/number/N page: parse quality/episode blocks → resolve buttons.
# Movie layout: <h4>480p [500MB]</h4> + div.downloads-btns-div with
#   hubcloud video + filebee + gdlink buttons.
# Series layout: <h5>-:Episodes: N:-</h5> + div.downloads-btns-div with
#   hubcloud drive + gdflix buttons.
# Args: url, want_episode ("" for all/movie)
_m4u_resolve_m4ulinks() {
    local url="$1"
    local want_ep="${2:-}"
    local page
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    printf '%s' "$page" | python3 -c '
import sys, re, json
html = sys.stdin.read()
want = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else None

# split into blocks by h4 (movie quality) or h5 "Episodes: N" (series)
blocks = []  # (label, [button urls])
cur_label = ""
cur_btns = []
pat = re.compile(r"<h([45])[^>]*>(.*?)</h\1>", re.S)
# walk tokens in order: headings + a.btn buttons
tokens = []
for m in re.finditer(r"<h([45])[^>]*>(.*?)</h\1>|href=\"(https?://[^\"]+)\"[^>]*class=\"[^\"]*btn[^\"]*\"", html, re.S):
    if m.group(1):  # heading
        label = re.sub(r"<[^>]+>", "", m.group(2)).strip()
        tokens.append(("H", label))
    elif m.group(3):
        tokens.append(("B", m.group(3)))

for kind, val in tokens:
    if kind == "H":
        if cur_label and cur_btns:
            blocks.append((cur_label, cur_btns))
        cur_label = val
        cur_btns = []
    else:
        cur_btns.append(val)
if cur_label and cur_btns:
    blocks.append((cur_label, cur_btns))

# filter: drop telegram/ads-only blocks, keep blocks with any candidate
def keep(href):
    l = href.lower()
    return not any(x in l for x in ("t.me", "tg/go", "telegram", "tgredirect", "filesgram", "drivebot", "multiup", "winexch", "a-ads", "bit.ly", "one.one.one.one"))

out = []
for label, btns in blocks:
    good = [b for b in btns if keep(b)]
    if not good:
        continue
    if want is not None:
        m = re.search(r"Episodes?\s*:?\s*(\d+)", label, re.I)
        if not m or int(m.group(1)) != int(want):
            continue
    # resolve buttons by family
    for b in good:
        out.append(b)
print("\n".join(out))
' "$want_ep" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Plugin API (v5)
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_m4u_config
    _m4u_load_domains

    local html
    html=$(curl "${_M4U_CURL[@]}" -G "${_M4U_BASE}/" --data-urlencode "s=$query" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    local wp_results
    wp_results=$(_m4u_parse_wp_search_page "$html" "$query")

    # Cinemeta fallback (shared orchestrator): when the WP site search
    # returns sparse results, query Cinemeta for canonical titles and
    # re-search this site by title+year (CSX CineStream Movies4u behavior).
    cinemeta_search_fallback "$query" "$wp_results" _m4u_research_site
}

# WP search-page parser with relevance filter. WordPress falls back to a
# recent-posts grid when a query matches nothing — those unrelated rows
# must not surface. Kept only if the full normalized query is a substring
# of the normalized title, or every significant token matches whole-word.
_m4u_parse_wp_search_page() {
    printf '%s' "$1" | python3 -c '
import sys, re, html as h
page = sys.stdin.read()
query = sys.argv[1].lower()
out = []

def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

qtokens = [t for t in re.split(r"[^a-z0-9]+", query) if len(t) >= 3]
if not qtokens:
    qtokens = [re.sub(r"[^a-z0-9]", "", query)]
qnorm = norm(query)

for m in re.finditer(r"<a href=\"(https?://[^\"]+/[a-z0-9-]+/)\"[^>]*>([^<]{5,150})</a>", page):
    url, title = m.group(1), h.unescape(m.group(2)).strip()
    if any(x in url for x in ("/tag/", "/category/", "/page/", "/author/", "feed", "#", "?s=", "wp-content")):
        continue
    if not re.search(r"download|movie|season|series|\b\d{4}\b", url + " " + title, re.I):
        continue
    tnorm = norm(title)
    twords_lower = re.split(r"[^a-z0-9]+", title.lower())
    if qnorm and qnorm in tnorm:
        pass
    elif not all(any(t == w for w in twords_lower) for t in qtokens):
        continue
    slug = url.rstrip("/").rsplit("/", 1)[-1]
    tvtype = "series" if re.search(r"season|series|web.?series", title, re.I) else "movie"
    year = ""
    ym = re.search(r"\((\d{4})\)|(19|20)\d{2}", title)
    if ym:
        year = ym.group(1) or ym.group(0)
    ctitle = re.sub(r"^Download\s+", "", title, flags=re.I)
    ctitle = re.sub(r"\[[^\]]*\]", " ", ctitle)
    ctitle = re.sub(r"\{[^}]*\}", " ", ctitle)
    ctitle = re.sub(r"\s*(4K|[0-9]+p)\s*.*$", "", ctitle, flags=re.I)
    ctitle = re.sub(r"\s*(?:\bDual Audio\b|\bMulti Audio\b|\bWEB-? ?DL\b|\bWEBRip\b|\bBluRay\b|\bHDTS\b|\bHDTC\b|\bHDCAM\b|\bCAMRip\b|\bPREHD\b|\bx264\b|\bx265\b|\b10Bit\b|\bHEVC\b|\bESub[s]?\b|\bFull Movie\b|\bWeb Series\b|\bWEBSeries\b|\bAnime Series\b|\bSeries\b|\bHindi Dubbed\b|\bHindi\b|\bEnglish\b|\bTelugu\b|\bTamil\b|\bKannada\b|\bMalayalam\b|\bPunjabi\b|\bDubbed\b|\bORG\b|\bMovie\b|\bHQ\b|\bV[0-9]+\b|\bNetFlix\b|\bNetflix\b|\bAmazon Prime\b|\bPrime Video\b|\bHotstar\b|\bDisney\+? ?Hotstar\b|\bJioCinema\b|\bJio\b|\bMX Player\b|\bSonyLiv\b|\bZee5\b|\bApple TV\b|\bHBO Max\b|\bHBO Original\b|\bHBO\b)\s*", " ", ctitle, flags=re.I)
    ctitle = re.sub(r"\s+", " ", ctitle)
    ctitle = ctitle.strip(" -–|")
    ctitle = re.sub(r"\s+", " ", ctitle).strip()
    out.append({"id": slug, "title": ctitle, "type": tvtype, "year": year, "rating": None, "poster": None})

seen = set()
dedup = []
for o in out:
    if o["id"] not in seen:
        seen.add(o["id"])
        dedup.append(o)
print(__import__("json").dumps(dedup))
' "$2" 2>/dev/null || printf '[]'
}

# Cinemeta research callback: search THIS site by canonical title+year.
# Prints line-delimited JSON objects (the orchestrator merges/dedupes).
_m4u_research_site() {
    local cname="$1" cyear="$2" ctype="${3:-movie}"
    local site_html
    site_html=$(curl "${_M4U_CURL[@]}" -G "${_M4U_BASE}/" \
        --data-urlencode "s=${cname} ${cyear}" 2>/dev/null || true)
    [[ -z "$site_html" ]] && return 0
    printf '%s' "$site_html" | python3 -c "
import sys, re, html as h, json
page = sys.stdin.read()
ctitle, cyear, ctype = sys.argv[1], sys.argv[2], sys.argv[3]
ctnorm = re.sub(r'[^a-z0-9]', '', ctitle.lower())
for m in re.finditer(r'<a href=\"(https?://[^\"]+/[a-z0-9-]+/)\"[^>]*>([^<]{5,150})</a>', page):
    url, title = m.group(1), h.unescape(m.group(2)).strip()
    if any(x in url for x in ('/tag/','/category/','/page/','/author/','feed','#','?s=','wp-content')): continue
    tnorm = re.sub(r'[^a-z0-9]', '', title.lower())
    if ctnorm in tnorm or tnorm in ctnorm:
        slug = url.rstrip('/').rsplit('/',1)[-1]
        ym = re.search(r'\((\d{4})\)|(19|20)\d{2}', title)
        year = (ym.group(1) or ym.group(0)) if ym else ''
        ct = re.sub(r'^Download\s+','',title,flags=re.I)
        ct = re.sub(r'\[[^\]]*\]',' ',ct)
        ct = re.sub(r'\{[^}]*\}',' ',ct)
        ct = re.sub(r'\s*(4K|[0-9]+p)\s*.*$','',ct,flags=re.I)
        ct = re.sub(r'\s+',' ',ct).strip(' -|\u2013')
        print(json.dumps({'id':slug,'title':ct,'type':ctype,'year':year or cyear,'rating':None,'poster':None}))
" "$cname" "$cyear" "$ctype" 2>/dev/null || true
}

# Fan-out worker: resolve ONE m4ulinks page into stream JSON objects.
_m4u_get_url_worker() {
    local link="$1"
    local ep_target="${M4U_WORKER_EPISODE:-}"
    local btns
    btns=$(_m4u_resolve_m4ulinks "$link" "$ep_target") || return 0
    [[ -z "$btns" ]] && return 0

    local b su
    while IFS= read -r b; do
        [[ -z "$b" ]] && continue
        case "$b" in
            *hubcloud.cx/video*|*hubcloud.*/video*|*vcloud.*)
                _m4u_resolve_video "$b"
                ;;
            *hubcloud*|*hubdrive*)
                sdk_resolve_drive "$b" _m4u_is_stream_candidate 0 "$_M4U_PIXEL_GLOBS" "${_M4U_BASE}/"
                ;;
            *gdlink*|*gdflix*)
                _m4u_resolve_gdflix "$b"
                ;;
            *)
                if _m4u_is_stream_candidate "$b"; then
                    printf '%s\n' "$b"
                fi
                ;;
        esac
    done <<< "$btns" | while IFS=$'\t' read -r su su_q; do
        [[ -z "$su" ]] && continue
        [[ "${su,,}" == *sample* ]] && continue
        # NOTE: video-downloads.googleusercontent.com URLs are PLAYABLE streams
        # (HTTP 200 + MKV magic) as of 2026-08 — the gdlink.dev/busycdn chain
        # resolves to them. They used to be dropped here as "download pages";
        # that assumption went stale. verify_streams filters any that are
        # actually HTML by magic bytes, so emit them and let verification win.
        # pixeldrain page URL → direct file API
        if [[ "$su" == *pixeldrain* ]]; then
            su=$(sdk_normalize_pixeldrain "$su")
        fi
        # workers.dev hotlink-check needs Referer from sportverse.cc
        if [[ "$su" == *"workers.dev"* ]]; then
            _m4u_stream_json "$su" "https://sportverse.cc/" "$su_q"
        else
            _m4u_stream_json "$su" "" "$su_q"
        fi
    done
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_m4u_config
    _m4u_load_domains

    # Series episode id "series:season:episode" — resolve only that episode
    local series_id="" season="" episode=""
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi
    local detail_id="$id"
    [[ -n "$series_id" ]] && detail_id="$series_id"

    local detail_url="${_M4U_BASE}/${detail_id}/"
    local html
    html=$(curl "${_M4U_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "Movies4u detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty Movies4u detail page"

    # m4ulinks numbers on the post page.
    # BUG FIX (kept): must position-walk season headings and assign each
    # m4ulinks number to its nearest preceding "Season N" heading — without
    # it, episode 1 gets resolved from ALL seasons' pages. Also filter out
    # btn-zip (BATCH/ZIP) links which are zip packs, not per-episode pages.
    local num_links
    if [[ -n "$season" ]]; then
        num_links=$(printf '%s' "$html" | python3 -c "
import sys, re
html = sys.stdin.read()
want = int(sys.argv[1])
seen = set()
for m in re.finditer(r'<a\s[^>]*href=\"(https://m4ulinks\.[a-z]+/number/\d+)\"[^>]*class=\"([^\"]*)\"', html):
    l, cls = m.group(1), m.group(2)
    if l in seen: continue
    seen.add(l)
    if 'btn-zip' in cls or 'BATCH' in cls.upper():
        continue
    lpos = html.find(l)
    seasons = [(s.start(), int(s.group(1))) for s in re.finditer(r'Season\s*(\d+)', html, re.I)]
    cur = 1
    for spos, snum in seasons:
        if spos < lpos: cur = snum
        else: break
    if cur == want:
        print(l)
" "$season" 2>/dev/null || true)
    else
        # movie: all non-zip m4ulinks links
        num_links=$(printf '%s' "$html" | python3 -c "
import sys, re
html = sys.stdin.read()
seen = set()
for m in re.finditer(r'<a\s[^>]*href=\"(https://m4ulinks\.[a-z]+/number/\d+)\"[^>]*class=\"([^\"]*)\"', html):
    l, cls = m.group(1), m.group(2)
    if l in seen: continue
    seen.add(l)
    if 'btn-zip' in cls or 'BATCH' in cls.upper():
        continue
    print(l)
" 2>/dev/null || true)
    fi
    [[ -z "$num_links" ]] && die_plugin "No m4ulinks pages on Movies4u page for: $id"

    M4U_WORKER_EPISODE="$episode"
    SDK_FANOUT_MERGE='unique_by(.url)'
    local -a _links=()
    mapfile -t _links <<< "$num_links"
    local merged
    merged=$(sdk_fanout _m4u_get_url_worker "${_links[@]}")
    unset M4U_WORKER_EPISODE SDK_FANOUT_MERGE

    [[ -z "$merged" || "$merged" == "[]" ]] && die_plugin "No playable links resolved for: $id"
    printf '%s\n' "$merged"
}

plugin_list_seasons() {
    local series_id="$1"
    _load_m4u_config
    _m4u_load_domains

    local html
    html=$(curl "${_M4U_CURL[@]}" "${_M4U_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    local seasons_json
    seasons_json=$(printf '%s' "$html" | grep -oiE 'Season[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | jq -c '[.[] | {id: (.|tostring), title: ("Season " + (.|tostring)), number: .}]' 2>/dev/null || true)

    # Fallback: title range like "Season 1-2" or "Season 1 – 2"
    if [[ -z "$seasons_json" || "$seasons_json" == "[]" ]]; then
        local range
        range=$(printf '%s' "$html" | grep -oiE 'Season[[:space:]]*[0-9]+[[:space:]]*[-–][[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -2 | tr '\n' ' ')
        local s1 s2
        s1=$(printf '%s' "$range" | awk '{print $1}')
        s2=$(printf '%s' "$range" | awk '{print $2}')
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
    _load_m4u_config
    _m4u_load_domains

    local html
    html=$(curl "${_M4U_CURL[@]}" "${_M4U_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # m4ulinks page for this season: assign each number to the nearest
    # preceding "Season N" heading, take the first (Download Links) page.
    local target
    target=$(printf '%s' "$html" | python3 -c '
import sys, re
page = sys.stdin.read()
want = int(sys.argv[1])
links = re.findall(r"https://m4ulinks\.[a-z]+/number/\d+", page)
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
        break
' "$season_number" 2>/dev/null || true)
    [[ -z "$target" ]] && target=$(printf '%s\n' "$html" | grep -oE 'https://m4ulinks\.[a-z]+/number/[0-9]+' | head -1 || true)
    [[ -z "$target" ]] && return 1

    # count "-:Episodes: N:-" blocks on that page
    local page ep_count
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$target" 2>/dev/null || true)
    ep_count=$(printf '%s' "$page" | grep -oE 'Episodes?[[:space:]]*:?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 2>/dev/null || echo 0)
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count=$(printf '%s' "$page" | grep -cE 'downloads-btns-div' 2>/dev/null || true)
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count="1"

    # Batched JSONL → one jq pass (was one jq fork per episode)
    local lines="" i
    for (( i = 1; i <= ep_count; i++ )); do
        lines+="$(jq -nc --arg id "${series_id}:${season_number}:${i}" --arg t "Episode $i" --argjson n "$i" --argjson s "$season_number" \
            '{"id": $id, "title": $t, "number": $n, "episode": $n, "season": $s}')"$'\n'
    done
    jq -s '.' <<< "$lines"
}

plugin_health() {
    _load_m4u_config
    _m4u_load_domains
    local code
    code=$(curl -s --connect-timeout 8 --max-time 15 -A "$_M4U_UA" -o /dev/null -w '%{http_code}' "${_M4U_BASE}/" 2>/dev/null || echo 000)
    [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}\n' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
