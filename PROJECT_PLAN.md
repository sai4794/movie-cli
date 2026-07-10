# Movie-CLI Project Plan (v6)

## Project Overview

**Name**: movie-cli
**Goal**: Terminal-based movie/series search and play tool
**Inspiration**: ani-cli (anime) → movie-cli (movies + series)
**Version**: 0.1.0
**Status**: Planning Phase (v6 — 15-Agent Review Complete, Legal Excluded)

---

## Architecture (MVP First)

```
movie-cli                 # Single script for v0.1
├── lib/
│   ├── init.sh           # set -euo pipefail, umask, traps, globals
│   ├── errors.sh         # Error handling (die_*, warn, info, debug, retry)
│   ├── config.sh         # Safe config loading (NOT source)
│   ├── player.sh         # yt-dlp + mpv/vlc/iina wrapper
│   ├── cache.sh          # Caching with TTL + eviction
│   ├── history.sh        # Watch history (JSONL format)
│   ├── download.sh       # Download orchestration
│   └── ui.sh             # fzf/rofi/dmenu selection, spinners
├── plugins/
│   ├── _template.sh      # Plugin template
│   ├── movieblast.sh     # MovieBlast API (v0.1 only)
│   └── cinestream.sh     # TMDB + embeds (v0.2+)
├── config/
│   └── default.conf      # Key=value format (NOT shell)
├── tests/
│   ├── setup.sh          # Mock curl, temp dirs, helpers
│   ├── test_core.sh      # Core functions
│   ├── test_security.sh  # Input validation
│   ├── test_history.sh   # History functions
│   └── fixtures/         # Mock API responses
├── install.sh            # Installer (with checksum)
├── uninstall.sh          # Uninstaller
├── CONTRIBUTING.md       # Contribution guide
├── SECURITY.md           # Vulnerability disclosure
└── README.md             # User docs
```

---

## MVP Scope (v0.1.0 — Phase 0-2 Only)

**Ship this first:**
- Core framework (config, security, error handling, fzf selection)
- MovieBlast plugin (search + play)
- Basic watch history (`-l` view, `-D` delete)
- `-q` quality selection
- Single player (mpv)
- Cross-platform installer

**Defer to v0.2+:**
- CineStream plugin
- Download mode
- Multiple players (vlc, iina)
- Syncplay
- JSON output
- rofi/dmenu alternatives
- Self-update mechanism
- `-e` episode range, `--dub` language, and `-c` continue watch history
- `uninstall.sh` (Shipped early as part of hardening)

---

## CLI Interface (v0.1 — 15 Flags)

```
Usage: movie-cli [OPTIONS] <query>

Search:
  -p, --plugin NAME      Use specific plugin (default: auto)
  -q, --quality LEVEL    Min quality: 480, 720, 1080 [default: 720]
  -S, --search-only      Output results without playing
      --select N         Auto-select Nth result

Playback:
  -e, --episode RANGE    Episode range (e.g., 5-6, 5-, "5 6")
      --dub [LANG]       Play dubbed version (default: en)
      --no-detach        Don't detach player

History:
  -c, --continue         Continue watching from history
  -l, --log              View watch history
  -D, --delete-history   Delete watch history

System:
  -u, --update           Self-update from GitHub
      --list-plugins     List available plugins
      --check-deps       Verify all dependencies
      --debug            Enable debug logging
  -v, --version          Show version
  -h, --help             Show this help

Examples:
  movie-cli "inception"
  movie-cli -q 1080 "breaking bad"
  movie-cli -e 5-6 "breaking bad"
  movie-cli -c                              # Continue watching
  movie-cli --dub "naruto"                  # English dub
  movie-cli --dub es "naruto"               # Spanish dub
  movie-cli --select 3 "inception"          # Pick 3rd result
  movie-cli --log                           # View history
```

---

## Safe Config Loading (NOT source)

```bash
# config/default.conf format (key=value, NO shell execution)
PLAYER=mpv
QUALITY=720
PLUGIN=auto
VERBOSE=0
DEBUG=0

# Safe loader — parse key=value, validate keys
load_config() {
    local valid_keys="PLAYER QUALITY PLUGIN VERBOSE DEBUG UI_BACKEND SYNCPLAY_HOST"
    local conf_file="$1"
    [[ -f "$conf_file" ]] || return 0
    
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        
        # Validate key is in allowlist
        if [[ " $valid_keys " == *" $key "* ]]; then
            export "$key=$value"
        else
            warn "Unknown config key: $key"
        fi
    done < "$conf_file"
}
```

### Config Priority Chain
```
CLI flags > env vars > ~/.config/movie-cli/movie-cli.conf > default.conf
```

---

## Phase 0: Research/Spike (2-4h)

### Tasks
- [ ] Test MovieBlast API with curl
- [ ] Test TMDB API search
- [ ] Test embed sources with yt-dlp
- [ ] Document in RESEARCH.md
- [ ] Decision gate for CineStream

---

## Phase 1: Core Framework (6-8h)

### Init Script (`lib/init.sh`)
```bash
set -euo pipefail
umask 077

# Trap cleanup
cleanup() {
    rm -f "$TMPFILE" 2>/dev/null
    kill "$MPV_PID" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# Globals
VERSION="0.1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/movie-cli"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/movie-cli"
DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/movie-cli"
LOG_FILE="$DATA_DIR/movie-cli.log"
HISTORY_FILE="$DATA_DIR/history.jsonl"
```

### Security (Day 1)
- [ ] `sanitize_query()` — strip metacharacters, URL-encode
- [ ] `set -euo pipefail` + `umask 077`
- [ ] Cache keys via sha256 hash
- [ ] `printf '%s\n'` not `echo -e`
- [ ] Input validation (empty, max 200 chars)
- [ ] `trap` handlers for EXIT, SIGINT, SIGHUP
- [ ] Curl timeouts (`--connect-timeout 10 --max-time 30`)
- [ ] Temp files via `mktemp -d` with trap cleanup
- [ ] Player allowlist (mpv, vlc, iina only)
- [ ] Safe config loading (key=value parser)
- [ ] `sha256_check()` portability wrapper
- [ ] Portable date function (`date -Iseconds` → fallback)

### Core Functions
- [ ] Arg parsing with 15 flags
- [ ] `check_deps()` — verify required vs optional
- [ ] `load_config()` — safe key=value parser
- [ ] Plugin loader with validation
- [ ] fzf selection with `--expect=esc,ctrl-q`
- [ ] `--search-only`, `--select N` output modes
- [ ] Persistent logging with rotation (1MB cap)
- [ ] Log viewing with `--log`
- [ ] `--debug` / `--quiet` flags

---

## Phase 2: MovieBlast Plugin (5-7h)

### Token Management (Tiered — NO Hardcoded Default)
```
1. Check $MOVIEBLAST_TOKEN env var
2. Check ~/.config/movie-cli/movieblast.conf (chmod 600)
3. If all fail → prompt user to configure
4. NEVER ship hardcoded tokens
```

### Tasks
- [ ] Plugin template (`_template.sh`)
- [ ] `movieblast.sh` with plugin contract
- [ ] Search + detail + series functions
- [ ] Response schema validation
- [ ] Token validation regex
- [ ] Token health check on startup
- [ ] Token expiry detection (401/403 → re-resolve)
- [ ] Retry with exponential backoff
- [ ] Cache search results (1h TTL)

---

## Phase 3: History System (4-6h)

### Storage (JSONL — append-only)
```bash
# ~/.local/share/movie-cli/history.jsonl
# Each line is one JSON entry — append-only, no read-all
{"v":1,"title":"Inception","plugin":"movieblast","id":"123","type":"movie",
 "ts":"2026-07-02T12:00:00","season":null,"episode":null,"progress":2712,"duration":8880}
```

### Functions
```bash
history_add()              # Append entry (echo >> file)
history_get_last()         # tail -1 | jq
history_list()             # tail -500 | jq -s 'reverse'
history_delete()           # Remove by index
history_clear()            # Truncate file
history_update_progress()  # Update progress field
history_prune()            # Keep last 500 entries
```

### Continue Watching
```bash
movie-cli -c
  → history_list | fzf
  → User picks
  → mpv --start=$progress
```

### Auto-Advance for Series
```
Episode ends → Check next ep
  → If exists: "Play next? [Y/n]"
  → If last of season: check next season
  → If last of series: "Series complete!"
```

---

## Plugin Interface Contract (v5)

### Required Metadata
```bash
PLUGIN_NAME="PluginName"
PLUGIN_VERSION="1.0.0"
PLUGIN_API_VERSION="5.0"
PLUGIN_TYPES=("movie" "series")
PLUGIN_REQUIRES=("curl" "jq")
```

### Required Functions
```bash
plugin_search(query, quality) → stdout: JSON array
plugin_get_url(id, quality) → stdout: URL string
```

### Result Schema (REQUIRED fields)
```json
{
  "id": "string (required)",
  "title": "string (required)",
  "type": "movie|series (required)",
  "year": "int|null (optional)",
  "rating": "string|null (optional)",
  "poster": "url|null (optional)"
}
```

### Error Contract
```
0 = success
1 = no results
2 = network error (retryable)
3 = auth error (not retryable)
4 = plugin error
5 = dependency missing
```

### Plugin Validation
```bash
validate_plugin() {
    local file="$1"
    source "$file" || return 1
    [[ -n "${PLUGIN_NAME:-}" ]] || return 1
    [[ -n "${PLUGIN_API_VERSION:-}" ]] || return 1
    declare -f plugin_search &>/dev/null || return 1
    declare -f plugin_get_url &>/dev/null || return 1
    # Version compatibility check
    [[ "${PLUGIN_API_VERSION%%.*}" == "${HOST_API_VERSION%%.*}" ]] || return 1
}
```

### Plugin Discovery
```bash
# Scan both directories
PLUGIN_DIRS=("$SCRIPT_DIR/plugins" "$CONF_DIR/plugins")
for dir in "${PLUGIN_DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    for plugin in "$dir"/*.sh; do
        validate_plugin "$plugin" && load_plugin "$plugin"
    done
done
```

---

## Error Handling (`lib/errors.sh`)

```bash
_log_error() { printf '[%s] %s\n' "$(date +"%Y-%m-%dT%H:%M:%S%z")" "$*" >> "$LOG_FILE" 2>/dev/null; }

die_user()    { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 1; }
die_network() { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 2; }
die_plugin()  { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 3; }
die_player()  { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 4; }
die_deps()    { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 5; }
die_auth()    { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 6; }
die_config()  { _log_error "ERROR: $*"; printf '%s\n' "[movie-cli] ERROR: $*" >&2; exit 7; }

warn()  { printf '%s\n' "[movie-cli] WARN: $*" >&2; }
info()  { [[ "${VERBOSE:-0}" == "1" ]] && printf '%s\n' "[movie-cli] $*" >&2; }
debug() { [[ "${DEBUG:-0}" == "1" ]] && printf '%s\n' "[DEBUG] $*" >&2; }

retry() {
    local max="${1:-3}" delay="${2:-2}"; shift 2
    local attempt=1
    while (( attempt <= max )); do
        if "$@"; then return 0; fi
        (( attempt == max )) && break
        warn "Attempt $attempt/$max failed, retrying in ${delay}s..."
        sleep "$delay" || return 130
        (( attempt++ )); (( delay *= 2 ))
        (( delay > 60 )) && delay=60
    done; return 1
}
```

---

## Caching Strategy (`lib/cache.sh`)

```bash
CACHE_TTL_SEARCH=3600     # 1h for search results
CACHE_TTL_HEALTH=3600     # 1h for health checks
CACHE_TTL_TOKEN=86400     # 24h for token validation
CACHE_MAX_SIZE="50M"      # Auto-prune oldest

cache_key() { printf '%s' "$1" | sha256_sum | cut -d' ' -f1; }

cache_get() {
    local key_file="$CACHE_DIR/$(cache_key "$1")"
    [[ -f "$key_file" ]] || return 1
    local age=$(( $(date +%s) - $(file_mtime "$key_file") ))
    (( age < ${2:-$CACHE_TTL_SEARCH} )) || { rm -f "$key_file"; return 1; }
    cat "$key_file"
}

cache_set() {
    local key_file="$CACHE_DIR/$(cache_key "$1")"
    mkdir -p "$CACHE_DIR"
    printf '%s' "$2" > "$key_file"
}

# Portable mtime (GNU + BSD)
file_mtime() {
    stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Portable sha256 (GNU + BSD)
sha256_sum() {
    sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null
}

cache_cleanup() { find "$CACHE_DIR" -mtime +7 -delete 2>/dev/null; }
```

---

## Security Checklist

- [ ] `sanitize_query()` — strip metacharacters, URL-encode
- [ ] `set -euo pipefail` in init.sh
- [ ] `umask 077` at startup
- [ ] Cache keys via sha256 hash
- [ ] `printf '%s\n'` not `echo -e`
- [ ] Input validation (empty, max 200 chars)
- [ ] `trap` handlers for EXIT, SIGINT, SIGHUP
- [ ] Curl timeouts + `--proto '=https'`
- [ ] Temp files via `mktemp -d` with trap cleanup
- [ ] Player name allowlist validation
- [ ] `chmod 600` on config files with tokens
- [ ] HTTPS-only for all external requests
- [ ] Safe config loading (key=value, NOT source)
- [ ] `sha256_check()` + `file_mtime()` portability wrappers
- [ ] Portable date function
- [ ] MPV IPC socket in XDG_RUNTIME_DIR (not /tmp)

---

## Testing Strategy

### Framework
bats-core + bats-assert + bats-support

### Mock Strategy
```bash
# tests/setup.sh
mock_curl() {
    local url="$1"
    case "$url" in
        *movieblast*) cat "$BATS_TEST_DIRNAME/fixtures/movieblast_search.json" ;;
        *themoviedb*) cat "$BATS_TEST_DIRNAME/fixtures/tmdb_search.json" ;;
        *error*)      return 1 ;;
        *empty*)      echo "[]" ;;
        *)            return 1 ;;
    esac
}

# Mock fzf for UI tests
mock_fzf() { echo "$1"; }
```

### Test Files
```
tests/
├── setup.sh              # Mock curl, temp dirs, helpers
├── test_core.sh          # Core functions
├── test_security.sh      # Input validation, injection
├── test_history.sh       # History functions (JSONL)
├── test_cache.sh         # Caching functions
├── test_plugins.sh       # Plugin contract validation
├── test_config.sh        # Config loading priority
└── fixtures/
    ├── movieblast_search.json
    ├── movieblast_detail.json
    ├── tmdb_search.json
    ├── tmdb_movie.json
    ├── empty.json
    └── malformed.json
```

### CI Matrix
```yaml
strategy:
  matrix:
    os: [ubuntu-latest, macos-latest]
    bash-version: [3.2, 5.1, 5.2]
```

---

## Cross-Platform Support

| Platform | Package Manager | Notes |
|----------|----------------|-------|
| Linux (Debian) | apt | Standard |
| Linux (Arch) | pacman | Standard |
| Linux (Fedora) | dnf | Added |
| macOS | brew | `brew install --cask mpv` |
| Android | pkg (Termux) | root-repo + x11-repo first |
| Windows | WSL2 | Not native, WSL only |
| FreeBSD | pkg | May need ports for mpv |

---

## CI/CD

```yaml
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: shellcheck movie-cli lib/*.sh plugins/*.sh
  
  test:
    needs: lint
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - run: bats tests/
  
  security:
    needs: [lint, test]
    runs-on: ubuntu-latest
    steps:
      - uses: gitleaks/gitleaks-action@v2
  
  release:
    needs: [lint, test, security]
    if: startsWith(github.ref, 'refs/tags/')
    steps:
      - run: tar czf movie-cli-${{ github.ref_name }}.tar.gz ...
      - run: sha256sum ... > CHECKSUM
      - uses: softprops/action-gh-release@v2
```

---

## Roadmap

| Version | Scope | Hours |
|---------|-------|-------|
| v0.1.0 | Core + MovieBlast + History | 20-28h |
| v0.2.0 | CineStream + Download | 12-18h |
| v0.3.0 | Multiple players + rofi/dmenu | 6-10h |
| v0.4.0 | Syncplay + Advanced features | 6-10h |
| v1.0.0 | Stable, documented, community-ready | 4-6h |
| **Total** | | **48-72h** |

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| v6.0 | 2026-07-02 | 15-agent review: MVP scope, safe config, JSONL history, plugin validation, no hardcoded tokens, portability wrappers |
| v5.0 | 2026-07-02 | 12-agent review: flag conflicts, result schema, download, security |
| v4.0 | 2026-07-02 | Full ani-cli feature parity |
| v3.0 | 2026-07-02 | Security hardening, plugin lifecycle |
| v2.0 | 2026-07-02 | Plugin contract, error handling |
| v1.0 | 2026-07-02 | Initial plan |
