#!/usr/bin/env bats
# test_hdhub4u.sh — Tests for the HDhub4u plugin

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
    source "$PROJECT_DIR/plugins/hdhub4u.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "HDhub4u metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "HDhub4u" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[0]}" == "movie" ]]
    [[ "${PLUGIN_TYPES[1]}" == "series" ]]
}

@test "HDhub4u info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"HDhub4u","version":"1.0.0","types":["movie","series"]}'
}

@test "HDhub4u search returns valid JSON array of results" {
    run plugin_search "inception"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]

    local first
    first=$(printf '%s' "$output" | jq -c '.[0]')
    printf '%s' "$first" | jq -e '.id and .title and .type' >/dev/null
}

@test "HDhub4u get_url returns playable stream candidates for a movie" {
    local id
    id=$(plugin_search "inception" | jq -r '.[0].id' 2>/dev/null)
    [[ -n "$id" && "$id" != "null" ]] || skip "search returned no id"

    run plugin_get_url "$id"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]

    printf '%s' "$output" | jq -e '.[0].url and .[0].quality' >/dev/null
    printf '%s' "$output" | jq -e 'all(.[]; .url | startswith("http"))' >/dev/null
}

@test "HDhub4u health succeeds" {
    run plugin_health
    assert_success
}

@test "HDhub4u series seasons are extracted" {
    run plugin_list_seasons "all-of-us-are-dead-s01-hindi-webrip-all-episodes"
    assert_success
    printf '%s' "$output" | jq -e '.[0].id and .[0].title and .[0].number' >/dev/null
}

@test "HDhub4u series episodes are extracted per season" {
    run plugin_list_episodes "all-of-us-are-dead-s01-hindi-webrip-all-episodes" "1"
    assert_success

    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]
    # Episode id convention: series_id:season:episode
    printf '%s' "$output" | jq -e '.[0].id | test("^all-of-us-are-dead-s01-hindi-webrip-all-episodes:1:[0-9]+$")' >/dev/null
}
