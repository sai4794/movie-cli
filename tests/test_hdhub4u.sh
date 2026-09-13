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

@test "HDhub4u get_url routes padded AND unpadded episode labels" {
    # Offline: stub curl with a 2-episode fixture chain; each episode's
    # hubdrive file resolves to a distinct mkv so routing errors (wrong
    # episode pulled) are caught. Regression guard for the E%02d-vs-E(\d{1,2})
    # mismatch that left unpadded "E2" labels unresolvable.
    local DETAIL='<html><body>
E1 &ndash; <a href="https://hubdrive.tips/file/ONE">link1</a>
E2 - <a href="https://hubdrive.tips/file/TWO">link2</a>
</body></html>'
    curl() {
        local url="${@: -1}"
        local id
        case "$url" in
            *hubcloud.php*) id="${url##*id=}"; printf '<a href="https://cdn.example.workers.dev/%s.mkv" class="btn btn-success btn-lg h6">D</a>' "$id" ;;
            */drive/*) id="${url##*/}"; printf '<a id="download" href="https://gamerxyt.com/hubcloud.php?id=%s">x</a>' "$id" ;;
            *file/ONE*) printf '<a href="https://hubcloud.cx/drive/DRV-ONE">d</a>' ;;
            *file/TWO*) printf '<a href="https://hubcloud.cx/drive/DRV-TWO">d</a>' ;;
            *test-series*) printf '%s' "$DETAIL" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' '' ;;
        esac
    }

    local raw
    raw="$(plugin_get_url "test-series:1:2" 2>/dev/null)"
    [[ -n "$raw" ]] || fail "ep2 (unpadded E2 label) resolved nothing"
    run jq -e '.[0].url == "https://cdn.example.workers.dev/DRV-TWO.mkv"' <<< "$raw"
    assert_success

    raw="$(plugin_get_url "test-series:1:1" 2>/dev/null)"
    [[ -n "$raw" ]] || fail "ep1 (padded E1 label) resolved nothing"
    run jq -e '.[0].url == "https://cdn.example.workers.dev/DRV-ONE.mkv"' <<< "$raw"
    assert_success
}

@test "HDhub4u get_url resolves movie posts behind the JS ad-gate" {
    # Offline: 2026-08 redesign routes movie download buttons through a
    # greenmountmotors.com/?id=<b64> JS gate instead of direct hubdrive
    # links. The gate page embeds a token (b64d->b64d->rot13->b64d->JSON
    # ->atob(o)) that decodes to an hblinks.co archive page listing the
    # hubdrive mirrors. Stub the whole chain; assert the movie resolves.
    local TOKEN
    TOKEN=$(python3 -c '
import base64, codecs, json
payload = json.dumps({"w":10,"l":"https://greenmountmotors.com/homelander/","o":base64.b64encode(b"https://hblinks.co/archives/777").decode()})
l3 = base64.b64encode(payload.encode()).decode()
l2 = codecs.encode(l3, "rot_13")
l1 = base64.b64encode(l2.encode()).decode()
print(base64.b64encode(l1.encode()).decode())
')
    local DETAIL="<html><body><a href=\"https://greenmountmotors.com/?id=GATE1\"><em>720p Links [1GB]</em></a></body></html>"
    local GATE_PAGE="<html><script>s('o','$TOKEN',180*1000);</script></html>"
    local HBLINKS='<html><a href="https://hubdrive.tips/file/GMOV">Instant Download</a></html>'
    curl() {
        local url="${@: -1}"
        local id
        case "$url" in
            *hubcloud.php*) id="${url##*id=}"; printf '<a href="https://cdn.example.workers.dev/%s.mkv" class="btn btn-success btn-lg h6">D</a>' "$id" ;;
            */drive/*) id="${url##*/}"; printf '<a id="download" href="https://gamerxyt.com/hubcloud.php?id=%s">x</a>' "$id" ;;
            *file/GMOV*) printf '<a href="https://hubcloud.cx/drive/DRV-GMOV">d</a>' ;;
            *greenmountmotors*) printf '%s' "$GATE_PAGE" ;;
            *hblinks.co*) printf '%s' "$HBLINKS" ;;
            *test-gated-movie*) printf '%s' "$DETAIL" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' '' ;;
        esac
    }

    local raw
    raw="$(plugin_get_url "test-gated-movie" 2>/dev/null)"
    [[ -n "$raw" ]] || fail "gated movie resolved nothing (gate decode broken)"
    run jq -e '.[0].url == "https://cdn.example.workers.dev/DRV-GMOV.mkv"' <<< "$raw"
    assert_success
}

@test "HDhub4u get_url routes pixel links on rotated hubcloud TLDs" {
    # Offline: hubcloud rotates TLDs (pixel.hubcloud.cx -> .ist -> ...).
    # Pixel redirector links must be resolved via the dl.php?link= page,
    # not emitted raw (raw pixel URLs serve HTML and die in verify_streams,
    # leaving zero playable streams). Regression guard: PIXEL_GLOBS must
    # stay TLD-agnostic.
    local DETAIL='<html><body><a href="https://hubdrive.tips/file/PIXF">dl</a></body></html>'
    curl() {
        local url="${@: -1}"
        local id
        case "$url" in
            # sdk_resolve_pixel probes with `-o tmpfile -w %{url_effective}`:
            # the stub curl must swallow flags and serve: real curl writes
            # the dl.php page to the -o file and prints url_effective.
            *pixel.hubcloud.ist*)
                local outfile="" wants_effective=0 a
                for a in "$@"; do
                    [[ "$a" == "-o" ]] && { outfile="next"; continue; }
                    [[ "$outfile" == "next" ]] && { outfile="$a"; continue; }
                    [[ "$a" == "%{url_effective}" ]] && wants_effective=1
                done
                if (( wants_effective )); then
                    printf '%s' 'https://dl.example/dl.php?link=https%3A%2F%2Fcdn.example.workers.dev%2FPIXEL.mkv'
                elif [[ -n "$outfile" && "$outfile" != "next" ]]; then
                    printf '<a href="https://dl.example/other">x</a>' > "$outfile"
                fi
                ;;
            *hubcloud.php*) printf '<a href="https://pixel.hubcloud.ist/?id=PIX1" class="btn btn-success btn-lg h6">D</a>' ;;
            */drive/*) printf '<a id="download" href="https://gamerxyt.com/hubcloud.php?id=DRV-PIX">x</a>' ;;
            *file/PIXF*) printf '<a href="https://hubcloud.cx/drive/DRV-PIX">d</a>' ;;
            *test-pixel-ist*) printf '%s' "$DETAIL" ;;
            *raw.githubusercontent*) printf '%s' '{}' ;;
            *) printf '%s' '' ;;
        esac
    }

    local raw
    raw="$(plugin_get_url "test-pixel-ist" 2>/dev/null)"
    [[ -n "$raw" ]] || fail "pixel-hosted movie resolved nothing"
    run jq -e '.[0].url == "https://cdn.example.workers.dev/PIXEL.mkv"' <<< "$raw"
    assert_success
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
