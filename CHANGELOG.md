# Changelog

All notable changes to movie-cli will be documented in this file.

## [Unreleased]

### Fixed
- **Plugin discovery SIGPIPE race** — `validate_plugin` piped the whole plugin file into `grep -q`; grep exits on the first match while printf is still writing the remaining 20-30KB → SIGPIPE (141) → pipefail → the plugin was silently dropped from `--list-plugins` and search-all, intermittently and per-plugin (bigger files raced more). Now greps the file directly. A/B on a 50k-line synthetic plugin: 0/100 vs 100/100 failures.
- **Pixel-resolver temp-file race** — `_m4u_resolve_pixel`, `_df_resolve_pixel`, `_h4u_resolve_pixel`, `_4kh_resolve_pixel` wrote parallel resolution output to `/tmp/<name>_pixel_body.$$`; `$$` is the parent PID shared by every `( ... ) &` subshell, so concurrent `curl -o` writes raced on one file and dropped streams. All four now use `mktemp`.
- **dflinks TLD rotation** — dudefilms pages now link `dflinks.cc` archives (rotation source already points at dudefilms.garden), but the plugin only matched `dflinks.online` → every movie/series failed with "No archive links". Now matches any `dflinks.[a-z]+`; same broadening for m4ulinks.
- **vegamovies gpdl2 routing** — `*hubcloud.cx*` in the V-Cloud family case matched before `*gpdl*.hubcloud.cx*`, making the pixel-redirect branch dead code (shellcheck SC2221/SC2222); gpdl2 links were handed to the VCloud resolver and dropped. Dispatch order fixed.
- **hdhub4u episode labels** — `plugin_list_episodes` accepted `E1` and `E01`, but `plugin_get_url` only matched zero-padded `E01`; unpadded pages resolved to nothing. Both now accepted.
- **SIGPIPE races in page-size grep checks** — vegamovies `Episodes:` label checks (3 sites) and hdhub4u `Season N` extraction used `printf | grep -q` / `grep | head -1` on full pages; same early-exit race intermittently degraded episodes to season-packs. Now here-strings / consume-then-slice.
- **movieblast sign URL with existing query params** — `_mb_sign_url` appended `?verify=` to URLs that already had a query string (`...?token=x?verify=...`), corrupting the stream URL. Now appends `&verify=` when a query exists.
- **movieblast get_url on missing sources** — `qualities_json` was unset when a media item had neither `.seasons` nor `.videos`, hitting a `set -u` unbound-variable abort instead of the clean "No video sources" die.
- **history progress update could abort playback** — `history_update_progress` returns 1 when jq fails on a corrupt history line, and the three call sites under `set -e` let that kill the CLI *after* playback succeeded. Call sites now tolerate failure.
- **confirm() hang without a tty** — `read </dev/tty` blocked forever in piped/scripted runs (e.g. `-D` in CI). Declines immediately when no tty.
- **dudefilms search returned nothing since 9a21514** — the Cinemeta-fallback commit wrapped the parser's direct-print pipeline in a variable but never added the trailing `printf`, and never added the fallback block it claimed; every dudefilms search was silently empty. Parser extracted to `_df_parse_search_page`, print restored, fallback implemented to match 4khdhub. (Only dudefilms was affected — hdhub4u/movieblast/4khdhub all print correctly.)
- **dudefilms episode extraction SIGPIPE** — `_df_resolve_archive_episode` ran page-sized archive content through `grep | head -1`; multi-mirror pages (several blocks per episode label) SIGPIPEd grep under pipefail → intermittent misses. Consume-then-slice with `awk NR==1`.
- **update.sh release-mode rm guard** — `${share_dir:?}` on the `rm -rf` swap, matching install.sh's convention (SC2115).
- **config env precedence for booleans** — `VERBOSE=0`/`DEBUG=0`/`QUIET=0`/`NO_COLOR=0` exports were ignored (markers only fired on `== "1"`), so a config-file "1" won against an explicit env "0" — violating CLI > env > config > defaults. Markers now use `${VAR+x}`.
- **retry() silent no-op** — `retry 3 mycmd` (or `retry 3 1` with no command) shifted the command away and returned 0 without running anything. max/delay must now be numeric and a command must remain; bad args warn + return 1.
- **history corrupt-line coverage** — bats regression tests for `history_update_progress` failing cleanly on a non-JSON line and the `(( end_pos > 0 )) && ... || true` call-site pattern surviving under `set -e`.
- **vegamovies episode-pairing boundary** — the family-preference scan took the *next* preferred-family link after an episode label, unbounded; an episode block lacking vcloud/fastdl grabbed the next block's link (E1 paired with E2's stream). Search is now bounded by the following label. (Deterministic fixture: old `E1→vcloud/j2`, new `E1→dgdrive/FILE1`.)
- **cinestream search ranking** — every title merely starting with the query word scored the same 90, so Cinemeta's catalog order won and "pushpa" surfaced Pushpavalli/Pushpanjali above the actual Pushpa films (ranked 11-12). First-word equality now scores 95; live "pushpa" puts Pushpa Impossible/Rampage/Rule/Rise in the top 5 with Pushpavalli below the first-word group. Salaar/KGF rankings unchanged.

### Added
- **4KHDHub plugin** — 4K movies/series from 4khdhub.one via the HubCloud/HubDrive mirror chain. Search, movie/series playback, season/episode listing, and a full resolver walk (hubcloud drive → gamerxyt resolver → workers.dev / fsl-buckets / pixel→googleusercontent / pixeldrain direct links). Reverse-engineered from the CloudStream FourKHDHub extension.
- **HDhub4u plugin** — Hindi/English movies from new4.hdhub4u.cl. Typesense JSON search API (GET with query params; POST is 403'd), detail pages resolved through hubdrive → hubcloud → direct .mkv. Series season posts are shortener-gated (gadgetsweb) and report no resolvable links.
- **verify_streams Range-ignore fix** — servers that ignore `Range:` (fsl-buckets, googleusercontent) previously timed out in the status probe and were falsely rejected as dead. The probe now uses `--max-filesize` and accepts a 2xx code received before abort, so whole-file-streaming video hosts pass verification.
- Tests for both new plugins (bats, 12 cases).
- **Regression tests** for the discovery SIGPIPE race, movieblast signing/no-source paths, hdhub4u episode-label routing, and vegamovies gpdl2 routing (offline stub-based; +12 bats cases).

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
