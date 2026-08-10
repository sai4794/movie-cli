#!/usr/bin/env bash
# lib/cinemeta.sh — Cinemeta query helpers for plugin search fallbacks
# Sourced by plugins that need Cinemeta title resolution.
# Source order: lib/init.sh → lib/errors.sh → lib/cinemeta.sh → plugin

# Query Cinemeta movie + series catalogs for a search term.
# Returns top N results as a JSON array: [{name, releaseInfo, type}, ...]
# Usage: cinemeta_top_results "query" [max]
cinemeta_top_results() {
    local query="$1"
    local max="${2:-3}"
    local cm_movie cm_series
    cm_movie=$(curl -s --connect-timeout 6 --max-time 15 \
        "https://v3-cinemeta.strem.io/catalog/movie/top/search=$(urlencode "$query").json" 2>/dev/null || true)
    cm_series=$(curl -s --connect-timeout 6 --max-time 15 \
        "https://v3-cinemeta.strem.io/catalog/series/top/search=$(urlencode "$query").json" 2>/dev/null || true)
    printf '%s\n%s' "$cm_movie" "$cm_series" | jq -s \
        "[.[]?.metas[]? | {name, releaseInfo, type}] | .[0:$max]" 2>/dev/null || echo "[]"
}

# Cinemeta fallback for WP-style ?s= search plugins.
# When existing results are sparse (<2), query Cinemeta and re-search
# the WP site by title+year. Returns merged JSON array.
# Args: $1=query, $2=existing results JSON, $3=CURL_ARRAY_NAME (e.g. _4KH_CURL),
#       $4=SITE_BASE_URL, $5=RESULT_PARSER_PYTHON (inline python snippet for parsing HTML)
cinemeta_wp_fallback() {
    set +euo pipefail
    local query="$1"
    local existing_json="$2"
    # $3-$5 are curl array name, base URL, and python parser — used inline below

    local count
    count=$(printf '%s' "$existing_json" | jq 'length' 2>/dev/null || echo 0)
    [[ "$count" -ge 2 ]] && printf '%s' "$existing_json" && return 0

    local cm_all
    cm_all=$(cinemeta_top_results "$query" 3)
    [[ -z "$cm_all" || "$cm_all" == "[]" || "$cm_all" == "null" ]] && printf '%s' "$existing_json" && return 0

    local cm_tmp cm_rows
    cm_tmp=$(mktemp)
    cm_rows=$(printf '%s' "$cm_all" | jq -c '.[]' 2>/dev/null || true)

    while IFS= read -r meta; do
        [[ -z "$meta" ]] && continue
        local cname cyear ctype
        cname=$(printf '%s' "$meta" | jq -r '.name // ""')
        cyear=$(printf '%s' "$meta" | jq -r '.releaseInfo // ""')
        ctype=$(printf '%s' "$meta" | jq -r '.type // "movie"')
        [[ -z "$cname" ]] && continue

        local site_html
        site_html=$(curl -sL --connect-timeout 8 --max-time 20 \
            -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36" \
            -G "${4}/" --data-urlencode "s=${cname} ${cyear}" 2>/dev/null || true)
        [[ -z "$site_html" ]] && continue

        printf '%s' "$site_html" | python3 -c "$5" "$cname" "$cyear" "$ctype" 2>/dev/null | \
            while IFS= read -r j; do
                [[ -n "$j" ]] && printf '%s\n' "$j" >> "$cm_tmp"
            done
    done <<< "$cm_rows"

    local cm_merged
    if [[ -s "$cm_tmp" ]]; then
        cm_merged=$(printf '%s\n%s' "$existing_json" "$(jq -s '.' "$cm_tmp" 2>/dev/null)" \
            | jq -s 'flatten | unique_by(.id)' 2>/dev/null \
            || printf '%s' "$existing_json")
    else
        cm_merged="$existing_json"
    fi
    rm -f "$cm_tmp"
    printf '%s' "$cm_merged"
}

# Reusable WP article parser (used by 4khdhub, dudefilms, movies4u fallbacks)
# Parses <a href="URL">TITLE</a> from HTML, cleans title, extracts slug/type/year.
cinemeta_wp_parse() {
    python3 -c "
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
"
}
