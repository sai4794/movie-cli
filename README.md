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
  1. Inception (2010)
  2. Inception
> 1

Playing: Inception (2010)
```

## Features

- **Search by name** — find movies and series instantly
- **Play in mpv** — high-quality video playback with resume
- **Watch history** — log and continue watching (`-c`)
- **Cross-platform** — Linux, macOS, Android (Termux)
- **Zero-config** — works out of the box

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
| `openssl` | Yes | URL signing |
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
| `-q, --quality LEVEL` | Min quality: 480, 720, 1080 (default: 720) |
| `-c, --continue` | Continue watching last entry |
| `-l, --log` | View watch history |
| `-D, --delete-history` | Delete watch history |
| `-s, --search-only` | Output results without playing |
| `-S, --select N` | Auto-select Nth result |
| `--no-detach` | Don't detach player |
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

# Verbose/debug output (0 or 1)
VERBOSE=0
DEBUG=0
```

Priority: CLI flags > env vars > config file > built-in defaults.

## License

[MIT](LICENSE)

## Credits

- [ani-cli](https://github.com/pystardust/ani-cli) — inspiration
- [Cinemeta](https://www.stremio.com) — metadata
- [Vidlink](https://vidlink.pro) — stream resolver
