#!/usr/bin/env bash
# 4khdhub.sh — 4KHDHub plugin for movie-cli
# Movies + series from 4khdhub.one (via hubcloud/hubdrive mirror chain)
# Reverse-engineered from the CloudStream FourKHDHub extension (phisher98 repo)
# Resolution chain: site detail page → hubcloud.ist/drive/ID or hubdrive.tips/file/ID
#   → resolver page (gamerxyt.com/hubcloud.php) → direct .mkv (workers.dev / fsl-buckets)
#   or pixel.hubcloud.cx → dl.php?link=video-downloads.googleusercontent.com

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

_load_4kh_config() {
    local conf_file="$CONF_DIR/4khdhub.conf"
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
            BASE_URL) _4KH_BASE="$value" ;;
        esac
    done < "$conf_file"
}

# ═══════════════════════════════════════════════════════════════
# Resolver walk: hubcloud drive page → resolver page → direct links
# ═══════════════════════════════════════════════════════════════

# Resolve one hubcloud.*/drive/ID page into candidate stream URLs
# (one per line on stdout). Follows HubCloud.kt logic:
#   drive page → #download href → resolver page → btn links
_4kh_resolve_drive() {
    local drive_url="$1"
    local page href base

    page=$(curl "${_4KH_CURL[@]}" "$drive_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    # hubcloud.php links are used directly; otherwise extract #download href
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

    _4kh_resolve_resolver "$href"
}

# Resolve a resolver page (e.g. gamerxyt.com/hubcloud.php?host=...&id=...&token=...)
# into direct stream URLs. Live page structure (2026-08-05):
#   <a href="https://cdn.fsl-buckets.work/....mkv?token=..." class="btn btn-success btn-lg h6">
#   <a href="https://patient-....workers.dev/.../....mkv" class="btn btn-success btn-lg h6">
#   <a href="https://pixel.hubcloud.cx/?id=..." class="btn btn-danger btn-lg h6">
_4kh_resolve_resolver() {
    local resolver_url="$1"
    local page

    page=$(curl "${_4KH_CURL[@]}" "$resolver_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    # All download buttons: a.btn links
    printf '%s' "$page" | grep -oE '<a[^>]*href="https?://[^"]+"[^>]*class="[^"]*btn[^"]*"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        case "$link" in
            *pixel.hubcloud.cx*)
                # pixel → 302 → pixel.*.workers.dev → dl.php?link=googleusercontent
                _4kh_resolve_pixel "$link"
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
                # telegram / ad / navigation links — skip
                ;;
        esac
    done
}

# pixel.hubcloud.cx/?id=... → 302 → pixel.*.workers.dev → page w/ dl.php?link=...
# The dl.php page JS sets downloadBtn.href = link param; final URL = link param.
_4kh_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final

    page=$(curl "${_4KH_CURL[@]}" "$pixel_url" 2>/dev/null) || return 1
    # The page references dl.php?link=<googleusercontent-url>
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' ]*dl\.php\?link=[^"'"'"' ]+' | head -1 2>/dev/null || true)
    [[ -z "$dl_url" ]] && return 1
    final=$(printf '%s' "$dl_url" | sed -E 's/.*link=//' | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || true)
    [[ -z "$final" ]] && return 1
    printf '%s\n' "$final"
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

# Quality from filename: 2160p/4K → 4K, 1080p → 1080, etc.
# 4K must be a standalone token — "DS4K"/"S4K" release tags must NOT match
_4kh_quality() {
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

# Build stream JSON object from a URL
# Percent-encode the URL: resolver pages emit raw spaces/brackets in filenames
# which curl's globbing chokes on (rc=3). Safe chars keep URL structure intact.
_4kh_stream_json() {
    local url="$1"
    local enc qual
    enc=$(printf '%s' "$url" | python3 -c '
import sys, urllib.parse
# brackets/spaces/plus must be encoded — curl globbing breaks on raw [] and rc=3
print(urllib.parse.quote(sys.stdin.read().strip(), safe=":/?&=%,.+-_()~"))
' 2>/dev/null || printf '%s' "$url")
    qual=$(_4kh_quality "$url")
    jq -nc --arg u "$enc" --arg q "$qual" '{quality: $q, url: $u, size: "unknown", provider: "4khdhub"}'
}

# ═══════════════════════════════════════════════════════════════
# Plugin Functions
# ═══════════════════════════════════════════════════════════════

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_4kh_config

    local encoded_query
    encoded_query=$(urlencode "$query")

    local html
    html=$(curl "${_4KH_CURL[@]}" "${_4KH_BASE}/?s=${encoded_query}" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # Parse movie cards: <a href="/slug/" class="movie-card" ...> ... <div class="movie-card-title">TITLE</div>
    printf '%s' "$html" | python3 -c '
import sys, re, json
html = sys.stdin.read()
out = []
for m in re.finditer(r"<a href=\"(/[^\"]+)\"[^>]*class=\"movie-card\"[^>]*>(.*?)</a>", html, re.S):
    slug, inner = m.group(1), m.group(2)
    title_m = re.search(r"movie-card-title[^>]*>([^<]+)", inner)
    if not title_m:
        continue
    title = title_m.group(1).strip()
    typ = "series" if "-series-" in slug else "movie"
    out.append({"id": slug.strip("/"), "title": title, "type": typ})
print(json.dumps(out))
' 2>/dev/null
}

plugin_get_url() {
    local id="$1"
    local quality="${2:-720}"
    _load_4kh_config

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
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local streams=""
            streams=$(_4kh_resolve_link "$link" 2>/dev/null || true)
            if [[ -n "$streams" ]]; then
                printf '%s\n' "$streams" | while IFS= read -r su; do
                    [[ -z "$su" ]] && continue
                    _4kh_stream_json "$su"
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
    _load_4kh_config

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
    curl -s --connect-timeout 8 --max-time 15 -o /dev/null -w '%{http_code}' \
        -A "$_4KH_UA" "${_4KH_BASE}/?s=test" 2>/dev/null | grep -qE '^200$'
}

plugin_info() {
    printf '{"name":"%s","version":"%s","types":["movie","series"]}' \
        "$PLUGIN_NAME" "$PLUGIN_VERSION"
}
