# Changelog

All notable changes to movie-cli will be documented in this file.

## [0.1.0] - 2026-07-10

### Added
- Core search and playback pipeline
- CineStream plugin (Cinemeta + Vidlink + PlayImdb)
- MovieBlast plugin (API + HMAC signing, built-in defaults)
- Watch history (JSONL append-only)
- `--continue` to resume last watched entry
- Progress tracking via MPV IPC + Lua script
- Configurable player (mpv, vlc, iina)
- Config file with priority chain (CLI > env > config > defaults)
- SHA256-keyed TTL cache with eviction
- Cross-platform installer with auto-dependency install
- fzf/rofi/dmenu UI selection with numbered fallback
- Quality sorting and stream verification
- HMAC URL signing for MovieBlast (re-signs at playback)
- Plugin API v5 with template
- bats-core test suite (53 tests)
- Install script for Linux, macOS, Termux
- Uninstall script
