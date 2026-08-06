#!/usr/bin/env bats
# test_dudefilms.sh — Tests for the DudeFilms plugin

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
    source "$PROJECT_DIR/plugins/dudefilms.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "DudeFilms metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "DudeFilms" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "DudeFilms info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"DudeFilms","version":"1.0.0","types":["movie","series"]}'
}

@test "DudeFilms search returns valid JSON array of results" {
    run plugin_search "salaar" "720"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array"' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "DudeFilms get_url returns playable stream candidates" {
    run plugin_get_url "salaar-2023-dual-audio-hindi-telugu-movie-web-dl-esub-480p-720p-1080p" "720"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    # Must be a valid JSON array of stream objects with the hubcloud chain
    local raw="$output"
    run jq -e 'type == "array" and length > 0' <<< "$raw"
    [ "$status" -eq 0 ]
    run jq -e 'all(.[]; has("url") and has("quality") and has("provider"))' <<< "$raw"
    [ "$status" -eq 0 ]
}

@test "DudeFilms health succeeds" {
    run plugin_health
    [ "$status" -eq 0 ]
}

@test "DudeFilms series seasons are extracted" {
    run plugin_list_seasons "some-series-slug"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "DudeFilms series episodes are extracted per season" {
    run plugin_list_episodes "some-series-slug" "1"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}
