#!/usr/bin/env bash
# tests/setup.sh — Test helpers, mock functions, temp directories
# Source this at the top of every test file

# Load bats helpers
load 'bats-support/load'
load 'bats-assert/load'

# Project root
PROJECT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

# Temp directory for each test
setup() {
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
    
    # Create test MovieBlast config
    cat > "$XDG_CONFIG_HOME/movie-cli/movieblast.conf" << 'EOF'
HASH256=test_hash256
PACKAGENAME=com.movieblast
SIGNATURE=test_signature
HMAC_SECRET=test_hmac_secret
TOKEN=test_token
EOF
    
    # Suppress debug output during tests
    export DEBUG=0
    export VERBOSE=0
    export QUIET=1
    
    # Source all project libraries
    source_project
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# Source project libraries
source_project() {
    source "$PROJECT_DIR/lib/init.sh"
    source "$PROJECT_DIR/lib/errors.sh"
    source "$PROJECT_DIR/lib/config.sh"
    source "$PROJECT_DIR/lib/cache.sh"
    source "$PROJECT_DIR/lib/ui.sh"
    source "$PROJECT_DIR/lib/player.sh"
    source "$PROJECT_DIR/lib/history.sh"
}

# Mock curl — returns fixture based on URL pattern
mock_curl() {
    local url="$1"
    case "$url" in
        *movieblast*search*)  cat "$PROJECT_DIR/tests/fixtures/movieblast_search.json" ;;
        *movieblast*detail*)  cat "$PROJECT_DIR/tests/fixtures/movieblast_detail.json" ;;
        *empty*)              echo "[]" ;;
        *error*)              return 1 ;;
        *malformed*)          echo "{broken json" ;;
        *)                    return 1 ;;
    esac
}
export -f mock_curl

# Mock fzf — always select first item
mock_fzf() {
    head -1
}
export -f mock_fzf