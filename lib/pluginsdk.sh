#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# pluginsdk.sh — Shared runtime for movie-cli source plugins (API v5)
#
# Every scrape plugin used to carry private copies of the same machinery:
# config parsing, domain rotation, stream-candidate filtering, quality
# detection, stream JSON building, and the hubcloud resolver chain, plus a
# hand-rolled parallel fan-out in plugin_get_url. Those copies drifted
# (five User-Agents, two quality vocabularies, four Cinemeta fallbacks).
# This module is the single implementation; plugins keep only their
# site-specific data (URLs, host lists) and pass it in.
#
# Source this at the top of a plugin (it is idempotent):
#     [[ -f "${LIB_DIR:-}/pluginsdk.sh" ]] && source "${LIB_DIR}/pluginsdk.sh"
#
# Conventions:
#   * Functions never die_* — failures are signaled by empty output /
#     non-zero return so the host decides process fate.
#   * All network helpers honor pipefail: pipelines are guarded with
#     `|| true` / fallbacks instead of disabling shell options.
# ═══════════════════════════════════════════════════════════════

[[ -n "${_PLUGIN_SDK_LOADED:-}" ]] && return 0
_PLUGIN_SDK_LOADED=1

# Glob-match helper shared by candidate filtering and resolver walks.
# Top-level (NOT nested in sdk_is_stream_candidate): sdk_resolve_resolver
# calls it directly, and a nested definition only exists after the first
# candidate call — the resolver ran first and logged "command not found".
# shellcheck disable=SC2053  # intentional: unquoted RHS = glob match
match_glob() { [[ -n "$1" && "$2" == $1 ]]; }

# ───────────────────────────────────────────────────────────────
# Config file loading (key=value parser shared with lib/config.sh)
# ───────────────────────────────────────────────────────────────

# sdk_conf_load FILE PREFIX KEY...
#   Parses a flat key=value conf file into ${PREFIX}_${KEY} variables.
#   Only whitelisted KEYs are accepted; others warn and are skipped.
#   Special case: BASE_URL also sets ${PREFIX}_USER_SET=1 — the flag every
#   plugin uses to pin its domain against auto-rotation.
sdk_conf_load() {
    local conf_file="$1"
    local prefix="$2"
    shift 2

    [[ -f "$conf_file" ]] || return 0

    local line key value uname allowed
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        key="${line%%=*}"
        value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        # Strip one layer of surrounding quotes
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"

        [[ -z "$key" ]] && continue

        # Whitelist check
        local valid=0
        for allowed in "$@"; do
            [[ "$key" == "$allowed" ]] && { valid=1; break; }
        done
        if (( ! valid )); then
            warn "Unknown config key: $key (in $conf_file)"
            continue
        fi

        printf -v "${prefix}_${key}" '%s' "$value"
        [[ "$key" == "BASE_URL" ]] && printf -v "${prefix}_USER_SET" '%s' "1"
    done < "$conf_file"
}

# ───────────────────────────────────────────────────────────────
# HTTP helper
# ───────────────────────────────────────────────────────────────

# sdk_http UA [REFERER] [MAX_TIME]
#   Builds _SDK_CURL — the standard curl flag array shared by all SDK
#   resolvers. Call once per invocation after config/domain rotation;
#   re-run whenever the base URL or referer changes.
sdk_http() {
    local ua="$1"
    local referer="${2:-}"
    local max_time="${3:-25}"
    _SDK_CURL=(-sL --connect-timeout 8 --max-time "$max_time" -A "$ua")
    [[ -n "$referer" ]] && _SDK_CURL+=(-H "Referer: $referer")
}

# sdk_fetch URL [REFERER] — body on stdout, empty on failure. Never dies.
sdk_fetch() {
    local url="$1"
    local referer="${2:-}"
    local -a extra=()
    [[ -n "$referer" ]] && extra=(-H "Referer: $referer")
    curl "${_SDK_CURL[@]}" "${extra[@]}" "$url" 2>/dev/null || true
}

# ───────────────────────────────────────────────────────────────
# Domain rotation (CloudStream-extension style)
# ───────────────────────────────────────────────────────────────

# sdk_rotate_domain CACHE_KEY LIST_URL JSON_KEY CURRENT_BASE NAME UA
#   Fetches the shared live-domain list (24h cache), extracts the JSON_KEY
#   entry, strips trailing slash/space, and prints it. Prints nothing when
#   unavailable; the caller compares against CURRENT_BASE, logs the
#   rotation, and applies it.
sdk_rotate_domain() {
    local cache_key="$1"
    local list_url="$2"
    local json_key="$3"
    local current_base="$4"
    local name="$5"
    local ua="$6"

    local cached=""
    if declare -f cache_get >/dev/null 2>&1; then
        cached=$(cache_get "$cache_key" 86400 2>/dev/null || true)
    fi
    if [[ -z "$cached" ]]; then
        cached=$(curl -s --connect-timeout 6 --max-time 15 -A "$ua" "$list_url" 2>/dev/null || true)
        if [[ -n "$cached" ]] && printf '%s' "$cached" | jq -e . >/dev/null 2>&1; then
            if declare -f cache_set >/dev/null 2>&1; then
                cache_set "$cache_key" "$cached" || true
            fi
        else
            cached=""
        fi
    fi
    [[ -z "$cached" ]] && return 0

    local dom
    dom=$(printf '%s' "$cached" | jq -r --arg k "$json_key" '.[$k] // empty' 2>/dev/null || true)
    [[ -z "$dom" || "$dom" == "null" ]] && return 0
    dom="${dom%/}"
    dom="${dom## }"
    [[ -z "$dom" ]] && return 0
    # Validate: this third-party list silently re-bases every request — a
    # compromised entry (userinfo/@, non-https, path) must not apply.
    [[ "$dom" =~ ^https://[A-Za-z0-9.-]+$ ]] || { debug "$name: rejecting malformed domain: $dom"; return 0; }

    if [[ "$dom" != "$current_base" ]]; then
        debug "$name domain rotated: $current_base → $dom"
    fi
    printf '%s\n' "$dom"
}

# ───────────────────────────────────────────────────────────────
# URL quoting
# ───────────────────────────────────────────────────────────────

# Percent-encode a URL for curl/mpv consumption. Brackets/spaces/plus must be
# encoded — curl globbing breaks on raw [] (rc=3). Safe chars keep URL
# structure intact. Falls back to the raw input when python3 is missing.
sdk_url_quote() {
    printf '%s' "$1" | python3 -c '
import sys, urllib.parse
print(urllib.parse.quote(sys.stdin.read().strip(), safe=":/?&=%,.+-_()~"))
' 2>/dev/null || printf '%s' "$1"
}

# Inverse for dl.php?link= payloads.
sdk_url_unquote() {
    python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))' 2>/dev/null
}

# ───────────────────────────────────────────────────────────────
# Stream candidate policy
# ───────────────────────────────────────────────────────────────

# sdk_is_stream_candidate LINK ALLOW_HOSTS REJECT_GLOBS FAMILY_GLOBS
#   LINK           URL to test
#   ALLOW_HOSTS    comma-separated user substrings (conf); match → accept
#   REJECT_GLOBS   |-separated lowercase globs (ads/shorteners/telegram)
#   FAMILY_GLOBS   |-separated known file-host globs
#   Stages run in fixed order: rejects → allowlist → families → media
#   extension heuristic (identical across every plugin).
sdk_is_stream_candidate() {
    local link="$1"
    local allow_hosts="$2"
    local reject_globs="$3"
    local family_globs="$4"

    local lower
    lower=$(printf '%s' "$link" | tr '[:upper:]' '[:lower:]')

    local glob
    local -a _SDK_GLOBS=()
    IFS='|' read -r -a _SDK_GLOBS <<< "$reject_globs"
    for glob in "${_SDK_GLOBS[@]}"; do
        match_glob "$glob" "$lower" && return 1
    done

    if [[ -n "$allow_hosts" ]]; then
        local host allow
        host=$(printf '%s' "$lower" | sed -E 's|^https?://([^/]+).*|\1|')
        local -a allow_arr=()
        IFS=',' read -r -a allow_arr <<< "$allow_hosts"
        for allow in "${allow_arr[@]}"; do
            allow="${allow,,}"
            [[ -n "$allow" && "$host" == *"$allow"* ]] && return 0
        done
    fi

    IFS='|' read -r -a _SDK_GLOBS <<< "$family_globs"
    for glob in "${_SDK_GLOBS[@]}"; do
        match_glob "$glob" "$lower" && return 0
    done

    # Direct media URL heuristic — video extension anywhere in the URL
    case "$lower" in
        *.mkv*|*.mp4*|*.webm*|*.m3u8*|*.flv*|*.mov*|*.avi*|*.ts*) return 0 ;;
    esac

    return 1
}

# ───────────────────────────────────────────────────────────────
# Quality detection
# ───────────────────────────────────────────────────────────────
# Two output vocabularies exist in the wild (sort_streams ranks both), so
# both flavors are provided. Do NOT unify outputs without a migration plan:
# quality strings surface verbatim in stream-selection labels.

# Substring flavor — vegamovies / dudefilms ("2160p", "1080p", ...)
sdk_quality_suffix() {
    local lower
    lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        *2160p*|*4k*) echo "2160p" ;;
        *1080p*)      echo "1080p" ;;
        *720p*)       echo "720p" ;;
        *480p*)       echo "480p" ;;
        *)            echo "auto" ;;
    esac
}

# Token flavor — hdhub4u / 4khdhub ("4K", "1440", "1080", ...).
# 4K must be a standalone token — "DS4K"/"S4K" release tags must NOT match.
sdk_quality_token() {
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

# ───────────────────────────────────────────────────────────────
# Stream JSON building
# ───────────────────────────────────────────────────────────────

# sdk_stream_json PROVIDER QUALITY URL [REFERER]
#   URL is emitted verbatim.
sdk_stream_json() {
    local provider="$1" quality="$2" url="$3" referer="${4:-}"
    if [[ -n "$referer" ]]; then
        jq -nc --arg u "$url" --arg q "$quality" --arg r "$referer" --arg p2 "$provider" \
            '{quality: $q, url: $u, size: "unknown", provider: $p2, referer: $r}'
    else
        jq -nc --arg u "$url" --arg q "$quality" --arg p2 "$provider" \
            '{quality: $q, url: $u, size: "unknown", provider: $p2}'
    fi
}

# sdk_stream_json_encoded PROVIDER QUALITY URL [REFERER]
#   Same, but percent-encodes the URL first (resolver pages emit raw
#   spaces/brackets in filenames).
sdk_stream_json_encoded() {
    local provider="$1" quality="$2" url="$3" referer="${4:-}"
    url=$(sdk_url_quote "$url")
    sdk_stream_json "$provider" "$quality" "$url" "$referer"
}

# ───────────────────────────────────────────────────────────────
# HubCloud resolver chain (shared by movies4u/hdhub4u/4khdhub/dudefilms)
# ───────────────────────────────────────────────────────────────

# pixeldrain page URL → direct API form (/api/file/ID?download)
sdk_normalize_pixeldrain() {
    local link="$1"
    if [[ "$link" == *"/api/file/"* || "$link" == *"download"* ]]; then
        printf '%s\n' "$link"
        return
    fi
    local pd_base pd_id
    pd_base=$(printf '%s' "$link" | sed -E 's|^(https?://[^/]+).*|\1|')
    pd_id="${link##*/}"
    printf '%s\n' "${pd_base}/api/file/${pd_id}?download"
}

# pixel.hubcloud.cx/?id=... / gpdl.* redirector → real download link.
# The dl.php page JS sets downloadBtn.href = link param; final URL = link param.
sdk_resolve_pixel() {
    local pixel_url="$1"
    local page dl_url final url_eff tmpbody
    tmpbody=$(mktemp)
    page=$(curl "${_SDK_CURL[@]}" -o "$tmpbody" -w '%{url_effective}' "$pixel_url" 2>/dev/null || true)
    url_eff="$page"
    page=$(cat "$tmpbody" 2>/dev/null || true)
    rm -f "$tmpbody"
    dl_url=$(printf '%s' "$page" | grep -oE 'https?://[^"'"'"' ]*dl\.php\?link=[^"'"'"' ]+' | head -1 2>/dev/null || true)
    if [[ -z "$dl_url" && "$url_eff" == *"dl.php?link="* ]]; then
        dl_url="$url_eff"
    fi
    [[ -z "$dl_url" ]] && return 1
    final=$(printf '%s' "$dl_url" | sed -E 's/.*link=//' | sdk_url_unquote || true)
    [[ -z "$final" ]] && return 1
    printf '%s\n' "$final"
}

# sdk_resolve_resolver URL CANDIDATE_FN BTN_ONLY PIXEL_GLOBS [REFERER]
#   Resolver page (e.g. gamerxyt.com/hubcloud.php) → direct stream URLs.
#   BTN_ONLY=1 keeps only class="btn" anchors; BTN_ONLY=0 keeps all anchors.
#   CANDIDATE_FN is the plugin's sdk_is_stream_candidate wrapper.
#   PIXEL_GLOBS are |-separated globs routed to the pixel/gpdl redirector
#   resolver — sites differ (movies4u routes any *gpdl*; hubdrive-family
#   plugins only *gpdl.hubcloud.cx*) so the exact list is caller data.
sdk_resolve_resolver() {
    local resolver_url="$1"
    local candidate_fn="$2"
    local btn_only="${3:-1}"
    local pixel_globs="${4:-*pixel.hubcloud.cx*|*gpdl.hubcloud.cx*}"
    local referer="${5:-}"

    local page grep_pat
    page=$(sdk_fetch "$resolver_url" "$referer")
    [[ -z "$page" ]] && return 1

    if [[ "$btn_only" == "1" ]]; then
        grep_pat='<a[^>]*href="https?://[^"]+"[^>]*class="[^"]*btn[^"]*"'
    else
        grep_pat='<a[^>]*href="https?://[^"]+"'
    fi

    printf '%s' "$page" | grep -oE "$grep_pat" | \
        sed -E 's/.*href="([^"]+)".*/\1/' | sort -u | while IFS= read -r link; do
        [[ -z "$link" ]] && continue
        local glob matched=0
        IFS='|' read -r -a _SDK_PGLOBS <<< "$pixel_globs"
        for glob in "${_SDK_PGLOBS[@]}"; do
            match_glob "$glob" "$link" && { matched=1; break; }
        done
        if (( matched )); then
            sdk_resolve_pixel "$link"
            continue
        fi
        case "$link" in
            *pixeldrain*)
                sdk_normalize_pixeldrain "$link"
                ;;
            *)
                if "$candidate_fn" "$link"; then
                    printf '%s\n' "$link"
                fi
                ;;
        esac
    done
}

# sdk_resolve_drive URL CANDIDATE_FN BTN_ONLY PIXEL_GLOBS [REFERER]
#   hubcloud.*/drive/ID page → id="download" href → resolver → direct links.
#   hubcloud.php links are used directly as the resolver URL.
sdk_resolve_drive() {
    local drive_url="$1"
    local candidate_fn="$2"
    local btn_only="${3:-1}"
    local pixel_globs="$4"
    local referer="${5:-}"

    local page href base
    page=$(sdk_fetch "$drive_url" "$referer")
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

    sdk_resolve_resolver "$href" "$candidate_fn" "$btn_only" "$pixel_globs" "$referer"
}

# ───────────────────────────────────────────────────────────────
# Parallel fan-out skeleton
# ───────────────────────────────────────────────────────────────

# sdk_fanout WORKER_FN ITEM...
#   Runs WORKER_FN once per item in a background subshell, capturing each
#   worker's stdout as line-delimited JSON objects in out_N files, waits for
#   all of them, merges everything into ONE JSON array on stdout.
#   Merge filter defaults to identity ('.'); override via SDK_FANOUT_MERGE
#   (e.g. 'unique_by(.url)'). Workers inherit the caller's globals.
sdk_fanout() {
    local worker_fn="$1"
    shift
    (( $# == 0 )) && { printf '[]'; return 0; }

    local tmp_dir
    tmp_dir=$(mktemp -d)
    local pids=() idx=0 item
    for item in "$@"; do
        [[ -z "$item" ]] && { idx=$((idx + 1)); continue; }
        (
            "$worker_fn" "$item" 2>/dev/null || true
        ) > "$tmp_dir/out_${idx}.json" &
        pids+=($!)
        idx=$((idx + 1))
    done
    wait "${pids[@]}" 2>/dev/null || true

    local merged=""
    if compgen -G "$tmp_dir/out_*.json" > /dev/null 2>&1; then
        merged=$(cat "$tmp_dir"/out_*.json 2>/dev/null | jq -s "${SDK_FANOUT_MERGE:-.}" 2>/dev/null) || merged=""
    fi
    rm -rf "$tmp_dir"
    # Always return a valid JSON array (empty workers → "[]")
    [[ -z "$merged" || "$merged" == "null" ]] && merged="[]"
    printf '%s\n' "$merged"
}
