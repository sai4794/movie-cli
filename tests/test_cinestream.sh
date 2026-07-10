#!/usr/bin/env bats
# test_cinestream.sh — Tests for the CineStream plugin

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
    source "$PROJECT_DIR/plugins/cinestream.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "CineStream metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "CineStream" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[0]}" == "movie" ]]
    [[ "${PLUGIN_TYPES[1]}" == "series" ]]
}

@test "CineStream info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"CineStream","version":"1.0.0","types":["movie","series"]}'
}

@test "CineStream health succeeds" {
    run plugin_health
    assert_success
}

@test "CineStream search returns valid JSON array of results" {
    # Perform a search for Inception
    run plugin_search "inception"
    assert_success
    
    # Assert output is valid JSON array and contains at least one result
    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -gt 0 ]]
    
    # Assert schema fields of the first result
    local first_item
    first_item=$(printf '%s' "$output" | jq -c '.[0]')
    [[ "$(printf '%s' "$first_item" | jq -r '.id')" =~ ^tt[0-9]+$ ]]
    [[ -n "$(printf '%s' "$first_item" | jq -r '.title')" ]]
    [[ "$(printf '%s' "$first_item" | jq -r '.type')" =~ ^(movie|series)$ ]]
}

@test "CineStream list seasons returns valid seasons for Breaking Bad" {
    run plugin_list_seasons "tt0903747"
    assert_success
    
    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -ge 5 ]] # Breaking Bad has 5 seasons
    
    local first_season
    first_season=$(printf '%s' "$output" | jq -c '.[0]')
    [[ "$(printf '%s' "$first_season" | jq -r '.id')" == "1" ]]
    [[ "$(printf '%s' "$first_season" | jq -r '.title')" == "Season 1" ]]
    [[ "$(printf '%s' "$first_season" | jq -r '.number')" -eq 1 ]]
}

@test "CineStream list episodes returns episodes for Breaking Bad Season 1" {
    run plugin_list_episodes "tt0903747" "1"
    assert_success
    
    local count
    count=$(printf '%s' "$output" | jq '. | length')
    [[ "$count" -ge 7 ]] # Season 1 has 7 episodes
    
    local first_ep
    first_ep=$(printf '%s' "$output" | jq -c '.[0]')
    [[ "$(printf '%s' "$first_ep" | jq -r '.id')" == "tt0903747:1:1" ]]
    [[ "$(printf '%s' "$first_ep" | jq -r '.season')" -eq 1 ]]
    [[ "$(printf '%s' "$first_ep" | jq -r '.episode')" -eq 1 ]]
    [[ -n "$(printf '%s' "$first_ep" | jq -r '.title')" ]]
}

@test "CineStream get url resolves direct video stream link" {
    # Resolve URL for Inception
    run plugin_get_url "tt1375666" "1080"
    assert_success
    # plugin_get_url returns JSON array, not raw URL
    [[ "$(printf '%s' "$output" | head -c 1)" == "[" ]]
    
    # Verify it contains a URL
    [[ "$output" == *"https://"* ]]
    
    # Resolve URL for Breaking Bad Season 1 Episode 1
    run plugin_get_url "tt0903747:1:1" "1080"
    assert_success
    [[ "$(printf '%s' "$output" | head -c 1)" == "[" ]]
    [[ "$output" == *"https://"* ]]
}

@test "CineStream search ranks relevant titles above unrelated ones" {
    run plugin_search "salaar"
    assert_success

    # Verify results are valid JSON array
    local count
    count=$(printf '%s' "$output" | jq 'length')
    [[ "$count" -gt 0 ]]

    # Verify Salaar titles come first (ranked by relevance)
    local first_title
    first_title=$(printf '%s' "$output" | jq -r '.[0].title')
    [[ "$first_title" == *"Salaar"* ]]

    # Verify no unrelated titles like "Saving Private Ryan" or "Kids"
    local has_unrelated
    has_unrelated=$(printf '%s' "$output" | jq -r '.[].title' | grep -i "saving private\|kids\|cartels" || true)
    [[ -z "$has_unrelated" ]]
}
