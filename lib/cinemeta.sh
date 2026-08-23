#!/usr/bin/env bash
# lib/cinemeta.sh — Cinemeta query helpers for plugin search fallbacks
# Sourced by plugins that need Cinemeta title resolution.
# Source order: lib/init.sh → lib/errors.sh → lib/cinemeta.sh → plugin

[[ -n "${_CINEMETA_LOADED:-}" ]] && return 0
_CINEMETA_LOADED=1

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

# ═══════════════════════════════════════════════════════════════
# Shared sparse-search fallback orchestrator.
#
# When a plugin's own search returns fewer than 2 results, query Cinemeta
# for canonical titles and let the plugin re-search its site per title.
# Previously every WP-scrape plugin hand-rolled this loop; they now pass a
# research callback instead:
#
#   RESEARCH_FN <title> <year> <type>
#     → prints JSON (objects and/or arrays, line-delimited) of extra hits
#
# Prints EXISTING_JSON untouched when it already has >= 2 results, when
# Cinemeta is unreachable, or when research yields nothing. Merges with
# existing results first-in-first-kept (unique_by(.id)).
# Hardened against pipefail — callers do NOT need `set +euo pipefail`.
# ═══════════════════════════════════════════════════════════════
cinemeta_search_fallback() {
    local query="$1"
    local existing="$2"
    local research_fn="$3"

    local count
    count=$(printf '%s' "$existing" | jq 'length' 2>/dev/null || echo 0)
    if (( count >= 2 )); then
        printf '%s' "$existing"
        return 0
    fi

    local cm_all
    cm_all=$(cinemeta_top_results "$query" 3 2>/dev/null || true)
    if [[ -z "$cm_all" || "$cm_all" == "[]" || "$cm_all" == "null" ]]; then
        printf '%s' "$existing"
        return 0
    fi

    # One jq pass extracts all metadata rows (was three forks per row).
    local rows name year type
    rows=$(printf '%s' "$cm_all" | jq -r '
        .[] | [(.name // ""), (.releaseInfo // ""), (.type // "movie")] | @tsv
    ' 2>/dev/null || true)

    local tmp
    tmp=$(mktemp)
    while IFS=$'\t' read -r name year type; do
        [[ -z "$name" ]] && continue
        "$research_fn" "$name" "$year" "$type" >> "$tmp" 2>/dev/null || true
    done <<< "$rows"

    if [[ -s "$tmp" ]]; then
        printf '%s\n%s' "$existing" "$(jq -s '.' "$tmp" 2>/dev/null)" \
            | jq -s 'flatten | unique_by(.id)' 2>/dev/null \
            || printf '%s' "$existing"
    else
        printf '%s' "$existing"
    fi
    rm -f "$tmp"
}
