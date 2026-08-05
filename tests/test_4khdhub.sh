#!/usr/bin/env bats
# test_4khdhub.sh — Tests for the 4KHDHub plugin

setup() {
    load 'bats-support/load'
    load 'bats-assert/load'

    PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BATS_TEST_TMPDIR="$(mktemp -d)"
    export HOME="$BATS_TEST_TMPDIR"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/.config"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/.cache"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/.local/share"

    mkdir -p "$XDG_CONFIG_HOME/movie-cli"
    mkdir -p "$XDG_CACHE_HOME/movie-cli"
    mkdir -p "$XDG_DATA_HOME/movie-cli"

    export DEBUG=0
    export VERBOSE=0
    export QUIET=1

    source "$PROJECT_DIR/lib/init.sh"
    source "$PROJECT_DIR/lib/errors.sh"
    source "$PROJECT_DIR/plugins/4khdhub.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "4KHDHub metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "4KHDHub" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[0]}" == "movie" ]]
    [[ "${PLUGIN_TYPES[1]}" == "series" ]]
}

@test "4KHDHub info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"4KHDHub","version":"1.0.0","types":["movie","series"]}'
}

@test "4KHDHub search returns valid JSON array of results" {
    run plugin_search "inception"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]

    local first
    first=$(printf '%s' "$output" | jq -c '.[0]')
    printf '%s' "$first" | jq -e '.id and .title and .type' >/dev/null
}

@test "4KHDHub get_url returns playable stream candidates for a movie" {
    # Use a known stable title from search
    local id
    id=$(plugin_search "inception" | jq -r '.[0].id' 2>/dev/null)
    [[ -n "$id" && "$id" != "null" ]] || skip "search returned no id"

    run plugin_get_url "$id"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]

    # Schema check
    printf '%s' "$output" | jq -e '.[0].url and .[0].quality' >/dev/null
    # All URLs must be http(s)
    printf '%s' "$output" | jq -e 'all(.[]; .url | startswith("http"))' >/dev/null
}

@test "4KHDHub series seasons are extracted" {
    run plugin_list_seasons "breaking-bad-series-1385"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]
    printf '%s' "$output" | jq -e '.[0].id and .[0].title and .[0].number' >/dev/null
}

@test "4KHDHub series episodes are extracted per season" {
    run plugin_list_episodes "breaking-bad-series-1385" "5"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]
    # Episode id convention: series_id:season:episode
    printf '%s' "$output" | jq -e '.[0].id | test("^breaking-bad-series-1385:5:[0-9]+$")' >/dev/null
}

@test "4KHDHub health succeeds" {
    run plugin_health
    assert_success
}
