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
| `mpv` | Manual | Video player (vlc/iina also work) — install separately |
| `fzf` | No | Fuzzy selection (falls back to numbered list) |
| `python3` | Yes | Regex extraction, embed resolution |
| `openssl` | Yes | URL signing |
| `socat` | Yes | MPV progress tracking |

The install script auto-installs core dependencies (curl, jq, python3, openssl, socat, fzf). Media players (mpv/vlc/iina) must be installed manually.

## Supported Platforms

| Platform | Status | Package Manager | Notes |
|----------|--------|-----------------|-------|
| Linux (Debian/Ubuntu) | ✅ Supported | apt | Full support |
| Linux (Fedora) | ✅ Supported | dnf | Full support |
| Linux (Arch) | ✅ Supported | pacman | Full support |
| macOS | ✅ Supported | brew | Requires Bash 4+ (installer auto-upgrades) |
| Android (Termux) | ✅ Supported | pkg | Install from F-Droid or termux.dev |

### Platform-Specific Notes

**Linux**
- All major distributions supported (Debian, Ubuntu, Fedora, Arch, etc.)
- Uses `python3` for regex extraction
- Install mpv: `sudo apt install mpv` or `sudo dnf install mpv`

**macOS**
- Requires Bash 4+ (macOS ships with Bash 3.2)
- The installer will automatically upgrade Bash via Homebrew if needed
- Uses `python3` for regex extraction
- Install mpv: `brew install mpv`

**Android (Termux)**
- Install from Play Store
- Uses `python` instead of `python3`
- Uses `openssl-tool` instead of `openssl`
- Install mpv from Play Store

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

## Inspiration

- [ani-cli](https://github.com/pystardust/ani-cli) — inspiration

---

## ⚠️ Safety Notice

`movie-cli` provides access to streams exposed by third-party plugins and services. These sources are not operated, controlled, or verified by this project.

Before using any stream, users should be aware of the following:

- Third-party streams may contain malicious, misleading, or unsafe content.
- Streams may expose your IP address or other network information to third-party servers.
- The availability, quality, security, and safety of streams cannot be guaranteed.
- Some streaming sources may violate the laws, regulations, copyrights, or terms of service applicable in your country or region.
- Users are solely responsible for ensuring that their use of any streaming source complies with applicable laws.
- Use of third-party streaming sources is entirely at your own risk.

## Content Disclaimer

`movie-cli` does not host, upload, store, distribute, or control any media files, streaming servers, or copyrighted content.

The project only provides a command-line interface capable of interacting with independent third-party plugins and services.

## Third-Party Plugins

Plugins included with or developed for `movie-cli` communicate with independent third-party services.

These services may:

- Change without notice
- Become unavailable
- Return inaccurate information
- Stop working completely

The developers of `movie-cli` do not control or guarantee the availability, reliability, legality, or accuracy of any third-party service.

## Privacy Notice

When using third-party plugins, your device communicates directly with external servers.

Those services may receive information such as:

- Your IP address
- HTTP request headers
- Network metadata
- Other information normally transmitted during network requests

Review the privacy practices of any service you choose to use.

## User Responsibility

By using `movie-cli`, you acknowledge that you are solely responsible for:

- Complying with applicable laws and regulations.
- Respecting copyrights and intellectual property rights.
- Following the terms of service of any third-party service you access.
- Determining whether the content you access is lawful in your jurisdiction.

## Trademark Notice

All product names, service names, trademarks, logos, and registered trademarks mentioned by this project belong to their respective owners.

Their use is for identification purposes only and does not imply endorsement, sponsorship, partnership, or affiliation.

## Final Disclaimer

> The developers of `movie-cli` do not host, own, distribute, control, or endorse any media content or streaming servers. All media content is obtained from independent third-party sources. Users assume full responsibility for how they use this software and for complying with all applicable laws, regulations, and third-party terms of service.
