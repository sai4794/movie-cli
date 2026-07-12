#!/usr/bin/env bash
# cache.sh — Caching layer with TTL and eviction
# Source AFTER init.sh

# ═══════════════════════════════════════════════════════════════
# Cache TTLs (seconds)
CACHE_TTL_SEARCH=3600      # 1 hour — search results

# Max cache entries before eviction
CACHE_MAX_ENTRIES=500

# ═══════════════════════════════════════════════════════════════
# Cache Key Generation (SHA256 of input)
# ═══════════════════════════════════════════════════════════════
cache_key() {
    printf '%s' "$1" | sha256_sum
}

# ═══════════════════════════════════════════════════════════════
# Cache Get — returns cached data or fails
# Args: $1=key, $2=ttl (optional, default: CACHE_TTL_SEARCH)
# ═══════════════════════════════════════════════════════════════
cache_get() {
    local key="$1"
    local ttl="${2:-$CACHE_TTL_SEARCH}"
    local key_file="$CACHE_DIR/$(cache_key "$key")"

    [[ -f "$key_file" ]] || return 1

    # Check age
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    local mtime
    mtime=$(file_mtime "$key_file")
    local age=$(( now - mtime ))

    if (( age >= ttl )); then
        debug "Cache expired: $key (${age}s old, ttl=${ttl}s)"
        rm -f "$key_file"
        return 1
    fi

    debug "Cache hit: $key (${age}s old)"
    cat "$key_file"
}

# ═══════════════════════════════════════════════════════════════
# Cache Evict — remove oldest entries if over max
cache_evict() {
    local count
    count=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    if (( count > CACHE_MAX_ENTRIES )); then
        local to_remove=$(( count - CACHE_MAX_ENTRIES ))
        debug "Cache eviction: $count entries, removing $to_remove oldest"
        # Portable: use stat + sort instead of find -printf (GNU-only)
        find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | \
            while IFS= read -r file; do
                mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null || echo 0)
                printf '%s %s\n' "$mtime" "$file"
            done | sort -n | head -n "$to_remove" | cut -d' ' -f2- | \
            xargs rm -f 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════
# Cache Set — store data with automatic TTL via mtime
# Args: $1=key, $2=data
# ═══════════════════════════════════════════════════════════════
cache_set() {
    local key="$1"
    local data="$2"
    local key_file="$CACHE_DIR/$(cache_key "$key")"

    mkdir -p "$CACHE_DIR"
    printf '%s' "$data" > "$key_file"
    debug "Cache set: $key (${#data} bytes)"

    # Evict oldest entries if over limit (runs every set, cheap check)
    cache_evict
}

# ═══════════════════════════════════════════════════════════════
# Cache Delete
# ═══════════════════════════════════════════════════════════════
cache_delete() {
    local key="$1"
    local key_file="$CACHE_DIR/$(cache_key "$key")"
    rm -f "$key_file" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Cache Clear All
# ═══════════════════════════════════════════════════════════════
cache_clear() {
    rm -rf "${CACHE_DIR:?}"/*
    mkdir -p "$CACHE_DIR"
}

# ═══════════════════════════════════════════════════════════════
# Cache Cleanup — remove files older than 7 days
# ═══════════════════════════════════════════════════════════════
cache_cleanup() {
    find "$CACHE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
}
