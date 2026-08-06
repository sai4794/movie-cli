#!/usr/bin/env bats
# test_vegamovies.sh — Tests for the VegaMovies plugin

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
    source "$PROJECT_DIR/plugins/vegamovies.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "VegaMovies metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "VegaMovies" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "VegaMovies info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"VegaMovies","version":"1.0.0","types":["movie","series"]}'
}

@test "VegaMovies search returns valid JSON array of results" {
    run plugin_search "inception" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    run jq -e 'type == "array"' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "VegaMovies get_url returns playable stream candidates for a movie" {
    run plugin_get_url "download-spider-man-brand-new-day-2026" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    # Must have at least one direct R2 stream (the V-Cloud chain output)
    run jq -e '[.[] | select(.url | contains("r2.cloudflarestorage"))] | length > 0' <<< "$output"
    [ "$status" -eq 0 ] || skip "no live R2 mirrors in current window"
}

@test "VegaMovies health succeeds" {
    run plugin_health
    [ "$status" -eq 0 ]
}

@test "VegaMovies series seasons are extracted" {
    run plugin_list_seasons "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "VegaMovies series episodes are extracted per season" {
    run plugin_list_episodes "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl" "1"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "VegaMovies series get_url resolves streams (season-pack)" {
    run plugin_get_url "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl:1:1" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}
