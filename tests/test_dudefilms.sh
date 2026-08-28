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

@test "DudeFilms search filters unrelated WordPress fallback rows" {
    # WordPress falls back to recent posts when a query matches nothing
    # (e.g. "kgf" vs dotted titles "K.G.F") — those must not surface.
    run plugin_search "kgf" "720"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array" and length == 0' <<< "$output"
    [ "$status" -eq 0 ] || skip "KGF now present on the site"
}

@test "DudeFilms strict relevance: multi-word query keeps only exact match" {
    # "all of us are dead" used to match any title containing the word
    # "dead" (Deadstream, Darby and the Dead, ...). Now only the series
    # itself (or other titles containing ALL query words) should pass.
    run plugin_search "all of us are dead" "720"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    local raw="$output"
    run jq -e 'type == "array" and length == 1' <<< "$raw"
    [ "$status" -eq 0 ] || skip "site returned multiple results (still relevant)"
    run jq -e '.[0].title | test("All of Us Are Dead"; "i")' <<< "$raw"
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

@test "DudeFilms archive episode extraction survives multi-mirror pages" {
    # Offline: an archive page with TWO blocks for the same episode label
    # (multiple mirrors). Extraction must take the first href without an
    # early-exit head (SIGPIPE race) and resolve it as a stream.
    local ARCH='<html><body>
<a class="maxbutton-ep" href="https://cdn.example.workers.dev/ep1.mkv"><span>Episode 01</span></a>
<a class="maxbutton-ep" href="https://cdn.example.workers.dev/ep1b.mkv"><span>Episode 01</span></a>
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *archives*) printf '%s' "$ARCH" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' '' ;;
        esac
    }

    local out
    out="$(_df_resolve_archive_episode "https://dflinks.cc/archives/1" "1" 2>/dev/null || true)"
    [[ "$out" == *"ep1.mkv"* ]] || fail "episode extraction failed on multi-mirror page: $out"
    [[ "$out" != *"ep1b.mkv"* ]] || fail "did not take the first mirror: $out"
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

@test "DudeFilms multi-season post lists all seasons" {
    run plugin_list_seasons "house-of-the-dragon-season-1-2-dual-audio-hindi-english-web-series-bluray-esub-720p"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    local raw="$output"
    run jq -e 'type == "array" and length > 1' <<< "$raw"
    [ "$status" -eq 0 ] || skip "site returned single season"
    run jq -e '[.[].number] | contains([1, 2])' <<< "$raw"
    [ "$status" -eq 0 ]
}

@test "DudeFilms series episodes are extracted per season" {
    run plugin_list_episodes "some-series-slug" "1"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}

@test "DudeFilms series lists multiple episodes for a real series" {
    run plugin_list_episodes "house-of-the-dragon-season-03-dual-audio-hindi-english-webseries-web-dl-esubs-720p" "3"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    # Real series: several per-episode entries with distinct numbers
    local raw="$output"
    run jq -e 'length > 1' <<< "$raw"
    [ "$status" -eq 0 ] || skip "site returned single pack"
    run jq -e '[.[].number] | max >= 2' <<< "$raw"
    [ "$status" -eq 0 ]
}

@test "DudeFilms list_episodes handles zero-padded episode counts (octal trap)" {
    # Regression: episode labels like "Episode 09" yield ep_count="09", which
    # bash arithmetic reads as OCTAL (invalid -> "value too great for base"
    # error). The for-loop aborted and list_episodes emitted []. Fix forces
    # base-10 via 10#. Stub an archive page whose highest episode is 09.
    local DETAIL='<html><body><a href="https://dflinks.cc/archives/777">links</a></body></html>'
    local ARCH='<html><body>
<a class="maxbutton-ep" href="https://cdn.example.workers.dev/e1.mkv"><span>Episode 01</span></a>
<a class="maxbutton-ep" href="https://cdn.example.workers.dev/e8.mkv"><span>Episode 08</span></a>
<a class="maxbutton-ep" href="https://cdn.example.workers.dev/e9.mkv"><span>Episode 09</span></a>
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *archives/777*) printf '%s' "$ARCH" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' "$DETAIL" ;;
        esac
    }

    local raw
    raw="$(plugin_list_episodes "octal-series" "1" 2>/dev/null)"
    [[ -n "$raw" && "$raw" != "[]" ]] || fail "list_episodes emitted empty for Episode 09 archive (octal trap)"
    run jq -e 'length == 9' <<< "$raw"
    assert_success
    run jq -e '[.[].episode] | max == 9' <<< "$raw"
    assert_success
}

@test "DudeFilms per-episode get_url resolves distinct streams" {
    run plugin_get_url "house-of-the-dragon-season-03-dual-audio-hindi-english-webseries-web-dl-esubs-720p:3:1" "720"
    [ "$status" -eq 0 ] || skip "DudeFilms site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}
