# movie-cli

[![CI](https://github.com/sai4794/movie-cli/actions/workflows/ci.yml/badge.svg)](https://github.com/sai4794/movie-cli/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![ShellCheck](https://img.shields.io/badge/ShellCheck-passing-brightgreen)](https://www.shellcheck.net/)
[![Version](https://img.shields.io/badge/version-0.1.0-blue)](https://github.com/sai4794/movie-cli/releases)

Terminal-based movie/series search and play tool. Inspired by [ani-cli](https://github.com/pystardust/ani-cli) for anime.

## Demo

```
$ movie-cli "inception"
Fetching results...
? Select:
  1. Inception (2010) [CineStream]
  2. Inception [MovieBlast]
> 1

Playing: Inception (2010)
```

## Features

- **Search by name** — find movies and series instantly
- **Play in mpv** — high-quality video playback with resume
- **Watch history** — log and continue watching (`-c`)
- **Plugin system** — extend with new sources
- **Cross-platform** — Linux, macOS, Android (Termux)
- **Zero-config** — works out of the box with CineStream

## Installation

### Quick Install (Linux/macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/sai4794/movie-cli/main/install.sh | bash
```

### Manual Install

```bash
git clone https://github.com/sai4794/movie-cli.git
cd movie-cli
chmod +x movie-cli
./movie-cli --help
```

### Requirements

| Dependency | Required | Purpose |
|-----------|----------|---------|
| `curl` | Yes | HTTP requests |
| `jq` | Yes | JSON processing |
| `mpv` | Yes | Video player (vlc/iina also work) |
| `fzf` | No | Fuzzy selection (falls back to numbered list) |
| `python3` | Yes | Regex extraction, embed resolution |
| `openssl` | Yes | MovieBlast URL signing |
| `socat` | Yes | MPV progress tracking |

The install script auto-installs missing dependencies via your package manager (apt/dnf/pacman/brew/termux).

## Usage

```bash
# Interactive mode
movie-cli

# Direct search
movie-cli "inception"

# Specific quality
movie-cli -q 1080 "the matrix"

# Continue watching
movie-cli -c

# View history
movie-cli --log

# Auto-select 3rd result
movie-cli --select 3 "inception"

# Search only (no playback)
movie-cli -s "inception"
```

### Command Reference

| Flag | Description |
|------|-------------|
| `-p, --plugin NAME` | Use specific plugin (default: auto) |
| `-q, --quality LEVEL` | Min quality: 480, 720, 1080 (default: 720) |
| `-c, --continue` | Continue watching last entry |
| `-l, --log` | View watch history |
| `-D, --delete-history` | Delete watch history |
| `-s, --search-only` | Output results without playing |
| `-S, --select N` | Auto-select Nth result |
| `--no-detach` | Don't detach player |
| `--list-plugins` | List available plugins |
| `--check-deps` | Verify all dependencies |
| `--no-cache` | Bypass cache |
| `--clear-cache` | Clear all cached data |
| `--debug` | Enable debug logging |
| `--quiet` | Suppress non-essential output |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

## Configuration

Config file: `~/.config/movie-cli/movie-cli.conf`

```ini
# Player: mpv, vlc, iina
PLAYER=mpv

# Default quality: 480, 720, 1080
QUALITY=720

# Plugin: auto (try all), or specific name
PLUGIN=auto

# Verbose/debug output (0 or 1)
VERBOSE=0
DEBUG=0
```

Priority: CLI flags > env vars > config file > built-in defaults.

## Plugins

Plugins extend movie-cli with new content sources.

### Available

| Plugin | Source | Auth | Content |
|--------|--------|------|---------|
| CineStream | Cinemeta + Vidlink | None | Movies + Series |
| MovieBlast | MovieBlast API | Built-in | Movies + Series |

### Creating a Plugin

1. Copy `plugins/_template.sh`
2. Implement `plugin_search()` and `plugin_get_url()`
3. Place in `plugins/` or `~/.config/movie-cli/plugins/`

```bash
# plugin_search returns JSON array:
[{"id":"123","title":"Movie (2020)","type":"movie"}]

# plugin_get_url returns JSON array:
[{"quality":"1080","url":"https://...","size":"unknown","provider":"Name"}]
```

## Architecture

```
movie-cli                  # Main entry point (arg parsing, pipeline)
├── lib/
│   ├── init.sh            # Globals, traps, portability wrappers
│   ├── errors.sh          # Error handling, retry, safe curl
│   ├── config.sh          # Config loading (key=value parser)
│   ├── cache.sh           # SHA256-keyed TTL cache
│   ├── ui.sh              # fzf/rofi/dmenu selection, spinner
│   ├── player.sh          # mpv/vlc/iina wrapper + IPC
│   └── history.sh         # JSONL watch history
├── plugins/
│   ├── cinestream.sh      # Cinemeta + Vidlink (zero-config)
│   ├── movieblast.sh      # MovieBlast API (built-in creds)
│   └── _template.sh       # Plugin template
├── config/
│   └── default.conf       # Default configuration
└── tests/                 # bats-core test suite
```

## Development

```bash
# Run all tests
tests/bats/bin/bats tests/

# Run specific test
tests/bats/bin/bats tests/test_core.sh

# Lint with shellcheck
shellcheck movie-cli lib/*.sh plugins/*.sh
```

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| Linux (Debian/Ubuntu) | ✅ | Full support |
| Linux (Fedora) | ✅ | Full support |
| Linux (Arch) | ✅ | Full support |
| macOS | ✅ | Uses sed -E, shasum |
| Android (Termux) | ✅ | pkg install |
| Windows (WSL2) | ✅ | WSL only |

## License

[MIT](LICENSE)

## Credits

- [ani-cli](https://github.com/pystardust/ani-cli) — inspiration
- [Cinemeta](https://www.stremio.com) — metadata provider
- [Vidlink](https://vidlink.pro) — stream resolver
- [Cloudstream MovieBlast](https://cloudstream.miraheze.org) — MovieBlast extension source
