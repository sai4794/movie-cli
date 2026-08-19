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

_load_vm_config() {
    local conf_file="$CONF_DIR/vegamovies.conf"
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
            BASE_URL) _VM_BASE="$value"; _VM_BASE_USER_SET=1 ;;
            ALLOW_HOSTS) _VM_ALLOW_HOSTS="$value" ;;
        esac
    done < "$conf_file"
}

# Auto domain rotation (CSX-style): fetch the live URL list once a day
_vm_load_domains() {
    [[ "$_VM_BASE_USER_SET" == "1" ]] && return 0

    local cached=""
    if declare -f cache_get >/dev/null 2>&1; then
        cached=$(cache_get "$_VM_DOMAINS_CACHE_KEY" 86400 2>/dev/null || true)
    fi
    if [[ -z "$cached" ]]; then
        cached=$(curl -s --connect-timeout 6 --max-time 15 -A "$_VM_UA" "$_VM_DOMAINS_URL" 2>/dev/null || true)
        if [[ -n "$cached" ]] && printf '%s' "$cached" | jq -e . >/dev/null 2>&1; then
            if declare -f cache_set >/dev/null 2>&1; then
                cache_set "$_VM_DOMAINS_CACHE_KEY" "$cached" || true
            fi
        else
            cached=""
        fi
    fi
    [[ -z "$cached" ]] && return 0

    local dom
    dom=$(printf '%s' "$cached" | jq -r '.["vegamovies"] // empty' 2>/dev/null || true)
    [[ -z "$dom" || "$dom" == "null" ]] && return 0
    dom="${dom%/}"
    if [[ "$dom" != "$_VM_BASE" ]]; then
        debug "VegaMovies domain rotated: $_VM_BASE → $dom"
        _VM_BASE="$dom"
    fi
}

# Fuzzy host matching — same policy as 4khdhub/hdhub4u: match broadly,
# let verify_streams filter garbage. VegaMovies resolver pages emit
# vcloud/gpdl2/r2/gofile/filebee/megaup/transfer/vikingfile links.
_vm_is_stream_candidate() {
    local link="$1"
    local lower
    lower=$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')

    # Hard rejects — ad/navigation/shortener links
    case "$lower" in
        *snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me/*|*googlesyndication*|*doubleclick*|*bit\.ly*|*cutt\.ly*|*nexdrive*|*wp-content*|*gmpg*|*xmlrpc*|*vegamovies-apk*|*gokuhd*|*rogmovies*)
            return 1 ;;
    esac

    # User-configured host allowlist wins
    if [[ -n "$_VM_ALLOW_HOSTS" ]]; then
        local host allow
        host=$(printf '%s' "$lower" | sed -E 's|^https?://([^/]+).*|\1|')
        local -a allow_arr=()
        IFS=',' read -r -a allow_arr <<< "$_VM_ALLOW_HOSTS"
        for allow in "${allow_arr[@]}"; do
            allow="${allow,,}"
            [[ -n "$allow" && "$host" == *"$allow"* ]] && return 0
        done
    fi

    # Known file-host families
    case "$lower" in
        *vcloud*|*hubcloud*|*hubdrive*|*r2.cloudflarestorage*|*gpdl*|*pixeldrain*|*gofile*|*filebee*|*megaup*|*transfer\.it*|*vikingfile*|*fastdl*|*fsl*|*workers.dev*|*googleusercontent*)
            return 0 ;;
    esac

    # Direct media URL heuristic
    case "$lower" in
        *.mkv*|*.mp4*|*.webm*|*.m3u8*|*.flv*|*.mov*|*.avi*|*.ts*)
            return 0 ;;
    esac

    return 1
}

_vm_quality() {
    local url="$1"
    local lower
    lower=$(printf '%s' "$url" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *2160p*|*4k*) echo "2160p" ;;
        *1080p*) echo "1080p" ;;
        *720p*) echo "720p" ;;
        *480p*) echo "480p" ;;
        *) echo "auto" ;;
    esac
}

_vm_stream_json() {
    local url="$1"
    local enc qual
    enc=$(printf '%s' "$url" | python3 -c '
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read().strip(), safe=":/?&=%,.+-_()~"))
' 2>/dev/null || printf '%s' "$url")
    qual=$(_vm_quality "$url")
    jq -nc --arg u "$enc" --arg q "$qual" '{quality: $q, url: $u, size: "unknown", provider: "vegamovies"}'
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
    while IFS= read -r l; do
        [[ -n "$l" ]] && links+=("$l")
    done < <(printf '%s' "$page" | grep -oE 'href="https?://[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u)

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

    # nexdrive resolver links — the download buttons on the page.
    # For series episodes "series:season:episode", use the EPISODE's own
    # link (the dgdrive URL from the episode-links page) instead of the
    # season's batch links — resolving the batch gives the whole-season
    # zip, not the requested episode.
    local nx_links
    if [[ -n "$season" && -n "$episode" ]]; then
        # fetch the episode-links page for this season, find episode N's url
        local season_links
        season_links=$(printf '%s' "$html" | python3 -c '
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
' "$season" 2>/dev/null || true)
        # find that episode's OWN playable link on the episode-links page.
        # The page lists FIVE host families per episode (vcloud.fit,
        # fastdl.zip, filebee, gdtot, dgdrive) — prefer vcloud/fastdl like
        # CloudStream does (dgdrive is the ad-gated one).
        local link ep_html found=""
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            ep_html=$(curl "${_VM_CURL[@]}" -H "Referer: ${_VM_BASE}/${series_id}/" "$link" 2>/dev/null || true)
            [[ -z "$ep_html" ]] && continue
            # NOTE: here-string (<<<), not a printf pipe — grep -q exits on the
            # first match and a large page makes printf hit SIGPIPE (141) →
            # pipefail → the check flips to false intermittently.
            if grep -qE 'Episodes[: ]*[0-9]+' <<< "$ep_html"; then
                found=$(printf '%s' "$ep_html" | python3 -c '
import sys, re
html = sys.stdin.read()
want = int(sys.argv[1])
labels = [(m.start(), int(m.group(1))) for m in re.finditer(r"Episodes:\s*([0-9]+)\s*:-", html)]
# prefer vcloud.fit then fastdl.zip then dgdrive (ad-gated) as last resort
families = [r"https://vcloud\.fit/[^\"]+", r"https://fastdl\.zip/[^\"]+", r"https://dgdrive\.pro/[^\"]+"]
for lpos, n in labels:
    if n == want:
        for fam in families:
            links = [(m.start(), m.group(1)) for m in re.finditer(r"href=\"(" + fam + r")\"", html)]
            nxt = next((l for p2, l in links if p2 > lpos), None)
            if nxt:
                print(nxt)
                break
        break
' "$episode" 2>/dev/null || true)
                [[ -n "$found" ]] && break
            fi
        done <<< "$season_links"
        if [[ -n "$found" ]]; then
            nx_links="$found"
        else
            # episode page missing — fall back to the season's links
            nx_links=$(printf '%s' "$html" | python3 -c '
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
' "$season" 2>/dev/null || true)
        fi
    elif [[ -n "$season" ]]; then
        nx_links=$(printf '%s' "$html" | python3 -c '
import sys, re
html = sys.stdin.read()
want = int(sys.argv[1])
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
    elif cur == str(want):
        out.append(val)
print("\n".join(dict.fromkeys(out)))
' "$season" 2>/dev/null || true)
    else
        nx_links=$(printf '%s' "$html" | grep -oE 'href="https://nexdrive\.fit/genxfm[0-9]+/"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    fi
    [[ -z "$nx_links" ]] && die_plugin "No resolver links on VegaMovies page for: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local streams=""
            # Direct vcloud-family links (from the episode lookup) go
            # straight to the VCloud resolver (double-atob + button menu).
            # Other links are nexdrive resolver pages.
            case "$link" in
                *vcloud.fit*|*vcloud.zip*|*fastdl.zip*|*vcloud.org*)
                    streams=$(_vm_resolve_vcloud "$link" 2>/dev/null || true)
                    ;;
                *)
                    streams=$(_vm_resolve_nexdrive "$link" 2>/dev/null || true)
                    ;;
            esac
            if [[ -n "$streams" ]]; then
                printf '%s\n' "$streams" | while IFS= read -r su; do
                    [[ -z "$su" ]] && continue
                    [[ "${su,,}" == *sample* ]] && continue
                    _vm_stream_json "$su"
                done > "$tmp_dir/out_${idx}.json"
            fi
        ) &
        pids+=($!)
        idx=$((idx + 1))
    done <<< "$nx_links"

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

    # 1) find the nexdrive link for this season (position-walk as in get_url)
    local season_links
    season_links=$(printf '%s' "$html" | python3 -c '
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
' "$season_number" 2>/dev/null || true)
    [[ -z "$season_links" ]] && die_plugin "No season links for season $season_number"

    # 2) find the "Episode Links" page among this season's links (its page
    #    has per-episode labels); fetch it and extract labeled episodes.
    #    The episode-links page is flaky — retry once before giving up.
    local link ep_html
    local episode_pairs=""
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        ep_html=$(curl "${_VM_CURL[@]}" -H "Referer: ${_VM_BASE}/${series_id}/" "$link" 2>/dev/null || true)
        if [[ -z "$ep_html" ]] || ! grep -qE 'Episodes[: ]*[0-9]+' <<< "$ep_html"; then
            sleep 1
            ep_html=$(curl "${_VM_CURL[@]}" -H "Referer: ${_VM_BASE}/${series_id}/" "$link" 2>/dev/null || true)
        fi
        [[ -z "$ep_html" ]] && continue
        if grep -qE 'Episodes[: ]*[0-9]+' <<< "$ep_html"; then
            episode_pairs=$(printf '%s' "$ep_html" | python3 -c '
import sys, re
html = sys.stdin.read()
labels = [(m.start(), int(m.group(1))) for m in re.finditer(r"Episodes:\s*([0-9]+)\s*:-", html)]
# five host families per episode; prefer vcloud.fit then fastdl.zip then
# dgdrive (ad-gated, last resort) — matches CloudStream (p > a vcloud)
families = [r"https://vcloud\.fit/[^\"]+", r"https://fastdl\.zip/[^\"]+", r"https://dgdrive\.pro/[^\"]+"]
alllinks = {}
for fam in families:
    alllinks[fam] = [(m.start(), m.group(1)) for m in re.finditer(r"href=\"(" + fam + r")\"", html)]
pairs = []
for lpos, n in labels:
    for fam in families:
        nxt = next((l for p2, l in alllinks[fam] if p2 > lpos), None)
        if nxt:
            pairs.append((n, nxt))
            break
for n, l in sorted(set(pairs)):
    print("%d|%s" % (n, l))
' 2>/dev/null || true)
            [[ -n "$episode_pairs" ]] && break
        fi
    done <<< "$season_links"

    if [[ -z "$episode_pairs" ]]; then
        # fallback: no episode-links page yet (fresh season) — one pack entry
        printf '[{"id":"%s:%s:1","title":"Season %s pack","number":1,"episode":1,"season":%s}]\n' \
            "$series_id" "$season_number" "$season_number" "$season_number"
        return 0
    fi

    # 3) emit one episode entry per labeled episode (id is the dgdrive link)
    local json="[]"
    while IFS='|' read -r n link; do
        [[ -z "$n" || -z "$link" ]] && continue
        json=$(printf '%s' "$json" | jq -c --arg id "${series_id}:${season_number}:${n}" \
            --arg title "Episode $n" --argjson ep "$n" --argjson se "$season_number" \
            --arg url "$link" '. + [{"id": $id, "title": $title, "episode": $ep, "season": $se, "url": $url}]')
    done <<< "$episode_pairs"
    printf '%s\n' "$json"
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
