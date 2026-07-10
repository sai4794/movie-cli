#!/usr/bin/env bash
# history.sh — Watch history tracking (JSONL format, append-only)
# Source AFTER init.sh

# ═══════════════════════════════════════════════════════════════
# History Schema (JSONL — one JSON object per line)
# ═══════════════════════════════════════════════════════════════
# {
#   "v": 1,                    # schema version
#   "title": "Inception",
#   "plugin": "movieblast",
#   "id": "875",
#   "type": "movie",           # "movie" or "series"
#   "ts": "2026-07-02T12:00:00+0530",
#   "season": null,
#   "episode": null,
#   "progress": 2712,          # seconds elapsed (integer)
#   "duration": 8880           # total seconds
# }

HISTORY_MAX_ENTRIES=500

# ═══════════════════════════════════════════════════════════════
# Add Entry (append-only)
# ═══════════════════════════════════════════════════════════════
history_add() {
    local title="$1"
    local plugin="$2"
    local id="$3"
    local type="${4:-movie}"
    local season="${5:-null}"
    local episode="${6:-null}"

    local ts
    ts=$(date_iso)

    # Use jq to safely construct JSON (prevents injection via quotes/backslashes)
    # -c flag produces compact (single-line) output
    local entry
    entry=$(jq -nc \
        --arg t "$title" \
        --arg p "$plugin" \
        --arg i "$id" \
        --arg ty "$type" \
        --arg ts "$ts" \
        --argjson s "$season" \
        --argjson e "$episode" \
        '{v:1, title:$t, plugin:$p, id:$i, type:$ty, ts:$ts, season:$s, episode:$e, progress:0, duration:0}')

    mkdir -p "$DATA_DIR"
    printf '%s\n' "$entry" >> "$HISTORY_FILE"
    debug "History added: $title"
}

# ═══════════════════════════════════════════════════════════════
# Update Progress (replace last matching entry)
# ═══════════════════════════════════════════════════════════════
history_update_progress() {
    local id="$1"
    local progress="$2"
    local duration="${3:-0}"

    [[ -f "$HISTORY_FILE" ]] || return 0

    TMPFILE=$(mktemp "${HISTORY_FILE}.XXXXXX")

    # Update only the LAST entry matching this id in JSONL array slurp
    jq -s -c --arg id "$id" --argjson prog "$progress" --argjson dur "$duration" '
        (map(.id == $id) | rindex(true)) as $idx |
        if $idx != null then
            .[$idx].progress = $prog | .[$idx].duration = $dur
        else
            .
        end |
        .[]
    ' "$HISTORY_FILE" > "$TMPFILE" 2>/dev/null || {
        rm -f "$TMPFILE"
        TMPFILE=""
        return 1
    }

    mv "$TMPFILE" "$HISTORY_FILE"
    TMPFILE=""
    debug "History updated: id=$id progress=$progress"
}

# ═══════════════════════════════════════════════════════════════
# Get Last Entry
# ═══════════════════════════════════════════════════════════════
history_get_last() {
    [[ -f "$HISTORY_FILE" ]] || return 1
    tail -1 "$HISTORY_FILE"
}

# ═══════════════════════════════════════════════════════════════
# List Recent Entries (last N, newest first)
# ═══════════════════════════════════════════════════════════════
history_list() {
    local limit="${1:-20}"
    [[ -f "$HISTORY_FILE" ]] || return 0
    tail -"$limit" "$HISTORY_FILE" | tac
}

# ═══════════════════════════════════════════════════════════════
# Delete Entry by Index (1-based, from most recent)
# ═══════════════════════════════════════════════════════════════
history_delete() {
    local index="$1"
    [[ -f "$HISTORY_FILE" ]] || return 0

    local total
    total=$(wc -l < "$HISTORY_FILE")
    (( index < 1 || index > total )) && return 1

    TMPFILE=$(mktemp "${HISTORY_FILE}.XXXXXX")

    # Delete by index (1-based, from most recent) using slurp array
    jq -s -c --argjson idx "$index" 'del(.[length - $idx]) | .[]' "$HISTORY_FILE" > "$TMPFILE" 2>/dev/null || {
        rm -f "$TMPFILE"
        TMPFILE=""
        return 1
    }

    mv "$TMPFILE" "$HISTORY_FILE"
    TMPFILE=""
    debug "History deleted entry #$index"
}

# ═══════════════════════════════════════════════════════════════
# Clear All History
# ═══════════════════════════════════════════════════════════════
history_clear() {
    : > "$HISTORY_FILE"
    debug "History cleared"
}

# ═══════════════════════════════════════════════════════════════
# Prune — keep only last N entries
# ═══════════════════════════════════════════════════════════════
history_prune() {
    local max="${1:-$HISTORY_MAX_ENTRIES}"
    [[ -f "$HISTORY_FILE" ]] || return 0

    local total
    total=$(grep -c '^{' "$HISTORY_FILE" 2>/dev/null) || true
    total="${total:-0}"
    (( total <= max )) && return 0

    # Extract only compact JSONL entries, keep last $max
    TMPFILE=$(mktemp "${HISTORY_FILE}.XXXXXX")
    grep '^{' "$HISTORY_FILE" | tail -n "$max" > "$TMPFILE"
    mv "$TMPFILE" "$HISTORY_FILE"
    TMPFILE=""
    debug "History pruned: $total → $max entries"
}

# ═══════════════════════════════════════════════════════════════
# Get History Count
# ═══════════════════════════════════════════════════════════════
history_count() {
    if [[ ! -f "$HISTORY_FILE" ]]; then
        echo 0
        return
    fi
    # Count compact JSONL entries (lines starting with {)
    local c
    c=$(grep -c '^{' "$HISTORY_FILE" 2>/dev/null) || true
    echo "${c:-0}"
}
