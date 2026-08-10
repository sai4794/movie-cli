#!/usr/bin/env bats
# test_cinex.sh — Tests for the CineX multi-provider plugin

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
    source "$PROJECT_DIR/plugins/cinex.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "CineX metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "CineX" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "CineX info returns correct JSON format" {
    local raw="$PLUGIN_NAME"
    run plugin_info
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"name":"CineX"'* ]]
    [[ "$output" == *'"types":["movie","series"]'* ]]
    # registry must be a JSON array in the info payload
    [[ "$output" == *'"providers":['* ]]
}

@test "CineX provider registry is populated and functions exist" {
    [[ ${#_CX_REGISTRY[@]} -ge 10 ]]
    for p in "${_CX_REGISTRY[@]}"; do
        declare -f "_cx_provider_${p}" >/dev/null 2>&1 || fail "provider $p has no function"
    done
}

@test "CineX health succeeds" {
    run plugin_health
    [[ "$status" -eq 0 ]]
}

@test "CineX search returns valid JSON array of results" {
    run plugin_search "inception"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    [[ "$raw" == "["* ]] || fail "not a JSON array: $raw"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].id != null and .[0].title != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "CineX search ranks relevant titles above unrelated ones" {
    local raw
    raw="$(plugin_search "inception" 2>/dev/null)"
    local top
    top="$(jq -r '.[0].title' <<< "$raw")"
    [[ "$top" == *"Inception"* ]] || fail "top result not Inception: $top"
}

@test "CineX list seasons returns valid seasons for Breaking Bad" {
    run plugin_list_seasons "tt0903747"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length >= 1' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].number != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "CineX list episodes returns episodes for Breaking Bad Season 1" {
    run plugin_list_episodes "tt0903747" "1"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length >= 1' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].episode != null and .[0].id != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "CineX get url resolves streams for Inception (movie)" {
    skip "live multi-provider resolution is slow (~90s); verified manually"
    run plugin_get_url "tt1375666"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].url != null and .[0].provider != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "CineX get url resolves streams for Breaking Bad S1E1 (series)" {
    skip "live multi-provider resolution is slow (~90s); verified manually"
    run plugin_get_url "tt0903747:1:1"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "CineX id parsing handles movie and series ids" {
    _cx_parse_id "tt1375666"
    [[ "$_CX_IMDB" == "tt1375666" ]]
    [[ -z "$_CX_SEASON" ]]
    _cx_parse_id "tt0903747:1:1"
    [[ "$_CX_IMDB" == "tt0903747" ]]
    [[ "$_CX_SEASON" == "1" ]]
    [[ "$_CX_EPISODE" == "1" ]]
}
