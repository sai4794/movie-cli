#!/usr/bin/env bats
# test_movieblast.sh — Tests for the MovieBlast plugin (offline-safe)

setup() {
    load 'bats-support/load'
    load 'bats-assert/load'

    PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    BATS_TEST_TMPDIR="$(mktemp -d)"
    export HOME="$BATS_TEST_TMPDIR"
    export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/.config"
    export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/.cache"
    export XDG_DATA_HOME="$BATS_TEST_TMPDIR/.local/share"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/run"

    mkdir -p "$XDG_CONFIG_HOME/movie-cli"
    mkdir -p "$XDG_CACHE_HOME/movie-cli"
    mkdir -p "$XDG_DATA_HOME/movie-cli"
    mkdir -p "$XDG_RUNTIME_DIR"

    export DEBUG=0
    export VERBOSE=0
    export QUIET=1

    source "$PROJECT_DIR/lib/init.sh"
    source "$PROJECT_DIR/lib/errors.sh"
    source "$PROJECT_DIR/plugins/movieblast.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "MovieBlast metadata is correctly set" {
    [[ "$PLUGIN_NAME" == "MovieBlast" ]]
    [[ "$PLUGIN_API_VERSION" == "5" ]]
    [[ "${PLUGIN_TYPES[*]}" == *"movie"* ]]
    [[ "${PLUGIN_TYPES[*]}" == *"series"* ]]
}

@test "MovieBlast info returns correct JSON format" {
    run plugin_info
    assert_success
    assert_output '{"name":"MovieBlast","version":"1.0.0","types":["movie","series"]}'
}

@test "MovieBlast plugin_get_url fails cleanly when API has no sources" {
    # Regression: qualities_json was uninitialized when .seasons/.videos was
    # missing → set -u "unbound variable" crash inside the subshell instead
    # of a clean die_plugin. Now initialized to [].
    _mb_api() { printf '%s' '{}'; }
    run plugin_get_url "12345" 720
    assert_failure
    [[ "$output" == *"No video sources"* ]]
}

@test "MovieBlast sign_url appends verify as ? for clean URLs" {
    local out
    out="$(_mb_sign_url "https://cdn.example/video.mkv")"
    [[ "$out" == "https://cdn.example/video.mkv?verify="* ]] || fail "bad suffix: $out"
    [[ "$(printf '%s' "$out" | grep -o '?' | wc -l)" -eq 1 ]]
}

@test "MovieBlast sign_url appends verify as & when URL already has a query" {
    # Regression: a second '?' corrupted signed URLs with token params.
    local out
    out="$(_mb_sign_url "https://cdn.example/video.mkv?token=abc")"
    [[ "$out" == "https://cdn.example/video.mkv?token=abc&verify="* ]] || fail "bad suffix: $out"
    [[ "$(printf '%s' "$out" | grep -o '?' | wc -l)" -eq 1 ]]
}

@test "MovieBlast plugin_sign_url strips old verify and re-signs" {
    local signed re
    signed="$(_mb_sign_url "https://cdn.example/video.mkv?token=abc")"
    re="$(plugin_sign_url "$signed")"
    [[ "$re" == "https://cdn.example/video.mkv?token=abc&verify="* ]] || fail "bad re-sign: $re"
    [[ "$(printf '%s' "$re" | grep -o '?' | wc -l)" -eq 1 ]]
}
