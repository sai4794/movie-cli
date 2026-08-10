#!/usr/bin/env bash
# movies4u.sh — Movies4u plugin for movie-cli
# WordPress site (movies4u.clinic family) with the m4ulinks.site link-farm
# chain: post page → m4ulinks.site/number/N → hubcloud/video|drive + gdlink +
# gdflix buttons → resolver (sportverse/gamerxyt hubcloud.php) → direct links
# Reference: phisher98 CloudStream extension "Movies4u" (v11), decompiled.

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

_load_m4u_config() {
    local conf_file="$CONF_DIR/movies4u.conf"
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
            BASE_URL) _M4U_BASE="$value"; _M4U_BASE_USER_SET=1 ;;
            ALLOW_HOSTS) _M4U_ALLOW_HOSTS="$value" ;;
        esac
    done < "$conf_file"
}

# Auto domain rotation — same source the phisher CloudStream extensions use
_m4u_load_domains() {
    [[ "$_M4U_BASE_USER_SET" == "1" ]] && return 0
    local cached=""
    if declare -f cache_get >/dev/null 2>&1; then
        cached=$(cache_get "$_M4U_DOMAINS_CACHE_KEY" 86400 2>/dev/null || true)
    fi
    if [[ -z "$cached" ]]; then
        cached=$(curl -s --connect-timeout 6 --max-time 15 -A "$_M4U_UA" "$_M4U_DOMAINS_URL" 2>/dev/null || true)
        if [[ -n "$cached" ]] && printf '%s' "$cached" | jq -e . >/dev/null 2>&1; then
            if declare -f cache_set >/dev/null 2>&1; then
                cache_set "$_M4U_DOMAINS_CACHE_KEY" "$cached" || true
            fi
        else
            cached=""
        fi
    fi
    [[ -z "$cached" ]] && return 0
    local dom
    dom=$(printf '%s' "$cached" | jq -r '.["movies4u"] // empty' 2>/dev/null || true)
    [[ -z "$dom" || "$dom" == "null" ]] && return 0
    dom="${dom%/}"
    if [[ "$dom" != "$_M4U_BASE" ]]; then
        debug "Movies4u domain rotated: $_M4U_BASE → $dom"
        _M4U_BASE="$dom"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Stream candidate policy (same philosophy as dudefilms/hdhub4u)
# ═══════════════════════════════════════════════════════════════
_m4u_is_stream_candidate() {
    local link="$1"
    local lower
    lower=$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')

    # Hard rejects — never streams
    case "$lower" in
        *tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*hubcloud.cx/video*|*googlesyndication*|*winexch*|*effectivecpm*|*profitableratecpm*|*a-ads*|*khelostar*|*drivebot*|*filesgram*|*tgredirect*|*multiup*|*royaljeet*|*bit.ly*)
            return 1 ;;
    esac

    if [[ -n "$_M4U_ALLOW_HOSTS" ]]; then
        local host allow
        host=$(printf '%s' "$lower" | sed -E 's|^https?://([^/]+).*|\1|')
        local -a allow_arr=()
        IFS=',' read -r -a allow_arr <<< "$_M4U_ALLOW_HOSTS"
        for allow in "${allow_arr[@]}"; do
            allow="${allow,,}"
            [[ -n "$allow" && "$host" == *"$allow"* ]] && return 0
        done
    fi

    case "$lower" in
        *workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*|*gdlink*|*filepress*|*gofile*|*d0000d*|*drop.download*|*dood*|*driveapp*|*gdtot*|*gpdl*|*filesdl*)
            return 0 ;;
    esac

    case "$lower" in
        *.mkv*|*.mp4*|*.webm*|*.m3u8*|*.flv*|*.mov*|*.avi*|*.ts*)
            return 0 ;;
    esac

    return 1
}

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
    local url="$1"
    local referer="${2:-}"
    local qual
    qual=$(_m4u_quality "$url")
    if [[ -n "$referer" ]]; then
        jq -nc --arg u "$url" --arg q "$qual" --arg r "$referer" '{quality: $q, url: $u, size: "unknown", provider: "movies4u", referer: $r}'
    else
        jq -nc --arg u "$url" --arg q "$qual" '{quality: $q, url: $u, size: "unknown", provider: "movies4u"}'
    fi
}

# ═══════════════════════════════════════════════════════════════
# Resolvers
# ═══════════════════════════════════════════════════════════════

# Last hop: resolver page (sportverse/gamerxyt hubcloud.php) → direct links.
# Resolver pages list a.btn hrefs; keep stream candidates, resolve pixel
# redirectors, drop gates (tg/go, bit.ly, ads).
_m4u_resolve_resolver() {
    local resolver_url="$1"
    local page
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$resolver_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    printf '%s' "$page" | grep -oE '<a[^>]*href="https?://[^"]+"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        case "$link" in
            *pixel.hubcloud.cx*|*gpdl*)
                _m4u_resolve_pixel "$link"
                ;;
            *pixeldrain*)
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
                if _m4u_is_stream_candidate "$link"; then
                    printf '%s\n' "$link"
                fi
                ;;
        esac
    done
}

# pixel/gpdl redirector → real link (dl.php?link= extraction)
_m4u_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final url_eff
    page=$(curl "${_M4U_CURL[@]}" -o /tmp/m4u_pixel_body.$$ -w '%{url_effective}' "$pixel_url" 2>/dev/null || true)
    url_eff="$page"
    page=$(cat /tmp/m4u_pixel_body.$$ 2>/dev/null || true)
    rm -f /tmp/m4u_pixel_body.$$
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^" ]*dl\.php\?link=[^" ]+' | head -1 2>/dev/null || true)
    if [[ -z "$dl_url" && "$url_eff" == *"dl.php?link="* ]]; then
        dl_url="$url_eff"
    fi
    [[ -z "$dl_url" ]] && return 1
    final=$(printf '%s' "$dl_url" | sed -E 's/.*link=//' | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || true)
    [[ -z "$final" ]] && return 1
    printf '%s\n' "$final"
}

# hubcloud drive page → id="download" href (resolver) → direct links
_m4u_resolve_drive() {
    local drive_url="$1"
    local page href base
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$drive_url" 2>/dev/null) || return 1
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
    _m4u_resolve_resolver "$href"
}

# hubcloud video page → resolver href (sportverse hubcloud.php) → direct links
_m4u_resolve_video() {
    local video_url="$1"
    local page href
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$video_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1
    href=$(printf '%s' "$page" | grep -oE 'href="https?://[^"]*hubcloud\.php[^"]*"' | head -1 | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
    [[ -z "$href" ]] && return 1
    _m4u_resolve_resolver "$href"
}

# gdlink.dev/file/ID → Instant DL (busycdn) direct link; gates dropped.
# NOTE: busycdn links redirect to googleusercontent download pages — not
# playable streams, filtered by _m4u_is_stream_candidate. Only genuine
# candidates survive.
_m4u_resolve_gdlink() {
    local url="$1"
    local page
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1
    printf '%s' "$page" | grep -oE 'href="https?://[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        if _m4u_is_stream_candidate "$link"; then
            printf '%s\n' "$link"
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
# Args: url, want_episode ("" for all/movie), want_season_ep (unused)
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

    printf '%s' "$html" | python3 -c '
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
' "$query" 2>/dev/null || printf '[]'
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

    # m4ulinks numbers on the post page
    # BUG FIX: must position-walk season headings and assign each m4ulinks
    # number to its nearest preceding "Season N" heading. Without this,
    # episode 1 gets resolved from ALL seasons' m4ulinks pages (S1-S5),
    # mixing S1E1 with S2E1, S3E1, etc. Also filter out btn-zip (BATCH/ZIP)
    # links which are zip packs, not per-episode download pages.
    local num_links
    if [[ -n "$season" ]]; then
        num_links=$(printf '%s' "$html" | python3 -c "
import sys, re
html = sys.stdin.read()
want = int(sys.argv[1])
seen = set()
for m in re.finditer(r'<a\s[^>]*href=\"(https://m4ulinks\.(?:site|com)/number/\d+)\"[^>]*class=\"([^\"]*)\"', html):
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
for m in re.finditer(r'<a\s[^>]*href=\"(https://m4ulinks\.(?:site|com)/number/\d+)\"[^>]*class=\"([^\"]*)\"', html):
    l, cls = m.group(1), m.group(2)
    if l in seen: continue
    seen.add(l)
    if 'btn-zip' in cls or 'BATCH' in cls.upper():
        continue
    print(l)
" 2>/dev/null || true)
    fi
    [[ -z "$num_links" ]] && die_plugin "No m4ulinks pages on Movies4u page for: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0

    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local btns ep_target=""
            if [[ -n "$episode" ]]; then
                ep_target="$episode"
            fi
            btns=$(_m4u_resolve_m4ulinks "$link" "$ep_target" 2>/dev/null || true)
            if [[ -n "$btns" ]]; then
                printf '%s\n' "$btns" | while IFS= read -r b; do
                    [[ -z "$b" ]] && continue
                    case "$b" in
                        *hubcloud.cx/video*|*hubcloud.*/video*|*vcloud.*)
                            _m4u_resolve_video "$b"
                            ;;
                        *hubcloud*|*hubdrive*)
                            _m4u_resolve_drive "$b"
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
                done | while IFS= read -r su; do
                    [[ -z "$su" ]] && continue
                    [[ "${su,,}" == *sample* ]] && continue
                    # googleusercontent download pages are not playable streams
                    [[ "${su,,}" == *video-downloads.googleusercontent* ]] && continue
                    # pixeldrain page URL → direct file API
                    if [[ "$su" == *pixeldrain* && "$su" != *"/api/file/"* && "$su" != *"download"* ]]; then
                        local pd_base pd_id
                        pd_base=$(printf '%s' "$su" | sed -E 's|^(https?://[^/]+).*|\1|')
                        pd_id="${su##*/}"
                        [[ -n "$pd_id" ]] && su="${pd_base}/api/file/${pd_id}?download"
                    fi
                    # workers.dev hotlink-check needs Referer from sportverse.cc
                    if [[ "$su" == *"workers.dev"* ]]; then
                        _m4u_stream_json "$su" "https://sportverse.cc/"
                    else
                        _m4u_stream_json "$su"
                    fi
                done > "$tmp_dir/out_${idx}.json"
            fi
        ) &
        pids+=($!)
        idx=$((idx + 1))
    done <<< "$num_links"

    wait "${pids[@]}" 2>/dev/null || true

    local merged="[]"
    if compgen -G "$tmp_dir/out_*.json" > /dev/null 2>&1; then
        # out_*.json are line-delimited objects; jq -s slurps them into the
        # array directly (never 'add' — that merges objects into one).
        merged=$(cat "$tmp_dir"/out_*.json 2>/dev/null | jq -s 'unique_by(.url)' 2>/dev/null) || merged="[]"
    fi
    rm -rf "$tmp_dir"

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

    if [[ -z "$seasons_json" || "$seasons_json" == "[]" ]]; then
        local range
        range=$(printf '%s' "$html" | grep -oiE 'Season[[:space:]]*[0-9]+[[:space:]]*[-–][[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -2 | tr '\n' ' ')
        local s1 s2
        s1=$(printf '%s' "$range" | awk '{print $1}')
        s2=$(printf '%s' "$range" | awk '{print $2}')
        if [[ -n "$s1" && -n "$s2" && "$s2" -gt "$s1" ]]; then
            seasons_json="[]"
            local i
            for (( i = s1; i <= s2; i++ )); do
                seasons_json=$(printf '%s' "$seasons_json" | jq -c --argjson n "$i" '. + [{"id": ($n|tostring), "title": ("Season " + ($n|tostring)), "number": $n}]' 2>/dev/null)
            done
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
links = re.findall(r"https://m4ulinks\.(?:site|com)/number/\d+", page)
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
    [[ -z "$target" ]] && target=$(printf '%s\n' "$html" | grep -oE 'https://m4ulinks\.(site|com)/number/[0-9]+' | head -1 || true)
    [[ -z "$target" ]] && return 1

    # count "-:Episodes: N:-" blocks on that page
    local page ep_count
    page=$(curl "${_M4U_CURL[@]}" -H "Referer: ${_M4U_BASE}/" "$target" 2>/dev/null || true)
    ep_count=$(printf '%s' "$page" | grep -oE 'Episodes?[[:space:]]*:?[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 2>/dev/null || echo 0)
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count=$(printf '%s' "$page" | grep -cE 'downloads-btns-div' 2>/dev/null || echo 1)
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count="1"

    local i eps_json="[]"
    for (( i = 1; i <= ep_count; i++ )); do
        eps_json=$(printf '%s' "$eps_json" | jq -c --arg id "${series_id}:${season_number}:${i}" --arg t "Episode $i" --argjson n "$i" --argjson s "$season_number" \
            '. + [{"id": $id, "title": $t, "number": $n, "episode": $n, "season": $s}]' 2>/dev/null)
    done
    printf '%s\n' "$eps_json"
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
