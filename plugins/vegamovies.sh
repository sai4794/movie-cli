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

    # Direct links on the page already? (r2/gpdl2 present without token hop).
    # Exclude signup.php — that's a decoy ad page, not a stream.
    local direct
    direct=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' <>]*' | grep -E 'r2\.cloudflarestorage|gpdl[0-9]*\.hubcloud|/video/' | grep -v 'signup\.php' | sort -u 2>/dev/null || true)
    if [[ -n "$direct" ]]; then
        printf '%s\n' "$direct"
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
    first = base64.b64decode(s)
    second = base64.b64decode(first)
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

    printf '%s' "$tok_page" | grep -oE 'https?://[^"'"'"' <>]*' | grep -E 'r2\.cloudflarestorage|gpdl[0-9]*\.hubcloud|/video/|\.mkv|\.mp4' | sort -u 2>/dev/null || true
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
            *vcloud.zip*|*fastdl.zip*)
                (
                    _vm_resolve_vcloud "$link"
                ) > "$tmp_dir/out_${idx}.txt" &
                pids+=($!)
                ;;
            *gpdl*.hubcloud.cx*)
                # pixel-class redirector → follow to the real link
                (
                    local final
                    final=$(curl -sL --connect-timeout 6 --max-time 10 -A "$_VM_UA" -o /dev/null -w '%{url_effective}' "$link" 2>/dev/null || true)
                    [[ -n "$final" ]] && printf '%s\n' "$final"
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
            title: .post_title,
            type: (if (.post_title | test("Season [0-9]|Series|TV"; "i")) then "series" else "movie" end),
            year: (if (.post_title | test("\\((19|20)[0-9]{2}\\)")) then (.post_title | capture("\\((?<year>(19|20)[0-9]{2})\\)").year) else null end),
            rating: null,
            poster: .post_thumbnail
        }]
    ' 2>/dev/null
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

    # nexdrive resolver links — the download buttons on the page
    local nx_links
    nx_links=$(printf '%s' "$html" | grep -oE 'href="https://nexdrive\.fit/genxfm[0-9]+/"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    [[ -z "$nx_links" ]] && die_plugin "No resolver links on VegaMovies page for: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local streams=""
            streams=$(_vm_resolve_nexdrive "$link" 2>/dev/null || true)
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

    # Season-pack post: "Season N" headings → one season entry each
    local seasons_json="[]"
    seasons_json=$(printf '%s' "$html" | grep -oE 'Season [0-9]+' | grep -oE '[0-9]+' | sort -un | jq -c '[.[] | {id: (.|tostring), title: ("Season " + (.|tostring)), number: .}]' 2>/dev/null || true)
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

    # Season-pack posts bundle all episodes into the same resolver links;
    # expose one "episode" entry per season pack (matches CSX behavior of
    # one EpisodeLink per season/quality block).
    local ep_num="${season_number:-1}"
    printf '[{"id":"%s:%s:1","title":"Season %s pack","number":1,"episode":1,"season":%s}]\n' \
        "$series_id" "$season_number" "$season_number" "$season_number"
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
