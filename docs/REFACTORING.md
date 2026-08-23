# movie-cli — Architecture & Refactoring Report

Status: **implemented** (all items below are in the tree; 138/138 tests pass,
ShellCheck clean). This document records the reverse-engineered architecture,
the problems found, what was refactored, and what remains as follow-up work.

---

## 1. Clean architecture breakdown

```
movie-cli            entrypoint: arg parsing, dependency check, orchestration
├── lib/init.sh      globals, traps/cleanup, portability wrappers, profiler
├── lib/errors.sh    logger, die_* exit codes (1=user 2=net 3=plugin 4=player
│                    5=deps), retry with backoff, hardened api_curl
├── lib/config.sh    key=value config loader; priority CLI > env > file > default
├── lib/cache.sh     SHA256-keyed file cache, TTL via mtime, LRU eviction
├── lib/json.sh      NEW — batch JSON extraction (one jq pass per list)
├── lib/ui.sh        colors, spinner, fzf/rofi/dmenu/numbered selection
├── lib/player.sh    mpv/vlc/iina/Termux-intent launchers, IPC progress
├── lib/history.sh   JSONL watch history (append-only + progress updates)
├── lib/update.sh    self-update (git pull or release tarball swap)
├── lib/cinemeta.sh  Cinemeta catalog query + shared search-fallback orchestrator
├── lib/pluginsdk.sh NEW — shared plugin runtime (see §4)
└── plugins/*.sh     source plugins implementing the API v5 contract:
                     plugin_search / plugin_get_url / plugin_list_seasons /
                     plugin_list_episodes / plugin_health / plugin_info
```

### Data flow

1. `main()` — config load → immediate-exit flags → deps check → arg parse.
2. `search_and_play()`:
   - `_search_results()` — cache lookup → parallel all-plugin search
     (each plugin sourced in a throwaway subshell writing JSON fragments to a
     tmpdir) or single-plugin search (`run_plugin` option guard) → merge →
     cache store.
   - One `jq` pass fills parallel arrays (`json_fill_arrays`).
   - NAV LOOP (title → season → episode → playback) with `<- Back`
     sentinels at every level; back-navigation semantics preserved exactly.
3. Resolution pipeline: `plugin_get_url → sort_streams (quality rank) →
   verify_streams (bounded-concurrency probe pool)` → `select_stream`.
4. `play_with_fallback()` — play selected mirror → on failure walk remaining
   mirrors → re-resolve fresh once → give up. Exit 0/130 from the player is
   success (user quit/interrupt).
5. Progress persisted for `--continue` via mpv IPC/pos-file.

### Plugin contract (API v5)

Plugins are *sourced* into the shell. Metadata variables (`PLUGIN_NAME`,
`PLUGIN_API_VERSION="5"`, …) are grep-validated by `validate_plugin()`;
only one plugin's functions are resident at a time (the host unsets the
previous one before sourcing the next). Results are JSON arrays on stdout;
every item carries `.id/.title/.type/.plugin`.

---

## 2. Critical problem areas (found)

### Bad architecture decisions
- **430-line god function** (`search_and_play`) mixing caching, merging,
  parsing, UI and three levels of nested nav loops.
- **Plugin isolation by convention only**: plugins run in the host shell;
  correctness depended on every plugin defining the full function set.
- **Hidden dynamic-scope coupling**: `play_with_fallback` read the caller's
  `local quality` through bash dynamic scoping.
- **Selection by display-string equality** in the title menu (duplicate
  titles would collide — latent bug, preserved as-is by design).

### Correctness hazards
- **`set +euo pipefail` leak**: five plugins disabled errexit/nounset/
  pipefail inside their Cinemeta fallbacks believing it was subshell-scoped.
  In single-plugin paths it ran in the main shell and stayed off for the
  rest of the process. The comment claiming safety was wrong.
- **Inconsistent failure contracts**: some plugins returned `[]`, some
  printed nothing, some returned non-zero, and `die_plugin` inside a plugin
  killed the whole CLI in single-plugin paths.

### Duplication (before)
| Cluster | Copies |
|---|---|
| Config-file parser | 6 |
| Domain-rotation loader | 5 |
| Stream-candidate filter | 5 |
| Quality extractor (2 vocabularies) | 5 |
| Stream-JSON builder (+python encoder) | 5+4 |
| pixel/gpdl resolver | 4 |
| Resolver-page walk | 4 |
| hubcloud drive resolver | 4 |
| pixeldrain normalization | 7 |
| Cinemeta fallback loop (lib helpers dead!) | 4 hand-rolled |
| Season-position-walk python | 7 |
| Parallel fan-out skeleton | 7 |

### Performance bottlenecks
- One `jq` fork per field/row/item (e.g. 3 forks × N results just to build
  selection menus; 1 fork per episode when listing).
- python3+jq forked **per resolved stream URL** (~40 processes for 20 links).
- Unbounded parallelism in `verify_streams` (2 curls × N streams).
- Serial Cinemeta fallback loops; castle refetching its security key per call
  (left as follow-up — see §6).
- Same domains.json fetched 4× under different cache keys (now still 1 fetch
  per plugin key/day; shared-key dedup left as follow-up).

### Scalability risks
- Unbounded worker pools (fixed: capped at `VERIFY_MAX_JOBS=16`).
- O(n²)-ish jq-append loops for season/episode lists (fixed: batched JSONL).
- History rewrite per update is O(file) — acceptable ≤500 entries (pruned).

### Maintainability issues
- Dead code: `cinemeta_wp_fallback` / `cinemeta_wp_parse` (zero callers)
  while four plugins hand-rolled equivalent logic.
- Test harness glob picked up 4 non-bats live-network scripts → `bats
  tests/*.sh` failed outright (CI would too).
- Five User-Agent strings, inconsistent error contracts, misindented
  nav-loop body (lines ~450-770 of old entrypoint).

---

## 3. What was done (no functional change)

### Host
- `run_plugin` wrapper snapshots/restores `set -o` around every plugin call
  that executes in the main shell — plugins may relax options during their
  own execution but can no longer disable strict mode globally.
- `verify_streams`: probe extracted to `_verify_stream_probe`; worker pool
  bounded (`VERIFY_MAX_JOBS`, default 16). Same probes, same output messages.
- Decomposed `search_and_play`: `_tag_results`, `_search_all_plugins`,
  `_search_results`, `resolve_streams_for`, `collect_streams`,
  `_save_playback_progress`. Nav-loop control flow kept byte-for-byte (it
  was hardened through 7 fix commits; no behavioral risk taken).
- `play_with_fallback` takes quality explicitly (dynamic-scoping removed);
  all three call sites updated.
- All array-parsing blocks replaced with single-pass `json_fill_arrays`.
- Indentation normalized throughout the entrypoint.

### Shared runtime
- `lib/pluginsdk.sh` (new): `sdk_conf_load`, `sdk_http`/`sdk_fetch`,
  `sdk_rotate_domain`, `sdk_is_stream_candidate` (data-driven globs),
  `sdk_quality_suffix`/`sdk_quality_token` (both vocabularies kept on
  purpose — they surface verbatim in stream labels),
  `sdk_stream_json[_encoded]`, `sdk_normalize_pixeldrain`,
  `sdk_resolve_pixel/drive/resolver` (per-site pixel routing passed as
  data), `sdk_fanout` (parallel map + merge, `SDK_FANOUT_MERGE` overridable).
  SDK never calls `die_*` — failures are empty output / non-zero return.
- `lib/json.sh` (new): `json_count`, `json_rows` (one-pass TSV),
  `json_objects`, `json_fill_arrays`.
- `lib/cinemeta.sh`: dead functions deleted;
  `cinemeta_search_fallback QUERY EXISTING RESEARCH_FN` replaces the four
  hand-rolled loops (one metadata extraction pass instead of three forks
  per row; pipefail-hardened so plugins no longer need `set +euo`).

### Plugins migrated onto the SDK
vegamovies, movies4u, hdhub4u, 4khdhub, dudefilms. Each keeps only its
site-specific data (URLs, host lists, parsers); candidate policies and
reject lists are now declared as data strings next to the config defaults.
Per-site differences were preserved deliberately:
- movies4u keeps its bare-number quality vocabulary and does NOT
  percent-encode stream URLs; resolver accepts all anchors (btn_only=0) and
  routes any `*gpdl*` to the redirector.
- hdhub4u/4khdhub keep token-flavor quality labels and btn-only resolvers.
- vegamovies keeps its bespoke vcloud/nexdrive chain (not shared code).
- castle, cinestream, movieblast were left untouched (they share almost no
  scrape machinery; churn would add risk without dedup value).

### Tests
- 4 non-bats live-network scripts moved to `tests/manual/` (still runnable:
  `bash tests/manual/profile_cinestream.sh`). `bats tests/*.sh` now works,
  matching CI.
- Suite: **138 passing, 0 failing** (live-network tests included; occasional
  site-side flakes self-skip where guarded).

---

## 4. Refactoring strategies used (and why)

1. **Characterization-first**: ran the full suite before touching anything;
   live tests double as regression nets for resolver chains.
2. **Strangler pattern for duplication**: new SDK introduced alongside;
   plugins migrated one at a time with their test file re-run immediately
   (caught two real regressions during migration: lost `die_plugin` on
   empty fan-out merge; Typesense fallback param-set drift).
3. **Data over control flow**: per-plugin `case` ladders became declared
   glob strings consumed by one algorithm — behavior identical because
   patterns moved verbatim.
4. **Preserve battle-tested control flow**: nav-loop `continue`-depth
   semantics kept intact rather than rewritten into a state machine.
5. **Guard rails**: option-state snapshotting instead of auditing every
   plugin for `set +e`; bounded pools instead of trusting input sizes.

## 5. Verification checklist

- [x] `bash -n` on entrypoint, libs, plugins, install scripts
- [x] ShellCheck `--severity=warning --exclude=SC1090,SC2034,SC2206` clean
      (same flags as CI)
- [x] Full bats suite green across multiple runs
- [x] Live end-to-end checks: `-s "inception"` all-plugin search works
- [x] No changes to CLI flags, exit codes, output formats, or cache keys

## 6. Recommended follow-ups (not done — behavioral or larger risk)

1. **Index-based result selection** to fix the duplicate-title collision
   (changes observable selection behavior; needs a UX decision).
2. **Nav-loop state machine** (functions returning symbolic next-states)
   to remove `continue N` coupling — worth doing with interactive tests
   (expect/tmux) since none exist today.
3. **Shared domains.json fetch** across phisher98-based plugins (single
   cache key, per-plugin view) — changes cache contents only.
4. **castle.apk security-key caching** (currently one extra HTTP round trip
   per API request) — touches a private API protocol; needs live testing.
5. **Unify quality vocabularies** ("2160p" vs "4K") behind one canonical
   label set — user-visible change, needs a release note.
6. **Interactive-flow tests** (tmux-driven) for season/episode/back-nav.
7. Consider `mkfifo`/coproc or a tiny Python helper process to replace
   per-item jq/python forks in hot paths if profiling shows it matters.
