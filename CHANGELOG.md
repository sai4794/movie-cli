# Changelog

All notable changes to movie-cli will be documented in this file.

## [0.1.0] - 2026-07-10

### Added
- Core search and playback pipeline
- Watch history (JSONL append-only)
- `--continue` to resume last watched entry
- Progress tracking via MPV IPC + Lua script
- Configurable player (mpv, vlc, iina)
- Config file with priority chain (CLI > env > config > defaults)
- SHA256-keyed TTL cache with eviction
- Cross-platform installer with auto-dependency install
- fzf/rofi/dmenu UI selection with numbered fallback
- Quality sorting and stream verification
- bats-core test suite (55 tests)
- Install script for Linux, macOS, Termux
- Uninstall script
