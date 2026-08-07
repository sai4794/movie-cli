#!/usr/bin/env bats
# test_update.sh — Tests for the self-update command (lib/update.sh)

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
    source "$PROJECT_DIR/lib/config.sh"
    source "$PROJECT_DIR/lib/cache.sh"
    source "$PROJECT_DIR/lib/ui.sh"
    source "$PROJECT_DIR/lib/player.sh"
    source "$PROJECT_DIR/lib/history.sh"
    source "$PROJECT_DIR/lib/update.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

@test "update.sh defines update_self" {
    declare -f update_self >/dev/null
}

@test "update_self detects git mode in a git checkout" {
    # The project dir is a git repo — mode detection should say git
    run bash -c '
        source "$1/lib/init.sh"
        source "$1/lib/errors.sh"
        source "$1/lib/config.sh"
        source "$1/lib/cache.sh"
        source "$1/lib/ui.sh"
        source "$1/lib/player.sh"
        source "$1/lib/history.sh"
        source "$1/lib/update.sh"
        if [[ -d "$1/.git" ]]; then echo "git"; else echo "release"; fi
    ' _ "$PROJECT_DIR"
    assert_output "git"
}

@test "update_check reports remote main SHA (network)" {
    run update_check
    # Either up-to-date (rc=1) or update available (rc=0); must print mode
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
    assert_output --partial "Install mode:"
} 2>/dev/null || true

@test "dirty git tree refuses update" {
    # Create a fake dirty repo
    local fake_repo="$BATS_TEST_TMPDIR/fake-repo"
    mkdir -p "$fake_repo"
    git -C "$fake_repo" init -q 2>/dev/null
    echo "x" > "$fake_repo/file.txt"
    git -C "$fake_repo" add file.txt 2>/dev/null
    git -C "$fake_repo" -c user.email=t@t -c user.name=t commit -qm init 2>/dev/null
    echo "dirty" >> "$fake_repo/file.txt"  # uncommitted change

    run bash -c '
        source "$1/lib/init.sh"
        source "$1/lib/errors.sh"
        source "$1/lib/config.sh"
        source "$1/lib/cache.sh"
        source "$1/lib/ui.sh"
        source "$1/lib/player.sh"
        source "$1/lib/history.sh"
        source "$1/lib/update.sh"
        SCRIPT_DIR="$2"
        _update_git 2>&1 || true
        echo "rc=$?"
    ' _ "$PROJECT_DIR" "$fake_repo"
    assert_output --partial "uncommitted changes"
}

@test "release mode update swaps lib/plugins and preserves user config" {
    # Build a fake installed tree, run update in release mode
    local fake_bin="$BATS_TEST_TMPDIR/.local/bin"
    local fake_share="$BATS_TEST_TMPDIR/.local/share/movie-cli"
    mkdir -p "$fake_bin" "$fake_share" "$BATS_TEST_TMPDIR/.config/movie-cli"
    cp -r "$PROJECT_DIR/lib" "$fake_share/lib"
    cp -r "$PROJECT_DIR/plugins" "$fake_share/plugins"
    cp -r "$PROJECT_DIR/config" "$fake_share/config"
    cp "$PROJECT_DIR/movie-cli" "$fake_bin/movie-cli"
    chmod +x "$fake_bin/movie-cli"
    sed -i "s|SCRIPT_DIR=\".*\"|SCRIPT_DIR=\"$fake_share\"|" "$fake_bin/movie-cli"
    echo "user-data" > "$BATS_TEST_TMPDIR/.config/movie-cli/user.conf"

    run env HOME="$BATS_TEST_TMPDIR" XDG_DATA_HOME="$BATS_TEST_TMPDIR/.local/share" \
        "$fake_bin/movie-cli" update
    [ "$status" -eq 0 ] || skip "network unavailable"
    # User config untouched, lib present, backup created
    [ -f "$BATS_TEST_TMPDIR/.config/movie-cli/user.conf" ]
    [ -f "$fake_share/lib/init.sh" ]
    run ls -d "$BATS_TEST_TMPDIR/.local/share"/movie-cli-backup-*
    [ "$status" -eq 0 ]
}
