#!/usr/bin/env bash
# json.sh — Batch JSON extraction helpers (jq plumbing for the host)
# Source AFTER init.sh. Depends only on jq.
#
# Every helper here replaces the "one jq fork per field / per row / per item"
# pattern that was repeated across search_and_play() and the nav loops.
# One jq process extracts everything; bash splits the TSV output.

# ═══════════════════════════════════════════════════════════════
# Count elements of a JSON array. Never fails: invalid/empty input → 0.
# ═══════════════════════════════════════════════════════════════
json_count() {
    local json="$1"
    printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0
}

# ═══════════════════════════════════════════════════════════════
# Extract N fields from every element of a JSON array in ONE jq pass.
# Usage:   json_rows "$json" title id type plugin
# Output:  one TSV line per element, fields in the given order.
# Missing/null fields render as the literal string "null", matching what
# `jq -r '.[i].field'` printed before (callers treat both uniformly).
# ═══════════════════════════════════════════════════════════════
json_rows() {
    local json="$1"
    shift
    local fields="$*"
    printf '%s' "$json" | jq -r --arg fs "$fields" '
        .[] | [($fs | split(" "))[] as $f | (.[$f] // null | tostring)] | @tsv
    ' 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Emit compact JSON objects of an array, one per line.
# Replaces `done < <(printf '%s' "$json" | jq -c '.[]')` blocks.
# ═══════════════════════════════════════════════════════════════
json_objects() {
    local json="$1"
    printf '%s' "$json" | jq -c '.[]?' 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════
# Fill one bash array per field from a JSON array, in ONE pass.
# Usage:   json_fill_arrays "$results" R title id type plugin
# Sets:    R_TITLE[@] R_ID[@] R_TYPE[@] R_PLUGIN[@]  and  R_COUNT
# (array name = PREFIX + "_" + uppercase field name).
# Missing/null values arrive as the string "null" (see json_rows);
# callers apply their own defaults, same as the old per-field jq loops.
# ═══════════════════════════════════════════════════════════════
json_fill_arrays() {
    local json="$1"
    local prefix="$2"
    shift 2

    local field uname
    for field in "$@"; do
        uname="${field^^}"
        uname="${uname//-/_}"
        eval "${prefix}_${uname}=()"
    done
    printf -v "${prefix}_COUNT" '%s' "0"

    [[ -z "$json" || "$json" == "[]" ]] && return 0

    local n=0 field_value
    while IFS=$'\t' read -r "$@"; do
        for field in "$@"; do
            uname="${field^^}"
            uname="${uname//-/_}"
            field_value="${!field}"
            eval "${prefix}_${uname}+=(\"\${field_value}\")"
        done
        (( ++n ))
    done < <(json_rows "$json" "$@")
    printf -v "${prefix}_COUNT" '%s' "$n"
}
