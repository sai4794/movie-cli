#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# VegaMovies plugin for movie-cli
# Wordpress movie site (vegamovies.catering, rotates) — Typesense
# search + nexdrive.fit resolver pages + V-Cloud (hubcloud-family)
# video links. Reverse-engineered from the CloudStream CSX
# VegaMovies.cs3 (version 82).
#
# Chain (all verified live):
#   search:  /search.php?q=<query>            → Typesense JSON hits[].document
#   detail:  /<permalink>                     → nexdrive.fit/genxfm... hrefs
#   resolver: nexdrive.fit/genxfm...          → vcloud.zip/j_... + gpdl2.hubcloud.cx
#   vcloud:  vcloud.zip/j_...                 → script: var url = '...' (double-atob)
#   token:   vcloud.zip/j_...?token=<decoded> → r2.cloudflarestorage.com/...mkv?X-Amz-...  ← direct stream
#                                             → gpdl2.hubcloud.cx/?id=... (pixel-class)
#
# Domain rotation: SaurabhKaperwan/Utils/urls.json (key "vegamovies").
# ═══════════════════════════════════════════════════════════════

[[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"

PLUGIN_NAME="VegaMovies"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq" "python3")
PLUGIN_AUTHOR="movie-cli"
PLUGIN_DESCRIPTION="Movies and series from VegaMovies (nexdrive + V-Cloud/hubcloud chain)"

_VM_BASE="https://vegamovies.catering"
_VM_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36"
_VM_CURL=(-sL --connect-timeout 8 --max-time 25 -A "$_VM_UA")
_VM_ALLOW_HOSTS=""
# Live domain list — same source the CSX VegaMovies extension uses
# (SaurabhKaperwan/Utils/urls.json). Auto-rotation for site moves.
_VM_DOMAINS_URL="https://raw.githubusercontent.com/SaurabhKaperwan/Utils/refs/heads/main/urls.json"
_VM_DOMAINS_CACHE_KEY="vegamovies_domains"
_VM_BASE_USER_SET=0   # 1 = user set BASE_URL in conf (wins over auto-rotation)

# Stream-candidate policy as DATA (algorithm lives in lib/pluginsdk.sh):
# hard rejects → user allowlist → known host families → media extensions.
_VM_REJECT_GLOBS='*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me/*|*googlesyndication*|*doubleclick*|*bit\.ly*|*cutt\.ly*|*nexdrive*|*wp-content*|*gmpg*|*xmlrpc*|*vegamovies-apk*|*gokuhd*|*rogmovies*'
_VM_FAMILY_GLOBS='*vcloud*|*hubcloud*|*hubdrive*|*r2.cloudflarestorage*|*gpdl*|*pixeldrain*|*gofile*|*filebee*|*megaup*|*transfer\.it*|*vikingfile*|*fastdl*|*fsl*|*workers.dev*|*googleusercontent*'

_load_vm_config() {
    sdk_conf_load "$CONF_DIR/vegamovies.conf" VM BASE_URL ALLOW_HOSTS
    [[ -n "${VM_BASE_URL:-}" ]] && { _VM_BASE="$VM_BASE_URL"; _VM_BASE_USER_SET="${VM_USER_SET:-1}"; }
    [[ -n "${VM_ALLOW_HOSTS+x}" ]] && _VM_ALLOW_HOSTS="$VM_ALLOW_HOSTS"
}

# Auto domain rotation (CSX-style): fetch the live URL list once a day
_vm_load_domains() {
    [[ "$_VM_BASE_USER_SET" == "1" ]] && return 0
    local dom
    dom=$(sdk_rotate_domain "$_VM_DOMAINS_CACHE_KEY" "$_VM_DOMAINS_URL" \
        "vegamovies" "$_VM_BASE" "VegaMovies" "$_VM_UA") || return 0
    [[ -z "$dom" ]] && return 0
    _VM_BASE="$dom"
}

# Fuzzy host matching — same policy as 4khdhub/hdhub4u: match broadly,
# let verify_streams filter garbage. VegaMovies resolver pages emit
# vcloud/gpdl2/r2/gofile/filebee/megaup/transfer/vikingfile links.
_vm_is_stream_candidate() {
    sdk_is_stream_candidate "$1" "$_VM_ALLOW_HOSTS" "$_VM_REJECT_GLOBS" "$_VM_FAMILY_GLOBS"
}

_vm_quality() {
    sdk_quality_suffix "$1"
}

_vm_stream_json() {
    # Quality is detected from the RAW url (pre-encoding), matching CSX.
    local url="$1"
    sdk_stream_json_encoded "vegamovies" "$(sdk_quality_suffix "$url")" "$url"
}

# Resolve one vcloud.zip/j_... (or fastdl.zip/embed) link → direct video URLs.
# Follows the CSX VCloud extractor: fetch page, double-atob the
# "var url = '...'" payload, fetch tokenized URL, extract r2/gpdl2 links.
# NOTE: token-URL fetches can hang server-side (observed on dead season-pack
# links) — use a short max-time so one dead link can't stall the pipeline.
_vm_resolve_vcloud() {
    local vc_url="$1"
    local page

    page=$(curl -sL --connect-timeout 6 --max-time 12 -A "$_VM_UA" "$vc_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    # /video/ pages (hubcloud.lol/video/<id> etc): the CSX extractor takes
    # div.vd > center > a — the hubcloud.php resolver link. Follow it and
    # collect its btn links (R2/pixeldrain/gpdl).
    if [[ "$vc_url" == *"/video/"* ]]; then
        local resolver
        resolver=$(printf '%s' "$page" | python3 -c '
import sys, re
html = sys.stdin.read()
m = re.search(r"<div[^>]*class=\"[^\"]*vd[^\"]*\"[^>]*>(.*?)</div>", html, re.S)
if m:
    a = re.search(r"<a[^>]*href=\"([^\"]+)\"", m.group(1))
    if a and "hubcloud.php" in a.group(1):
        print(a.group(1))
' 2>/dev/null || true)
        if [[ -n "$resolver" ]]; then
            local rpage
            rpage=$(curl -sL --connect-timeout 6 --max-time 12 -A "$_VM_UA" "$resolver" 2>/dev/null || true)
            if [[ -n "$rpage" ]]; then
                printf '%s' "$rpage" | python3 -c '
import sys, re
html = sys.stdin.read()
out = []
for m in re.finditer(r"<a[^>]*href=\"(https?://[^\"]+)\"[^>]*class=\"[^\"]*btn[^\"]*\"", html):
    h = m.group(1)
    if any(k in h for k in ("pixeldrain", "gpdl", "r2.dev", "cloudflarestorage", "hubcloud")):
        out.append(h)
seen = list(dict.fromkeys(out))
for l in seen:
    print(l)
' 2>/dev/null | while IFS= read -r l; do
                    if [[ "$l" == *pixeldrain* && "$l" != *"/api/file/"* ]]; then
                        printf '%s\n' "https://pixeldrain.dev/api/file/${l##*/}?download"
                    else
                        printf '%s\n' "$l"
                    fi
                done | sort -u
                return 0
            fi
        fi
    fi

    # Direct links on the page already? (r2/gpdl2 present without token hop).
    # Exclude signup.php — that's a decoy ad page, not a stream.
    # NOTE: hubcloud /video/ links are NOT direct — they lead to a resolver
    # whose content may differ from this token's file; the real streams are
    # the FSL/Mega/Pixel/10Gbps buttons on the token page below.
    local direct
    direct=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' <>]*' | grep -E 'r2\.cloudflarestorage|gpdl[0-9]*\.hubcloud' | grep -v 'signup\.php' | grep -vE 'unpkg|site\.webmanifest' | sort -u 2>/dev/null || true)
    if [[ -n "$direct" ]]; then
        while IFS= read -r l; do
            if [[ "$l" == *pixeldrain.dev/u/* ]]; then
                local dpid
                dpid=${l##*/}
                printf '%s\n' "https://pixeldrain.dev/api/file/${dpid}?download"
            else
                printf '%s\n' "$l"
            fi
        done <<< "$direct"
        return 0
    fi

    # var url = '...' — double-base64 (double-atob) payload → tokenized URL
    local payload
    payload=$(printf '%s' "$page" | grep -oE "atob\(atob\('[^']*'\)\)" | head -1 | grep -oE "'[^']*'" | tr -d "'" 2>/dev/null || true)
    [[ -z "$payload" ]] && return 1

    local decoded
    decoded=$(printf '%s' "$payload" | python3 -c '
import sys, base64
s = sys.stdin.read().strip()
try:
    first = base64.b64decode(s + "=" * (-len(s) % 4))
    p2 = first.decode().strip()
    second = base64.b64decode(p2 + "=" * (-len(p2) % 4))
    print(second.decode())
except Exception:
    sys.exit(1)
' 2>/dev/null || true)
    [[ -z "$decoded" ]] && return 1

    # Tokenized URL page → extract the real video links (short timeout:
    # dead links hang server-side and must not stall the whole resolution)
    local tok_page
    tok_page=$(curl -sL --connect-timeout 6 --max-time 10 -A "$_VM_UA" "$decoded" 2>/dev/null) || return 1
    [[ -z "$tok_page" ]] && return 1

    # CloudStream-parity: parse the `a.btn` button menu exactly like the CSX
    # VCloud extractor does. The button text identifies the server:
    #   "Download [FSLv2 Server]" / FSL Server / Mega / Download File → href
    #     (these are R2/FSL direct links)
    #   PixelServer → pixeldrain → the token page needs the api/file suffix
    #   BuzzServer  → hx-redirect header dance
    #   Server : 10Gbps → resolveFinalUrl, `link=` param decode
    #   Telegram/bit.ly → decoys, skipped
    local found
    found=$(printf '%s' "$tok_page" | python3 -c '
import sys, re
html = sys.stdin.read()
out = []
for m in re.finditer(r"<a[^>]*class=\"[^\"]*btn[^\"]*\"[^>]*>.*?</a>", html, re.S):
    raw = m.group(0)
    text = re.sub(r"<[^>]+>", " ", raw)
    text = re.sub(r"\s+", " ", text).strip().lower()
    hrefm = re.search(r"href=\"([^\"]+)\"", raw)
    if not hrefm:
        continue
    href = hrefm.group(1)
    if "bit.ly" in href or "tg/go" in href or "telegram" in text:
        continue  # ad/telegram decoys
    if ("fsl" in text or "mega" in text or "download" in text or "10gbps" in text
            or "pixel" in text or "buzz" in text):
        out.append(href)
seen = list(dict.fromkeys(out))
for l in seen:
    print(l)
' 2>/dev/null || true)
    if [[ -n "$found" ]]; then
        # Normalize pixeldrain short-links to API download form (matches
        # CSX: base + /api/file/<id>?download).
        while IFS= read -r l; do
            if [[ "$l" == *"/video/"* ]]; then
                continue  # hubcloud video decoy — not this token's file
            elif [[ "$l" == *pixeldrain.dev/u/* ]]; then
                local id
                id=${l##*/}
                printf '%s\n' "https://pixeldrain.dev/api/file/${id}?download"
            else
                printf '%s\n' "$l"
            fi
        done <<< "$found"
        return 0
    fi

    # Fallback: raw string grep (older page shapes with inline links)
    local fgrep
    fgrep=$(printf '%s' "$tok_page" | grep -oE 'https?://[^"'"'"' <>]*' | grep -E 'r2\.cloudflarestorage|gpdl[0-9]*\.hubcloud|\.mkv|\.mp4' | grep -vE 'unpkg|site\.webmanifest' | sort -u 2>/dev/null || true)
    [[ -n "$fgrep" ]] && printf '%s\n' "$fgrep"
}

# Resolve one nexdrive.fit/genxfm... resolver page → candidate stream URLs.
# V-Cloud chains run in parallel (dead links hang; one slow link must not
# serialize the whole page). NOTE: read links into an ARRAY first — a
# `... | while read` pipeline runs in a subshell and background pids would
# be lost, racing the output collection.
_vm_resolve_nexdrive() {
    local nx_url="$1"
    local page

    page=$(curl -sL --connect-timeout 8 --max-time 20 -A "$_VM_UA" -H "Referer: ${_VM_BASE}/" "$nx_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    local -a links=()
    local _vm_links_tmp
    _vm_links_tmp=$(mktemp 2>/dev/null || mktemp -t vegamovies_links)
    printf '%s' "$page" | grep -oE 'href="https?://[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u > "$_vm_links_tmp" 2>/dev/null || true
    while IFS= read -r l; do
        [[ -n "$l" ]] && links+=("$l")
    done < "$_vm_links_tmp"
    rm -f "$_vm_links_tmp" 2>/dev/null || true

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    local link
    for link in "${links[@]}"; do
        case "$link" in
            *gpdl*.hubcloud.cx*)
                # pixel-class redirector → follow to the real link
                # NOTE: must be checked BEFORE the hubcloud.cx V-Cloud family
                # below — *hubcloud.cx* would swallow gpdl2.hubcloud.cx links
                # into the VCloud resolver (SC2221/SC2222).
                (
                    local final
                    final=$(curl -sL --connect-timeout 6 --max-time 10 -A "$_VM_UA" -o /dev/null -w '%{url_effective}' "$link" 2>/dev/null || true)
                    [[ -n "$final" ]] && printf '%s\n' "$final"
                ) > "$tmp_dir/out_${idx}.txt" &
                pids+=($!)
                ;;
            *vcloud.zip*|*fastdl.zip*|*vcloud.fit*|*vcloud.org*|*vcloud.*|*hubcloud.fit*|*hubcloud.cx*)
                (
                    # V-Cloud pages: short-form vcloud.fit/<id> pages carry the
                    # double-atob token chain; route ALL vcloud-family links
                    # through the CSX-parity VCloud resolver.
                    _vm_resolve_vcloud "$link"
                ) > "$tmp_dir/out_${idx}.txt" &
                pids+=($!)
                ;;
            *)
                if _vm_is_stream_candidate "$link"; then
                    printf '%s\n' "$link" > "$tmp_dir/out_${idx}.txt" &
                    pids+=($!)
                fi
                ;;
        esac
        idx=$((idx + 1))
    done

    wait "${pids[@]}" 2>/dev/null || true

    local out=""
    if compgen -G "$tmp_dir/out_*.txt" > /dev/null 2>&1; then
        out=$(cat "$tmp_dir"/out_*.txt 2>/dev/null | sort -u)
    fi
    rm -rf "$tmp_dir"
    [[ -n "$out" ]] && printf '%s\n' "$out"
}

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_vm_config
    _vm_load_domains

    local response
    response=$(curl -s --connect-timeout 8 --max-time 25 \
        -A "$_VM_UA" \
        -G "${_VM_BASE}/search.php" \
        --data-urlencode "q=$query" 2>/dev/null) || return 1
    [[ -z "$response" ]] && return 1

    printf '%s' "$response" | jq -c '
        [.hits[]?.document |
        {
            id: (.permalink | sub("^https?://[^/]+"; "") | gsub("^/"; "") | gsub("/$"; "")),
            title: (.post_title
                | sub("^Download "; "")
                | gsub("\\[[^\\]]*\\]"; " ")
                | gsub("\\{[^}]*\\}"; " ")
                | sub("\\s*(4K|[0-9]+p)\\s*.*$"; "")
                | gsub("\\s*(?:\\bDual Audio\\b|\\bMulti Audio\\b|\\bWEB-? ?DL\\b|\\bWEBRip\\b|\\bBluRay\\b|\\bHDTS\\b|\\bHDTC\\b|\\bHDCAM\\b|\\bCAMRip\\b|\\bPREHD\\b|\\bx264\\b|\\bx265\\b|\\b10Bit\\b|\\bHEVC\\b|\\bESubs?\\b|\\bFull Movie\\b|\\bWeb Series\\b|\\bWEBSeries\\b|\\bAnime Series\\b|\\bSeries\\b|\\bHindi Dubbed\\b|\\bHindi\\b|\\bEnglish\\b|\\bTelugu\\b|\\bTamil\\b|\\bKannada\\b|\\bMalayalam\\b|\\bPunjabi\\b|\\bDubbed\\b|\\bORG\\b|\\bMovie\\b|\\bHQ\\b|\\bV[0-9]+\\b|\\bNetFlix\\b|\\bNetflix\\b|\\bAmazon Prime\\b|\\bPrime Video\\b|\\bHotstar\\b|\\bDisney\\+? ?Hotstar\\b|\\bJioHotstar\\b|\\bJioCinema\\b|\\bJio\\b|\\bMX Player\\b|\\bSonyLiv\\b|\\bZee5\\b|\\bApple TV\\b|\\bHBO Max\\b|\\bHBO Original\\b|\\bHBO\\b)\\s*"; " "; "i")
                | gsub("\\(\\s*\\)"; "")
                | gsub("\\s*:\\s*$"; "")
                | gsub("\\s*[-–]\\s*"; "-")
                | gsub("\\s+"; " ")
                | gsub("^\\s+|\\s+$"; "")
                | rtrimstr(" -–|") | ltrimstr(" -–|")
                | gsub("\\s+"; " ")),
            type: (if (.post_title | test("Season [0-9]|Series|TV"; "i")) then "series" else "movie" end),
            year: (if (.post_title | test("\\((19|20)[0-9]{2}\\)")) then (.post_title | capture("\\((?<year>(19|20)[0-9]{2})\\)").year) else null end),
            rating: null,
            poster: .post_thumbnail,
            _cat: (.category // [])
        }]
    ' 2>/dev/null | python3 -c '
import sys, json, re
items = json.load(sys.stdin)
query = sys.argv[1].lower() if len(sys.argv) > 1 else ""

def norm(s):
    return re.sub(r"[^a-z0-9]", "", s.lower())

qtokens = [t for t in re.split(r"[^a-z0-9]+", query) if len(t) >= 3]
if not qtokens:
    qtokens = [re.sub(r"[^a-z0-9]", "", query)]
qnorm = norm(query)
out = []
for it in items:
    title = it.get("title") or ""
    tnorm = norm(title)
    twords = re.split(r"[^a-z0-9]+", title.lower())
    cats = [norm(c) for c in (it.get("_cat") or [])]
    if qnorm and qnorm in tnorm:
        out.append(it)
    elif qtokens and all(any(t == w for w in twords) for t in qtokens):
        out.append(it)
    elif qtokens and any(any(t == w for w in cats) for t in qtokens):
        # category match (actor/language/quality searches etc.)
        out.append(it)
for o in out:
    o.pop("_cat", None)
print(json.dumps(out))
' "$query" 2>/dev/null
}

# Season-position walk shared by get_url/list_episodes: assign each
# nexdrive link to its nearest preceding "Season N" heading.
_vm_season_links() {
    local html_page="$1" want="$2"
    printf '%s' "$html_page" | python3 -c '
import sys, re
html = sys.stdin.read()
want = sys.argv[1]
tokens = []
for m in re.finditer(r"Season\s*(\d+)", html):
    tokens.append((m.start(), "S", m.group(1)))
for m in re.finditer(r"href=\"(https://nexdrive\.fit/genxfm\d+/)\"", html):
    tokens.append((m.start(), "L", m.group(1)))
tokens.sort(key=lambda t: t[0])
cur = "0"
out = []
for pos, kind, val in tokens:
    if kind == "S":
        cur = val
    elif cur == want:
        out.append(val)
print("\n".join(dict.fromkeys(out)))
' "$want" 2>/dev/null || true
}

# Hub-page resolver (2026-08 redesign): a series post is now a HUB page with
# per-season headings + "Download Now" buttons linking to individual season
# pages; the nexdrive resolver links live on those season pages, NOT the hub.
# Given hub HTML + a season number, return the season page URL path (e.g.
# "/download-money-heist-season-1-hindi-english-480p-720p/"), or empty.
# Position-walk: assign each Download Now link to its nearest preceding
# "Season N" heading.
_vm_hub_season_url() {
    local html_page="$1" want="$2"
    printf '%s' "$html_page" | python3 -c '
import sys, re
html = sys.stdin.read()
want = sys.argv[1]
tokens = []
for m in re.finditer(r"Season\s*(\d+)", html):
    tokens.append((m.start(), "S", m.group(1)))
for m in re.finditer(r"<a[^>]*href=[\"\x27](/download-[^\"\x27]+)[\"\x27][^>]*>\s*<button[^>]*class=\"dwd-button\"[^>]*>\s*Download Now\s*</button>", html):
    tokens.append((m.start(), "L", m.group(1)))
tokens.sort(key=lambda t: t[0])
cur = None
for pos, kind, val in tokens:
    if kind == "S":
        cur = val
    elif kind == "L" and cur == want:
        print(val)
        break
' "$want" 2>/dev/null || true
}

# True when the page is a hub page: has Download Now season buttons but NO
# nexdrive resolver links. Used to decide whether to follow a season link.
_vm_is_hub_page() {
    local html_page="$1"
    # here-string, not a printf pipe — grep -q exits on first match and a
    # large page makes printf hit SIGPIPE (141) → pipefail → false flip.
    if grep -qE 'https://nexdrive\.fit/genxfm' <<< "$html_page"; then
        return 1   # has resolver links → not a hub
    fi
    grep -qE 'class="dwd-button">[^<]*Download Now' <<< "$html_page"
}

# Extract EVERY nexdrive resolver link from a page (no season position-walk).
# Used on dedicated season pages (post-2026-08 redesign) where all the links
# belong to the one season, and on movie pages.
_vm_all_nexdrive_links() {
    local html_page="$1"
    printf '%s' "$html_page" | grep -oE 'href="https://nexdrive\.fit/genxfm[0-9]+/"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true
}

# Episode-links page pairing: prefer vcloud.fit → fastdl.zip → dgdrive
# (ad-gated, last resort), bounded to each "Episodes: N:-" block so a block
# missing the preferred family cannot steal the next episode's link.
_vm_episode_pairs() {
    local ep_html="$1"
    printf '%s' "$ep_html" | python3 -c '
import sys, re
html = sys.stdin.read()
labels = [(m.start(), int(m.group(1))) for m in re.finditer(r"Episodes:\s*([0-9]+)\s*:-", html)]
families = [r"https://vcloud\.fit/[^\"]+", r"https://fastdl\.zip/[^\"]+", r"https://dgdrive\.pro/[^\"]+"]
alllinks = {}
for fam in families:
    alllinks[fam] = [(m.start(), m.group(1)) for m in re.finditer(r"href=\"(" + fam + r")\"", html)]
pairs = []
for lpos, n in labels:
    nxt_label = next((p for p, _ in labels if p > lpos), len(html))
    for fam in families:
        nxt = next((l for p2, l in alllinks[fam] if lpos < p2 < nxt_label), None)
        if nxt:
            pairs.append((n, nxt))
            break
for n, l in sorted(set(pairs)):
    print("%d|%s" % (n, l))
' 2>/dev/null || true
}

# Fan-out worker: resolve ONE nexdrive/vcloud link into stream JSON objects.
_vm_get_url_worker() {
    local link="$1"
    local streams=""
    # Direct vcloud-family links (from the episode lookup) go straight to
    # the VCloud resolver (double-atob + button menu). Other links are
    # nexdrive resolver pages.
    case "$link" in
        *vcloud.fit*|*vcloud.zip*|*fastdl.zip*|*vcloud.org*)
            streams=$(_vm_resolve_vcloud "$link")
            ;;
        *)
            streams=$(_vm_resolve_nexdrive "$link")
            ;;
    esac
    [[ -z "$streams" ]] && return 0
    local su
    while IFS= read -r su; do
        [[ -z "$su" ]] && continue
        [[ "${su,,}" == *sample* ]] && continue
        _vm_stream_json "$su"
    done <<< "$streams"
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_vm_config
    _vm_load_domains

    # Series episode id "series:season:episode" — the season-pack post lists
    # the same resolver links for all episodes; select by season block.
    local series_id="" season="" episode=""
    if [[ "$id" == *:*:* ]]; then
        IFS=':' read -r series_id season episode <<< "$id"
    fi

    local detail_url
    if [[ -n "$series_id" ]]; then
        detail_url="${_VM_BASE}/${series_id}/"
    else
        detail_url="${_VM_BASE}/${id}/"
    fi
    local html
    html=$(curl "${_VM_CURL[@]}" "$detail_url" 2>/dev/null) || die_network "VegaMovies detail page fetch failed"
    [[ -z "$html" ]] && die_plugin "Empty VegaMovies detail page"

    # 2026-08 redesign: series posts are now HUB pages — per-season headings +
    # "Download Now" buttons, and NO nexdrive resolver links. The resolver
    # links live on each season's dedicated page. If this is a hub page,
    # follow the requested season's button to its page and work from there.
    if _vm_is_hub_page "$html"; then
        local want_season="${season:-1}"
        local season_path
        season_path=$(_vm_hub_season_url "$html" "$want_season")
        if [[ -n "$season_path" ]]; then
            local season_html
            season_html=$(curl "${_VM_CURL[@]}" -H "Referer: $detail_url" "${_VM_BASE}${season_path}" 2>/dev/null || true)
            [[ -n "$season_html" ]] && html="$season_html"
        fi
    fi

    # nexdrive resolver links — the download buttons on the page.
    # For series episodes "series:season:episode", use the EPISODE's own
    # link (the dgdrive URL from the episode-links page) instead of the
    # season's batch links — resolving the batch gives the whole-season
    # zip, not the requested episode.
    local nx_links
    if [[ -n "$season" && -n "$episode" ]]; then
        # fetch the episode-links pages for this season, find episode N's url.
        # Position-walk first (multi-season pages); fall back to every link
        # (dedicated season pages post-redesign hold one season's links).
        local season_links
        season_links=$(_vm_season_links "$html" "$season")
        [[ -z "$season_links" ]] && season_links=$(_vm_all_nexdrive_links "$html")
        # Merge per-episode across host families (2026-08 redesign: one
        # episode-links page per family — G-Direct/fastdl.zip often dead,
        # V-Cloud/vcloud.fit works). Prefers vcloud.fit > fastdl.zip > dgdrive.
        local found=""
        found=$(_vm_episode_pairs_merged "$season_links" | awk -F'|' -v want="$episode" '$1 == want {print $2; exit}')
        if [[ -n "$found" ]]; then
            nx_links="$found"
        else
            # episode page missing — fall back to the season's links
            nx_links="$season_links"
        fi
    elif [[ -n "$season" ]]; then
        nx_links=$(_vm_season_links "$html" "$season")
        [[ -z "$nx_links" ]] && nx_links=$(_vm_all_nexdrive_links "$html")
    else
        nx_links=$(_vm_all_nexdrive_links "$html")
    fi
    [[ -z "$nx_links" ]] && die_plugin "No resolver links on VegaMovies page for: $id"

    local -a _links=()
    mapfile -t _links <<< "$nx_links"
    local merged
    merged=$(sdk_fanout _vm_get_url_worker "${_links[@]}")
    [[ -z "$merged" || "$merged" == "[]" ]] && die_plugin "No playable links resolved for: $id"
    printf '%s\n' "$merged"
}

# Single-episode variant of _vm_episode_pairs: the pair for ONE episode.
_vm_episode_pair_for() {
    local ep_html="$1" want_ep="$2"
    _vm_episode_pairs "$ep_html" | awk -F'|' -v want="$want_ep" '$1 == want {print $2; exit}'
}

# Merge episode pairs across MULTIPLE episode-links pages (2026-08 redesign).
# A season now ships SEVERAL episode-links pages — one per host family
# (G-Direct → fastdl.zip, V-Cloud → vcloud.fit, ...). The G-Direct/fastdl
# links are frequently dead ("File is Deleted"), while V-Cloud/vcloud.fit
# resolve. Walk the season's nexdrive links, fetch each page that carries
# "Episodes: N:-" labels (capped so we don't fetch all 20+ links), and merge
# per-episode preferring vcloud.fit > fastdl.zip > dgdrive.pro. Emits the same
# "N|url" lines as _vm_episode_pairs.
_vm_episode_pairs_merged() {
    local links="$1"
    local max_pages="${2:-4}"
    local link ep_html allpairs="" pages=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (( pages >= max_pages )) && break
        ep_html=$(curl "${_VM_CURL[@]}" -H "Referer: ${_VM_BASE}/" "$link" 2>/dev/null || true)
        [[ -z "$ep_html" ]] && continue
        # here-string, not a printf pipe (SIGPIPE under pipefail).
        grep -qE 'Episodes[: ]*[0-9]+' <<< "$ep_html" || continue
        pages=$((pages + 1))
        local p
        p=$(_vm_episode_pairs "$ep_html")
        [[ -n "$p" ]] && allpairs+="$p"$'\n'
    done <<< "$links"
    printf '%s' "$allpairs" | python3 -c '
import sys
pref = [("vcloud.fit", 0), ("fastdl.zip", 1), ("dgdrive.pro", 2)]
best = {}
for line in sys.stdin:
    line = line.strip()
    if not line or "|" not in line:
        continue
    n, url = line.split("|", 1)
    rank = 99
    for fam, r in pref:
        if fam in url:
            rank = r
            break
    if n not in best or rank < best[n][0]:
        best[n] = (rank, url)
for n in sorted(best, key=lambda x: int(x)):
    print("%s|%s" % (n, best[n][1]))
' 2>/dev/null || true
}

plugin_list_seasons() {
    local series_id="$1"
    _load_vm_config
    _vm_load_domains

    local html
    html=$(curl "${_VM_CURL[@]}" "${_VM_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # Season-pack post: "Season N" headings → one season entry each.
    # NOTE: jq needs -s here — without it every sort line is a separate
    # input and the output collapses to an empty/partial array.
    local seasons_json="[]"
    seasons_json=$(printf '%s' "$html" | grep -oE 'Season [0-9]+' | grep -oE '[0-9]+' | sort -un | jq -sc 'map({id: (.|tostring), title: ("Season " + (.|tostring)), number: .})' 2>/dev/null || true)
    if [[ -z "$seasons_json" || "$seasons_json" == "[]" ]]; then
        seasons_json='[{"id":"1","title":"Season 1","number":1}]'
    fi
    printf '%s\n' "$seasons_json"
}

plugin_list_episodes() {
    local series_id="$1"
    local season_number="${2:-1}"
    _load_vm_config
    _vm_load_domains

    # Season-pack posts group their nexdrive resolver links under per-season
    # headings ("Season 1" / "Season 2" ...). One of the links is the
    # "Episode Links" page: it lists the REAL episodes as labeled
    # "Episodes: NN:-" entries pointing to GDToT (dgdrive.pro) hosts.
    # Two-level walk: season block → episode-links page → per-episode links.
    local html
    html=$(curl "${_VM_CURL[@]}" "${_VM_BASE}/${series_id}/" 2>/dev/null) || return 1
    if [[ -z "$html" ]]; then
        sleep 1
        html=$(curl "${_VM_CURL[@]}" "${_VM_BASE}/${series_id}/" 2>/dev/null) || return 1
    fi
    [[ -z "$html" ]] && return 1

    # 2026-08 redesign: series posts are HUB pages (season headings + Download
    # Now buttons, no nexdrive links). Follow the requested season's button to
    # its dedicated page where the resolver links live.
    if _vm_is_hub_page "$html"; then
        local season_path
        season_path=$(_vm_hub_season_url "$html" "$season_number")
        if [[ -n "$season_path" ]]; then
            local season_html
            season_html=$(curl "${_VM_CURL[@]}" -H "Referer: ${_VM_BASE}/${series_id}/" "${_VM_BASE}${season_path}" 2>/dev/null || true)
            [[ -n "$season_html" ]] && html="$season_html"
        fi
    fi

    # 1) find the nexdrive link for this season (position-walk as in get_url).
    #    Fall back to every link on the page (dedicated season pages hold one
    #    season's links, so the position-walk finds nothing).
    local season_links
    season_links=$(_vm_season_links "$html" "$season_number")
    [[ -z "$season_links" ]] && season_links=$(_vm_all_nexdrive_links "$html")
    if [[ -z "$season_links" ]]; then
        # Bundle post with no direct per-season links (S1-5 packs etc.):
        # emit a single pack entry so the title stays listable/playable
        # instead of dying with "No season links".
        printf '[{"id":"%s:%s:1","title":"Season %s pack","number":1,"episode":1,"season":%s}]\n' \
            "$series_id" "$season_number" "$season_number" "$season_number"
        return 0
    fi

    # 2) find the "Episode Links" pages among this season's links and merge
    #    per-episode across host families (2026-08 redesign: one page per
    #    family — G-Direct/fastdl.zip is often dead, V-Cloud/vcloud.fit works).
    #    Prefers vcloud.fit > fastdl.zip > dgdrive.pro per episode.
    local episode_pairs
    episode_pairs=$(_vm_episode_pairs_merged "$season_links")

    if [[ -z "$episode_pairs" ]]; then
        # fallback: no episode-links page yet (fresh season) — one pack entry
        printf '[{"id":"%s:%s:1","title":"Season %s pack","number":1,"episode":1,"season":%s}]\n' \
            "$series_id" "$season_number" "$season_number" "$season_number"
        return 0
    fi

    # 3) emit one episode entry per labeled episode (id is the dgdrive link);
    #    batched: build JSONL first, one jq pass merges (was one fork per ep)
    local lines="" n link
    while IFS='|' read -r n link; do
        [[ -z "$n" || -z "$link" ]] && continue
        lines+="$(jq -nc --arg id "${series_id}:${season_number}:${n}" \
            --arg title "Episode $n" --argjson ep "$n" --argjson se "$season_number" \
            --arg url "$link" \
            '{"id": $id, "title": $title, "episode": $ep, "season": $se, "url": $url}')"$'\n'
    done <<< "$episode_pairs"
    if [[ -n "$lines" ]]; then
        jq -s '.' <<< "$lines"
    else
        printf '[]'
    fi
}

plugin_health() {
    _load_vm_config
    _vm_load_domains
    local code
    code=$(curl -s --connect-timeout 8 --max-time 15 -A "$_VM_UA" -o /dev/null -w '%{http_code}' "${_VM_BASE}/" 2>/dev/null || echo 000)
    [[ "$code" == "200" || "$code" == "301" || "$code" == "302" ]]
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}\n' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
