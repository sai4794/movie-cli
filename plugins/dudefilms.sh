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

_load_df_config() {
    local conf_file="$CONF_DIR/dudefilms.conf"
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
            BASE_URL) _DF_BASE="$value"; _DF_BASE_USER_SET=1 ;;
            ALLOW_HOSTS) _DF_ALLOW_HOSTS="$value" ;;
        esac
    done < "$conf_file"
}

# Auto domain rotation: fetch the live domain list once a day
_df_load_domains() {
    [[ "$_DF_BASE_USER_SET" == "1" ]] && return 0

    local cached=""
    if declare -f cache_get >/dev/null 2>&1; then
        cached=$(cache_get "$_DF_DOMAINS_CACHE_KEY" 86400 2>/dev/null || true)
    fi
    if [[ -z "$cached" ]]; then
        cached=$(curl -s --connect-timeout 6 --max-time 15 -A "$_DF_UA" "$_DF_DOMAINS_URL" 2>/dev/null || true)
        if [[ -n "$cached" ]] && printf '%s' "$cached" | jq -e . >/dev/null 2>&1; then
            if declare -f cache_set >/dev/null 2>&1; then
                cache_set "$_DF_DOMAINS_CACHE_KEY" "$cached" || true
            fi
        else
            cached=""
        fi
    fi
    [[ -z "$cached" ]] && return 0

    local dom
    dom=$(printf '%s' "$cached" | jq -r '.["dudefilms"] // empty' 2>/dev/null || true)
    [[ -z "$dom" || "$dom" == "null" ]] && return 0
    dom="${dom%/}"
    if [[ "$dom" != "$_DF_BASE" ]]; then
        debug "DudeFilms domain rotated: $_DF_BASE → $dom"
        _DF_BASE="$dom"
    fi
}

# ═══════════════════════════════════════════════════════════════
# HubCloud drive chain (identical to hdhub4u/4khdhub resolvers)
# ═══════════════════════════════════════════════════════════════

# Fuzzy host matching — same policy as hdhub4u: match broadly,
# let verify_streams filter garbage.
_df_is_stream_candidate() {
    local link="$1"
    local lower
    lower=$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')

    # Hard rejects — these are never streams
    case "$lower" in
        *tg/go*|*snvhost*|*one.one.one.one*|*google.com/search*|*tinyurl*|*t.me*|*hubcloud.cx/drive*|*googlesyndication*|*winexch*|*effectivecpm*|*profitableratecpm*|*a-ads*|*khelostar*)
            return 1 ;;
    esac

    # User-configured host allowlist wins
    if [[ -n "$_DF_ALLOW_HOSTS" ]]; then
        local host allow
        host=$(printf '%s' "$lower" | sed -E 's|^https?://([^/]+).*|\1|')
        local -a allow_arr=()
        IFS=',' read -r -a allow_arr <<< "$_DF_ALLOW_HOSTS"
        for allow in "${allow_arr[@]}"; do
            allow="${allow,,}"
            [[ -n "$allow" && "$host" == *"$allow"* ]] && return 0
        done
    fi

    # Known file-host families (substring match = fuzzy across rotated hosts)
    case "$lower" in
        *workers.dev*|*r2.cloudflarestorage*|*pixeldrain*|*fsl*|*filescdn*|*aiplex*|*hubcloud*|*hubdrive*|*googleusercontent*|*gdlink*|*filepress*|*gofile*|*d0000d*|*drop.download*|*dood*|*driveapp*|*gdtot*)
            return 0 ;;
    esac

    # Direct media URL heuristic
    case "$lower" in
        *.mkv*|*.mp4*|*.webm*|*.m3u8*|*.flv*|*.mov*|*.avi*|*.ts*)
            return 0 ;;
    esac

    return 1
}

_df_quality() {
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

_df_stream_json() {
    local url="$1"
    local enc qual
    enc=$(printf '%s' "$url" | python3 -c '
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read().strip(), safe=":/?&=%,.+-_()~"))
' 2>/dev/null || printf '%s' "$url")
    qual=$(_df_quality "$url")
    jq -nc --arg u "$enc" --arg q "$qual" '{quality: $q, url: $u, size: "unknown", provider: "dudefilms"}'
}

# hubcloud.*/drive/ID → #download href → resolver page → direct links
_df_resolve_drive() {
    local drive_url="$1"
    local page href base

    page=$(curl "${_DF_CURL[@]}" "$drive_url" 2>/dev/null) || return 1
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

    _df_resolve_resolver "$href"
}

# Resolver page (gamerxyt.com/hubcloud.php) → btn links → direct streams
_df_resolve_resolver() {
    local resolver_url="$1"
    local page

    page=$(curl "${_DF_CURL[@]}" "$resolver_url" 2>/dev/null) || return 1
    [[ -z "$page" ]] && return 1

    printf '%s' "$page" | grep -oE '<a[^>]*href="https?://[^"]+"[^>]*class="[^"]*btn[^"]*"' | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        case "$link" in
            *pixel.hubcloud.cx*|*gpdl.hubcloud.cx*)
                _df_resolve_pixel "$link"
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
                if _df_is_stream_candidate "$link"; then
                    printf '%s\n' "$link"
                fi
                ;;
        esac
    done
}

# pixel/gpdl redirector → real link (double-atob / dl.php?link= extraction)
_df_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final url_eff

    page=$(curl "${_DF_CURL[@]}" -o /tmp/df_pixel_body.$$ -w '%{url_effective}' "$pixel_url" 2>/dev/null || true)
    url_eff="$page"
    page=$(cat /tmp/df_pixel_body.$$ 2>/dev/null || true)
    rm -f /tmp/df_pixel_body.$$
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' ]*dl\.php\?link=[^"'"'"' ]+' | head -1 2>/dev/null || true)
    if [[ -z "$dl_url" && "$url_eff" == *"dl.php?link="* ]]; then
        dl_url="$url_eff"
    fi
    [[ -z "$dl_url" ]] && return 1
    final=$(printf '%s' "$dl_url" | sed -E 's/.*link=//' | python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null || true)
    [[ -z "$final" ]] && return 1
    printf '%s\n' "$final"
}

# Any hubcloud-family link → drive chain
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

    # Archive hop can be flaky — retry once before giving up
    page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$arch_url" 2>/dev/null || true)
    if [[ -z "$page" ]]; then
        sleep 1
        page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$arch_url" 2>/dev/null || true)
    fi
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

    # Archive hop can be flaky — retry once
    page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$arch_url" 2>/dev/null || true)
    if [[ -z "$page" ]]; then
        sleep 1
        page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$arch_url" 2>/dev/null || true)
    fi
    [[ -z "$page" ]] && return 1

    # Extract the anchor for the wanted episode number (zero-padded label)
    local target
    target=$(printf '%02d' "$want_ep" 2>/dev/null || printf '%s' "$want_ep")
    local ep_url
    ep_url=$(printf '%s' "$page" | grep -oE "<a[^>]*class=\"[^\"]*maxbutton-ep[^\"]*\"[^>]*href=\"[^\"]+\"[^>]*><span[^>]*>Episode[[:space:]]*${target}[[:space:]]*</span>" | head -1 | grep -oE 'href="[^"]+"' | sed -E 's/.*href="([^"]+)".*/\1/' 2>/dev/null || true)
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

plugin_search() {
    local query="$1"
    local quality="${2:-720}"
    _load_df_config
    _df_load_domains

    local html
    html=$(curl "${_DF_CURL[@]}" -G "${_DF_BASE}/" --data-urlencode "s=$query" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    # WordPress search results: article links + titles.
    # Relevance filter: WordPress falls back to the recent-posts grid when a
    # query matches nothing (e.g. "kgf" vs dotted titles "K.G.F") — those
    # unrelated rows must not surface in the CLI. Keep only results whose
    # normalized title shares a significant token with the normalized query.
    printf '%s' "$html" | python3 -c '
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
    # relevance: any significant query token present in the normalized title,
    # or the full normalized query as a substring
    if qnorm and qnorm in tnorm:
        pass
    elif not any(t in tnorm for t in qtokens):
        continue
    slug = url.rstrip("/").rsplit("/", 1)[-1]
    tvtype = "series" if re.search(r"season|series|s\d{2}|e\d{2}", title, re.I) else "movie"
    year = ""
    ym = re.search(r"\((\d{4})\)|(19|20)\d{2}", title)
    if ym:
        year = ym.group(1) or ym.group(0)
    out.append({"id": slug, "title": title, "type": tvtype, "year": year, "rating": None, "poster": None})
# dedupe by id
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
links = re.findall(r"https://dflinks\.online/archives/\d+", page)
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
        arch_links=$(printf '%s' "$html" | grep -oE 'href="https?://dflinks\.online/archives/[0-9]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    fi
    [[ -z "$arch_links" ]] && die_plugin "No archive links on DudeFilms page for: $id"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0
    while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        (
            local streams=""
            if [[ -n "$episode" ]]; then
                # Per-episode: pick the Nth maxbutton-ep anchor from the archive
                streams=$(_df_resolve_archive_episode "$link" "$episode" 2>/dev/null || true)
            else
                streams=$(_df_resolve_archive "$link" 2>/dev/null || true)
            fi
            if [[ -n "$streams" ]]; then
                printf '%s\n' "$streams" | while IFS= read -r su; do
                    [[ -z "$su" ]] && continue
                    [[ "${su,,}" == *sample* ]] && continue
                    _df_stream_json "$su"
                done > "$tmp_dir/out_${idx}.json"
            fi
        ) &
        pids+=($!)
        idx=$((idx + 1))
    done <<< "$arch_links"

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
    _load_df_config
    _df_load_domains

    # Fetch the detail page → archive pages → count maxbutton-ep anchors
    # (each = one episode; e.g. HOTD S3 has "Episode 01".."Episode 07")
    local html arch_links ep_count
    html=$(curl "${_DF_CURL[@]}" "${_DF_BASE}/${series_id}/" 2>/dev/null) || return 1
    [[ -z "$html" ]] && return 1

    arch_links=$(printf '%s' "$html" | grep -oE 'href="https?://dflinks\.online/archives/[0-9]+"' | sed -E 's/.*href="([^"]+)".*/\1/' | sort -u 2>/dev/null || true)
    ep_count=0
    if [[ -n "$arch_links" ]]; then
        local first_arch
        first_arch=$(printf '%s\n' "$arch_links" | head -1)
        local arch_page
        arch_page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$first_arch" 2>/dev/null || true)
        if [[ -z "$arch_page" ]]; then
            sleep 1
            arch_page=$(curl "${_DF_CURL[@]}" -H "Referer: ${_DF_BASE}/" "$first_arch" 2>/dev/null || true)
        fi
        ep_count=$(printf '%s' "$arch_page" | grep -oE 'Episode[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | sort -un | tail -1 2>/dev/null || echo 0)
        [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count=$(printf '%s' "$arch_page" | grep -cE 'maxbutton-ep' 2>/dev/null || echo 0)
    fi
    [[ -z "$ep_count" || "$ep_count" == "0" ]] && ep_count="1"

    # Emit one episode entry per found episode (contract field is "episode")
    local i eps_json="[]"
    for (( i = 1; i <= ep_count; i++ )); do
        eps_json=$(printf '%s' "$eps_json" | jq -c --arg id "${series_id}:${season_number}:${i}" --arg t "Episode $i" --argjson n "$i" --argjson s "$season_number" \
            '. + [{"id": $id, "title": $t, "number": $n, "episode": $n, "season": $s}]' 2>/dev/null)
    done
    printf '%s\n' "$eps_json"
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
