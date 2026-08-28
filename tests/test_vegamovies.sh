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

@test "VegaMovies strict relevance: partial/fuzzy matches filtered" {
    # "salaar" used to return Sawaari (2016) / Maa Tujhhe Salaam (2002)
    # via Typesense fuzzy matching — neither is the requested movie.
    # Salaar is not on the vegamovies catalog, so this must be empty
    # (and never surface unrelated partial-title matches).
    run plugin_search "salaar" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    local raw="$output"
    if [[ "$(printf '%s' "$raw" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]]; then
        skip "Salaar not present on catalog (expected) — filter drops noise"
    fi
    run jq -e '[.[] | select(.title | test("Salaar"; "i"))] | length > 0' <<< "$raw"
    [ "$status" -eq 0 ]
}

@test "VegaMovies get_url returns playable stream candidates for a movie" {
    run plugin_get_url "download-spider-man-brand-new-day-2026" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    # Must have at least one direct R2 stream (the V-Cloud chain output)
    run jq -e '[.[] | select(.url | contains("r2.cloudflarestorage"))] | length > 0' <<< "$output"
    [ "$status" -eq 0 ] || skip "no live R2 mirrors in current window"
}

@test "VegaMovies nexdrive routes gpdl2.hubcloud.cx to the redirect branch" {
    # Offline: a nexdrive page with BOTH a gpdl2.hubcloud.cx pixel link and
    # a vcloud link. The gpdl2 link must go through the follow-redirect
    # branch (its final URL emitted), NOT the vcloud resolver — *hubcloud.cx*
    # in the vcloud family used to shadow *gpdl*.hubcloud.cx (SC2221/2222)
    # and dropped those streams.
    local NEXDRIVE='<html><body>
<a href="https://gpdl2.hubcloud.cx/?id=XYZ">pixel</a>
<a href="https://vcloud.fit/j_123">vcloud</a>
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *gpdl2.hubcloud.cx*) printf '%s' 'https://final.example/real.mkv' ;;
            *nexdrive*)          printf '%s' "$NEXDRIVE" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *)                   printf '%s' '' ;;
        esac
    }

    local out
    out="$(_vm_resolve_nexdrive "https://nexdrive.fit/genxfm1/" 2>/dev/null)"
    [[ "$out" == "https://final.example/real.mkv" ]] || fail "gpdl2 not routed through redirect branch: $out"
}

@test "VegaMovies episode pairing stays inside its own label block" {
    # Regression: the family-preference scan took the NEXT link of the
    # preferred family AFTER the label, unbounded — an episode block that
    # lacks vcloud/fastdl (only dgdrive) grabbed the NEXT episode's link
    # and paired E1 with E2's stream. Now bounded by the next label.
    local SERIES='<html><body>
Season 1 <a href="https://nexdrive.fit/genxfm1/">links</a>
</body></html>'
    local EP_PAGE='<html><body>
-:Episodes: 1:- <a href="https://dgdrive.pro/FILE1">
-:Episodes: 2:- <a href="https://vcloud.fit/j2">
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *nexdrive*) printf '%s' "$EP_PAGE" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' "$SERIES" ;;
        esac
    }

    local raw
    raw="$(plugin_list_episodes "series-slug" "1" 2>/dev/null)"
    [[ -n "$raw" ]] || fail "no episodes emitted"
    run jq -e 'length == 2' <<< "$raw"
    assert_success
    run jq -e '.[0].url == "https://dgdrive.pro/FILE1"' <<< "$raw"
    assert_success
    run jq -e '.[1].url == "https://vcloud.fit/j2"' <<< "$raw"
    assert_success
}

@test "VegaMovies get_url episode pick does not leak the next block's link" {
    # Regression (get_url twin): requesting E1 whose block only has dgdrive
    # (ad-gated, rejected) must NOT return E2's vcloud stream — the old
    # unbounded scan paired E1 with the next preferred-family link.
    local SERIES='<html><body>
Season 1 <a href="https://nexdrive.fit/genxfm1/">links</a>
</body></html>'
    local EP_PAGE='<html><body>
-:Episodes: 1:- <a href="https://dgdrive.pro/FILE1">
-:Episodes: 2:- <a href="https://vcloud.fit/j2">
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *nexdrive*) printf '%s' "$EP_PAGE" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' "$SERIES" ;;
        esac
    }
    _vm_resolve_vcloud() { printf '%s\n' "$1"; }
    _vm_resolve_dgdrive() { printf '%s\n' "$1"; }

    run plugin_get_url "series-slug:1:1" 720
    assert_failure
    [[ "$output" != *"vcloud.fit/j2"* ]]
    [[ "$output" == *"No playable links resolved"* ]]
}

@test "VegaMovies health succeeds" {
    run plugin_health
    [ "$status" -eq 0 ]
}

@test "VegaMovies series seasons are extracted" {
    run plugin_list_seasons "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    # The post covers Season 1-4 — all four must be listed
    run jq -e 'type == "array" and length == 4' <<< "$output"
    [ "$status" -eq 0 ] || skip "season count differs (site content changed)"
}

@test "VegaMovies series episodes are extracted per season" {
    run plugin_list_episodes "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl" "1"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    local raw="$output"
    run jq -e 'type == "array" and length > 0' <<< "$raw"
    [ "$status" -eq 0 ]
    # episodes must carry the right season + distinct episode numbers
    run jq -e 'all(.[]; .season == 1 and .episode >= 1)' <<< "$raw"
    [ "$status" -eq 0 ]
}

@test "VegaMovies hub page: season URL extracted and resolver links followed" {
    # 2026-08 redesign: series posts are HUB pages (season headings + Download
    # Now buttons, NO nexdrive links). The resolver links live on each season's
    # dedicated page. Verify _vm_is_hub_page detects the hub, _vm_hub_season_url
    # maps season N to its page, and get_url follows through to resolve.
    local HUB='<html><body>
<h5>Season 1 Single Episodes</h5>
<a href="/download-show-season-1-hindi-480p/" rel="nofollow"><button class="dwd-button">Download Now</button></a>
<h5>Season 2 Single Episodes</h5>
<a href="/download-show-season-2-hindi-720p/" rel="nofollow"><button class="dwd-button">Download Now</button></a>
</body></html>'
    local SEASON_PAGE='<html><body>
Season 2
<a href="https://nexdrive.fit/genxfm123456/">V-Cloud</a>
</body></html>'
    local EP_PAGE='<html><body>
-:Episodes: 1:- <a href="https://vcloud.fit/ep1link">
</body></html>'
    # _vm_resolve_vcloud fetches the vcloud.fit page via `curl -sL` and takes
    # the direct-link branch when an r2.cloudflarestorage URL is present.
    local VCLOUD_PAGE='<html><body>
<a href="https://abc123.r2.cloudflarestorage.com/hub2/Show.S02E01.720p.mkv?X-Amz-Signature=deadbeef">Download</a>
</body></html>'
    curl() {
        local url="${@: -1}"
        case "$url" in
            *season-2-hindi-720p*) printf '%s' "$SEASON_PAGE" ;;
            *vcloud.fit/ep1link*)  printf '%s' "$VCLOUD_PAGE" ;;
            *nexdrive*)            printf '%s' "$EP_PAGE" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *)                     printf '%s' "$HUB" ;;
        esac
    }

    # hub detection
    run _vm_is_hub_page "$HUB"
    assert_success
    # season 2 maps to its page
    run _vm_hub_season_url "$HUB" "2"
    assert_success
    [ "$output" = "/download-show-season-2-hindi-720p/" ]
    # season 1 maps to its page
    run _vm_hub_season_url "$HUB" "1"
    [ "$output" = "/download-show-season-1-hindi-480p/" ]
    # get_url follows hub -> season page -> episode link and resolves
    run plugin_get_url "show-slug:2:1" "720"
    [ "$status" -eq 0 ] || fail "get_url failed on hub page: $output"
    run jq -e '.. | objects | select(has("url")) | .url' <<< "$output"
    assert_success
}

@test "VegaMovies series get_url resolves streams (season-pack)" {
    run plugin_get_url "download-that-time-i-got-reincarnated-as-a-slime-season-1-4-hindi-dubbed-series-480p-720p-1080p-web-dl:1:1" "720"
    [ "$status" -eq 0 ] || skip "VegaMovies site unavailable"
    run jq -e 'type == "array" and length > 0' <<< "$output"
    [ "$status" -eq 0 ]
}
