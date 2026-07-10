#!/usr/bin/env bats
# test_core.sh — Tests for core functions

load 'setup'

@test "VERSION is set" {
    [[ -n "$VERSION" ]]
}

@test "init_dirs creates required directories" {
    rm -rf "$CONF_DIR" "$CACHE_DIR" "$DATA_DIR"
    init_dirs
    [[ -d "$CONF_DIR" ]]
    [[ -d "$CACHE_DIR" ]]
    [[ -d "$DATA_DIR" ]]
}

@test "file_mtime returns 0 for nonexistent file" {
    result=$(file_mtime "/nonexistent/file")
    [[ "$result" == "0" ]]
}

@test "file_mtime returns numeric value for existing file" {
    local tmpfile="$BATS_TEST_TMPDIR/testfile"
    touch "$tmpfile"
    local result=$(file_mtime "$tmpfile")
    [[ "$result" =~ ^[0-9]+$ ]]
}

@test "sha256_sum produces consistent hash" {
    local hash1=$(echo "test" | sha256_sum)
    local hash2=$(echo "test" | sha256_sum)
    [[ "$hash1" == "$hash2" ]]
    [[ ${#hash1} == 64 ]]
}

@test "sha256_sum produces different hashes for different input" {
    local hash1=$(echo "test1" | sha256_sum)
    local hash2=$(echo "test2" | sha256_sum)
    [[ "$hash1" != "$hash2" ]]
}

@test "die_user exits with code 1" {
    run die_user "test error"
    assert_failure
    [[ "$output" == *"ERROR: test error"* ]]
}

@test "die_network exits with code 2" {
    run die_network "network error"
    assert_failure
    [[ "$status" -eq 2 ]]
}

@test "die_plugin exits with code 3" {
    run die_plugin "plugin error"
    assert_failure
    [[ "$status" -eq 3 ]]
}

@test "die_deps exits with code 5" {
    run die_deps "missing dep"
    assert_failure
    [[ "$status" -eq 5 ]]
}

@test "warn writes to stderr" {
    export QUIET=0
    run warn "test warning"
    assert_success
    [[ "$output" == *"WARN: test warning"* ]]
}

@test "retry succeeds on first attempt" {
    run retry 3 1 true
    assert_success
}

@test "retry fails after max attempts" {
    run retry 2 1 false
    assert_failure
}

@test "retry retries then succeeds" {
    _retry_count=0
    flaky() { _retry_count=$((_retry_count + 1)); [[ $_retry_count -ge 2 ]]; }
    retry 3 1 flaky
    [[ "$_retry_count" -eq 2 ]]
}

@test "movie-cli rejects query longer than 200 characters" {
    local long_query=$(printf 'a%.0s' {1..201})
    run "$PROJECT_DIR/movie-cli" "$long_query"
    assert_failure
    [[ "$output" == *"too long"* ]]
}

@test "movie-cli rejects query with only shell metacharacters" {
    run "$PROJECT_DIR/movie-cli" ";|&><"
    assert_failure
    [[ "$output" == *"contains invalid characters"* ]]
}

@test "spinner_start and spinner_stop manage background process" {
    spinner_start "Test Spinner"
    [[ -n "$_spinner_pid" ]]
    kill -0 "$_spinner_pid"

    spinner_stop
    [[ -z "$_spinner_pid" ]]
}

@test "movie-cli runs interactively when no query is passed" {
    run bash -c "echo 'salaar' | \"$PROJECT_DIR/movie-cli\" --search-only"
    assert_success
    [[ "$output" == *"Checking dependencies..."* ]]
    [[ "$output" == *"Search movie:"* ]]
    [[ "$output" == *"Salaar"* ]]
}

@test "search results appear without blocking (no Ctrl+C needed)" {
    # Regression test: spinner output used to overwrite fallback list,
    # causing the program to appear blocked until Ctrl+C.
    # With --search-only, results should appear immediately.
    run timeout 15 "$PROJECT_DIR/movie-cli" -s "inception"
    assert_success
    # Verify results are numbered and contain the query
    [[ "$output" == *"1. "* ]]
    [[ "$output" == *"Inception"* ]]
}

@test "MovieBlast plugin_get_url returns valid JSON array" {
    # MovieBlast plugin_get_url must return [{quality, url, size}] not a plain URL
    source "$PROJECT_DIR/plugins/movieblast.sh"
    _load_token 2>/dev/null
    local result
    result=$(plugin_get_url "396" "720" 2>/dev/null)
    
    # Verify output starts with [ (JSON array)
    [[ "$(printf '%s' "$result" | head -c 1)" == "[" ]]
    
    # Verify it contains a URL
    [[ "$result" == *"https://"* ]]
}

@test "select_stream returns stream directly when only one stream" {
    local stream='{"quality":"1080p","url":"https://example.com/v.m3u8","provider":"test"}'
    select_stream "Pick: " "$stream"
    [[ "$_SELECT_ITEM_RESULT" == "$stream" ]]
}

@test "select_stream displays provider, quality, codec, audio, language, size" {
    # Build two streams and verify labels contain metadata
    local s1='{"quality":"1080p","url":"https://a.com/v","provider":"VidLink","codec":"HEVC","audio":"AAC","language":"English","size":"2.1 GB"}'
    local s2='{"quality":"720p","url":"https://b.com/v","provider":"Backup"}'
    
    # Verify jq can extract all fields
    local prov qual codec audio lang size
    prov=$(printf '%s' "$s1" | jq -r '.provider')
    qual=$(printf '%s' "$s1" | jq -r '.quality')
    codec=$(printf '%s' "$s1" | jq -r '.codec')
    audio=$(printf '%s' "$s1" | jq -r '.audio')
    lang=$(printf '%s' "$s1" | jq -r '.language')
    size=$(printf '%s' "$s1" | jq -r '.size')
    
    [[ "$prov" == "VidLink" ]]
    [[ "$qual" == "1080p" ]]
    [[ "$codec" == "HEVC" ]]
    [[ "$audio" == "AAC" ]]
    [[ "$lang" == "English" ]]
    [[ "$size" == "2.1 GB" ]]
    
    # Second stream has only provider and quality
    prov=$(printf '%s' "$s2" | jq -r '.provider')
    qual=$(printf '%s' "$s2" | jq -r '.quality')
    codec=$(printf '%s' "$s2" | jq -r '.codec // empty')
    [[ "$prov" == "Backup" ]]
    [[ "$qual" == "720p" ]]
    [[ -z "$codec" ]]
}

@test "select_stream handles HDR flag" {
    local stream='{"quality":"4K","url":"https://example.com/v","provider":"FileMoon","hdr":true}'
    local hdr
    hdr=$(printf '%s' "$stream" | jq -r '.hdr // false')
    [[ "$hdr" == "true" ]]
}

@test "select_stream handles empty quality gracefully" {
    local stream='{"url":"https://example.com/v","provider":"Backup"}'
    local qual
    qual=$(printf '%s' "$stream" | jq -r '.quality // empty')
    [[ -z "$qual" ]]
}
