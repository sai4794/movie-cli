#!/usr/bin/env bats
# test_cache.sh — Tests for caching functions

load 'setup'

@test "cache_key produces consistent hash" {
    local key1=$(cache_key "test query")
    local key2=$(cache_key "test query")
    [[ "$key1" == "$key2" ]]
    [[ ${#key1} == 64 ]]
}

@test "cache_key produces different hashes for different input" {
    local key1=$(cache_key "query1")
    local key2=$(cache_key "query2")
    [[ "$key1" != "$key2" ]]
}

@test "cache_set and cache_get roundtrip" {
    cache_set "mykey" "myvalue"
    local result=$(cache_get "mykey")
    [[ "$result" == "myvalue" ]]
}

@test "cache_get returns failure for missing key" {
    run cache_get "nonexistent"
    assert_failure
}

@test "cache_get returns failure for expired entry" {
    cache_set "expiring" "data"
    # Manually set mtime to 2 hours ago
    local key_file="$CACHE_DIR/$(cache_key "expiring")"
    touch -d "2 hours ago" "$key_file"
    run cache_get "expiring" 3600
    assert_failure
}

@test "cache_delete removes entry" {
    cache_set "to_delete" "data"
    cache_delete "to_delete"
    run cache_get "to_delete"
    assert_failure
}

@test "cache_clear removes all entries" {
    cache_set "key1" "val1"
    cache_set "key2" "val2"
    cache_clear
    run cache_get "key1"
    assert_failure
    run cache_get "key2"
    assert_failure
}

@test "cache cleanup removes old files" {
    cache_set "old" "data"
    cache_set "new" "data"
    local old_file="$CACHE_DIR/$(cache_key "old")"
    touch -d "8 days ago" "$old_file"
    cache_cleanup
    run cache_get "old"
    assert_failure
    local result=$(cache_get "new")
    [[ "$result" == "data" ]]
}

@test "cache_evict removes oldest entries when over limit" {
    CACHE_MAX_ENTRIES=5
    for i in $(seq 1 8); do
        cache_set "evict_test_$i" "data_$i"
        sleep 0.1
    done
    local count
    count=$(find "$CACHE_DIR" -maxdepth 1 -type f 2>/dev/null | wc -l)
    [[ "$count" -le 5 ]]
    local result
    result=$(cache_get "evict_test_8")
    [[ "$result" == "data_8" ]]
}
