# Changelog

All notable changes to movie-cli will be documented in this file.

## [Unreleased]

### Added
- **4KHDHub plugin** — 4K movies/series from 4khdhub.one via the HubCloud/HubDrive mirror chain. Search, movie/series playback, season/episode listing, and a full resolver walk (hubcloud drive → gamerxyt resolver → workers.dev / fsl-buckets / pixel→googleusercontent / pixeldrain direct links). Reverse-engineered from the CloudStream FourKHDHub extension.
- **HDhub4u plugin** — Hindi/English movies from new4.hdhub4u.cl. Typesense JSON search API (GET with query params; POST is 403'd), detail pages resolved through hubdrive → hubcloud → direct .mkv. Series season posts are shortener-gated (gadgetsweb) and report no resolvable links.
- **verify_streams Range-ignore fix** — servers that ignore `Range:` (fsl-buckets, googleusercontent) previously timed out in the status probe and were falsely rejected as dead. The probe now uses `--max-filesize` and accepts a 2xx code received before abort, so whole-file-streaming video hosts pass verification.
- Tests for both new plugins (bats, 12 cases).

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
