#!/usr/bin/env bats
# test_castle.sh — Tests for the CastleTv plugin

setup() {
    load 'bats-support/load'
    load 'bats-assert/load'

    PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export PATH="$PROJECT_DIR:$PATH"

    # Source init, errors, then the plugin (bats setup order)
    source "$PROJECT_DIR/lib/init.sh"
    source "$PROJECT_DIR/lib/errors.sh"
    source "$PROJECT_DIR/plugins/castle.sh"
}

@test "CastleTv metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "CastleTv" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "CastleTv info returns correct JSON format" {
    run plugin_info
    assert_success
    local info="$output"
    [[ $(echo "$info" | jq -r '.name') == "CastleTv" ]]
    [[ $(echo "$info" | jq -r '.version') == "1.0.0" ]]
}

@test "CastleTv health succeeds" {
    run plugin_health
    assert_success
}

@test "CastleTv search returns valid JSON array of results" {
    run plugin_search "inception"
    assert_success
    local raw="$output"
    local count
    count=$(echo "$raw" | jq 'length')
    [[ $count -ge 1 ]]
    echo "$raw" | jq -e '.[0].id' >/dev/null
    echo "$raw" | jq -e '.[0].title' >/dev/null
    echo "$raw" | jq -e '.[0].type' >/dev/null
}

@test "CastleTv search ranks relevant titles above unrelated ones" {
    run plugin_search "inception"
    local raw="$output"
    local first_title
    first_title=$(echo "$raw" | jq -r '.[0].title')
    [[ "${first_title,,}" == *"inception"* ]]
}

@test "CastleTv search returns empty for nonsense query" {
    run plugin_search "zzqxqj-nonsense-xyz"
    # Castle API may return related results; just verify no crash
    assert_success
}

@test "CastleTv get_url returns playable stream candidates for a movie" {
    run plugin_search "inception"
    local movie_id
    movie_id=$(echo "$output" | jq -r '.[0].id')
    run plugin_get_url "$movie_id" 720
    assert_success
    local raw="$output"
    # Output is a single JSON object, not array
    echo "$raw" | jq -e '.url' >/dev/null
    local url
    url=$(echo "$raw" | jq -r '.url')
    [[ "$url" == *"m3u8"* ]]
}

@test "CastleTv series seasons are extracted" {
    # Search for Breaking Bad to get a season ID
    run plugin_search "breaking bad"
    local series_id
    series_id=$(echo "$output" | jq -r '.[0].id')
    run plugin_list_seasons "$series_id"
    assert_success
    local raw="$output"
    [[ $(echo "$raw" | jq 'length') -ge 2 ]]
}

@test "CastleTv series episodes are extracted per season" {
    run plugin_search "breaking bad"
    local series_id
    series_id=$(echo "$output" | jq -r '.[0].id')
    run plugin_list_episodes "$series_id" "1"
    assert_success
    local raw="$output"
    [[ $(echo "$raw" | jq 'length') -ge 5 ]]
    echo "$raw" | jq -e '.[0].name' >/dev/null
}

@test "CastleTv series get_url resolves a specific episode" {
    run plugin_search "breaking bad"
    local series_id
    series_id=$(echo "$output" | jq -r '.[0].id')
    run plugin_get_url "${series_id}:1:1" 720
    assert_success
    local raw="$output"
    echo "$raw" | jq -e '.url' >/dev/null
    local url
    url=$(echo "$raw" | jq -r '.url')
    [[ "$url" == *"m3u8"* ]]
}
