#!/usr/bin/env bats
# test_movies4u.sh — Tests for the Movies4u plugin

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
    source "$PROJECT_DIR/plugins/movies4u.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "Movies4u metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "Movies4u" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "Movies4u info returns correct JSON format" {
    run plugin_info
    [[ "$status" -eq 0 ]]
    [[ "$output" == *'"name":"Movies4u"'* ]]
    [[ "$output" == *'"types":["movie","series"]'* ]]
}

@test "Movies4u health succeeds" {
    run plugin_health
    [[ "$status" -eq 0 ]]
}

@test "Movies4u search returns valid JSON array of results" {
    run plugin_search "inception"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    [[ "$raw" == "["* ]] || fail "not a JSON array: $raw"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].id != null and .[0].title != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "Movies4u search ranks relevant titles above unrelated ones" {
    local raw
    raw="$(plugin_search "inception" 2>/dev/null)"
    local top
    top="$(jq -r '.[0].title' <<< "$raw")"
    [[ "$top" == *"Inception"* ]] || fail "top result not Inception: $top"
}

@test "Movies4u search returns empty for nonsense query" {
    local raw
    raw="$(plugin_search "zzqxqj-nonsense-xyz" 2>/dev/null)"
    [[ "$raw" == "[]" ]] || fail "expected empty array, got: $raw"
}

@test "Movies4u get_url returns playable stream candidates for a movie" {
    run plugin_get_url "inception-2010-bluray-dual-audio-hindi-org-english-full-movie"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].url != null and .[0].provider != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "Movies4u series seasons are extracted" {
    run plugin_list_seasons "breaking-bad-season-1-5-dual-audio-hindi-org-english-complete-web-series-bluray"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length >= 3' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].number != null' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "Movies4u series episodes are extracted per season" {
    run plugin_list_episodes "breaking-bad-season-1-5-dual-audio-hindi-org-english-complete-web-series-bluray" "1"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length >= 1' <<< "$raw"
    [[ "$status" -eq 0 ]]
    run jq -e '.[0].episode == 1 and .[0].season == 1' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "Movies4u series get_url resolves a specific episode" {
    run plugin_get_url "breaking-bad-season-1-5-dual-audio-hindi-org-english-complete-web-series-bluray:1:1"
    [[ "$status" -eq 0 ]]
    local raw="$output"
    run jq -e 'length > 0' <<< "$raw"
    [[ "$status" -eq 0 ]]
}

@test "Movies4u resolver rejects gates and keeps direct hosts" {
    _m4u_is_stream_candidate "https://t.me/foo" && return 1
    _m4u_is_stream_candidate "https://drivebot.sbs/download?id=x" && return 1
    _m4u_is_stream_candidate "https://filesgram.xyz/?start=x" && return 1
    _m4u_is_stream_candidate "https://tgredirect.pages.dev/x" && return 1
    _m4u_is_stream_candidate "https://hubcloud.cx/drive/abc" && return 1
    _m4u_is_stream_candidate "https://x.workers.dev/file.mkv" || return 1
    _m4u_is_stream_candidate "https://x.r2.cloudflarestorage.com/hub/abc" || return 1
    _m4u_is_stream_candidate "https://pixeldrain.com/u/abc" || return 1
}
