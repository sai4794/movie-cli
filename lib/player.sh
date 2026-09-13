#!/usr/bin/env bash
# player.sh — Video player wrapper (mpv, vlc, iina)
# Source AFTER errors.sh

# ═══════════════════════════════════════════════════════════════
# Player Allowlist
# ═══════════════════════════════════════════════════════════════
_VALID_PLAYERS="mpv vlc iina"

validate_player() {
    local player="$1"
    if [[ " $_VALID_PLAYERS " != *" $player "* ]]; then
        die_player "Invalid player: $player (allowed: $_VALID_PLAYERS)"
    fi
    # ponytail: Android uses mpv-android via Play Store + intent launch,
    # not a CLI binary in $PATH. Same for iOS (external-app hand-off).
    # Skip binary check on both.
    if [[ "$_MC_PLATFORM" == "termux" || "$_MC_PLATFORM" == "ios" ]]; then
        return 0
    fi
    if ! command -v "$player" &>/dev/null; then
        die_deps "Player not found: $player"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Android Intent Launch
# ═══════════════════════════════════════════════════════════════

# ponytail: MIME type for Android intents. Servers often return
# application/octet-stream which routes to Chrome. -t video/*
# forces Android to match video players.
ANDROID_MIME="${ANDROID_MIME:-video/*}"

_android_escape_uri() {
    local raw="$1"

    # Android intents reject or mangle raw spaces/JSON chars in stream URLs.
    # Keep URL delimiters and existing percent-escapes intact.
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=":/?&=%+-._~"))' "$raw" 2>/dev/null || printf '%s\n' "$raw"
}

# ponytail: resolve 302 redirects before hand-off — mobile players don't
# all follow them, but terminal mpv does. Proxy URLs (p.111477.xyz, etc.)
# 302 to CDN. Use the raw URL (not yet URI-encoded) so curl sees the real
# endpoint. Pass Referer if required — some CDNs validate it even on HEAD
# requests. Prints the effective URL; echoes the input back unchanged on
# failure or when no redirect happened.
_mc_resolve_redirect() {
    local url="$1"
    local referrer="${2:-}"
    local -a redirect_headers=()
    [[ -n "$referrer" ]] && redirect_headers+=(-H "Referer: $referrer")
    local resolved_url
    # -4 first (IPv6-broken networks hang otherwise); retry without it so
    # IPv6-only hosts still resolve.
    resolved_url=$(curl -4 -g -sL --range 0-0 --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{url_effective}' "${redirect_headers[@]}" "$url" 2>/dev/null)
    if [[ -z "$resolved_url" ]]; then
        resolved_url=$(curl -g -sL --range 0-0 --connect-timeout 5 --max-time 15 \
            -o /dev/null -w '%{url_effective}' "${redirect_headers[@]}" "$url" 2>/dev/null || true)
    fi
    if [[ -n "$resolved_url" && "$resolved_url" != "$url" ]]; then
        debug "Redirect resolved: $url -> $resolved_url"
        printf '%s' "$resolved_url"
    else
        printf '%s' "$url"
    fi
}

# ponytail: try launching URL via Android implicit VIEW intent.
# No hardcoded activities — Android resolves the best handler.
# Returns 0 on success.
_android_launch() {
    local url="$1"
    local wait_for_exit="${2:-0}"
    local start_time="${3:-}"
    local referrer="${4:-}"
    local _am_rc=0 _am_err=""

    # Resolve redirects first, then URI-encode exactly once.
    local final_url
    final_url=$(_mc_resolve_redirect "$url" "$referrer")

    # ponytail: URI-encode exactly once, after all redirects are resolved.
    local intent_url
    intent_url=$(_android_escape_uri "$final_url")
    if [[ "$intent_url" != "$final_url" ]]; then
        debug "Android intent URI encoded"
    fi

    local am_flags=(-a android.intent.action.VIEW -d "$intent_url" -t "$ANDROID_MIME")
    # ponytail: -W blocks until mpv-android exits. Needed for series
    # playback (NO_DETACH=1) so script waits for player to finish.
    [[ "$wait_for_exit" == "1" ]] && am_flags+=(-W)
    # ponytail: --ei position is mpv-android's verified resume extra (milliseconds)
    # Source: MPVActivity.kt parseIntentExtras() — extras.getInt("position", 0) / 1000
    # Integer arithmetic: mpv time-pos can be fractional ("2712.5"); a
    # float breaks $(( )) with a syntax error and fails the launch.
    [[ -n "$start_time" ]] && am_flags+=(--ei position $((${start_time%.*} * 1000)))
    # ponytail: pass HTTP Referer to mpv-android via Intent extras.
    # mpv-android MPVActivity.kt reads extras.getString("referrer") in parseIntentExtras().
    [[ -n "$referrer" ]] && am_flags+=(--es referrer "$referrer")

    debug "am start flags: ${am_flags[*]}"

    # ponytail: strip env vars that break Termux's am wrapper
    _am_err=$(env -u DEBUG -u VERBOSE am start "${am_flags[@]}" 2>&1) || _am_rc=$?

    debug "am start exit: $_am_rc"
    [[ -n "$_am_err" ]] && debug "am start output: $_am_err"

    if [[ "$_am_rc" -eq 0 ]]; then
        debug "Android intent launched successfully"
        return 0
    fi

    warn "Android intent failed (exit $_am_rc)"
    [[ -n "$_am_err" ]] && warn "am output: $_am_err"
    return "$_am_rc"
}

# ═══════════════════════════════════════════════════════════════
# iOS URL Launch
# ═══════════════════════════════════════════════════════════════

# ponytail: iOS sandboxes every app — one app cannot spawn another as a
# child process, so there is no mpv/vlc binary to exec and no desktop
# process model. The only hand-off mechanism is a URL opener exposed by
# the terminal host itself. Known openers: Blink Shell `openurl`/`open`,
# a-Shell `open` (a-Shell can't run bash at all, listed for completeness).
# iSH ships BusyBox's `open` (file opener, NOT a URL opener) — the helper
# below detects and excludes it.  Set MOVIE_CLI_OPENER=<cmd> if your
# setup provides a real URL opener.
#
# Hard platform limits (NOT fixable in-script, mirrors of Android's -W):
#   * fire-and-forget: no opener API reports playback exit status, so
#     NO_DETACH blocking is impossible on iOS.
#   * start_time/referrer cannot be passed as intent extras; resume and
#     CDN referer workarounds are best-effort (VLC scheme ignores them).

# Detect whether a command is a real iOS URL opener (not BusyBox `open`).
# BusyBox's open opens files; passing it a URL silently does nothing.
_ios_is_url_opener() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null || return 1
    # Blink Shell `openurl` — always a URL opener.
    [[ "$cmd" == "openurl" ]] && return 0
    # Check output of the binary for BusyBox signature.
    local _v
    _v=$("$cmd" --help 2>&1 | head -3) || true
    [[ "$_v" == *"BusyBox"* ]] && return 1
    # a-Shell's `open` — also a URL opener (no BusyBox in output).
    return 0
}

# Fallback: open a URL in VLC via its built-in HTTP interface.
# VLC for iOS exposes http://localhost:8080/requests/status.xml when the
# "HTTP remote control" toggle is enabled in Settings.  The /browse endpoint
# accepts a URI to play.
_ios_vlc_http_open() {
    local url="$1"
    local vlc_port="${VLC_HTTP_PORT:-8080}"
    local vlc_pass="${VLC_HTTP_PASSWORD:-}"  # default: no password
    # Array form: a password with spaces/globs must not word-split, and
    # the port is validated so `8080@evil/` userinfo shapes cannot redirect.
    [[ "$vlc_port" =~ ^[0-9]{1,5}$ ]] || vlc_port=8080
    local -a auth=()
    [[ -n "$vlc_pass" ]] && auth=(-u ":$vlc_pass")
    # /browse endpoint opens a URI in VLC's player.
    local _code
    _code=$(curl -s --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "${auth[@]}" \
        "http://localhost:${vlc_port}/requests/status.xml?command=adddirectory&uri=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=':/?&=%+-._~'))" "$url" 2>/dev/null)" 2>/dev/null) || true
    [[ "$_code" == "200" ]]
}

_ios_launch() {
    local url="$1"
    local start_time="${2:-}"
    local referrer="${3:-}"

    # Resolve 302 redirects first (same rationale as Android: the handler
    # receives the literal URL we pass).
    local final_url
    final_url=$(_mc_resolve_redirect "$url" "$referrer")

    # VLC-iOS registers the vlc:// scheme: vlc://<http-url> opens straight
    # into its player instead of Safari. Plain https first (Safari plays
    # m3u8/mp4 natively), vlc:// as retry.
    local opener="" c
    local -a candidates=()
    [[ -n "${MOVIE_CLI_OPENER:-}" ]] && candidates+=("$MOVIE_CLI_OPENER")
    candidates+=(openurl open)

    for c in "${candidates[@]}"; do
        if _ios_is_url_opener "$c"; then
            opener="$c"
            break
        fi
    done

    if [[ -n "$opener" ]]; then
        debug "iOS launch via $opener: $final_url"
        if "$opener" "$final_url" >/dev/null 2>&1; then
            debug "URL handed off successfully"
            [[ -n "$start_time" ]] && debug "iOS: resume position not passed (opener has no extras API)"
            return 0
        fi

        debug "plain open failed — retrying via vlc:// scheme"
        if "$opener" "vlc://$final_url" >/dev/null 2>&1; then
            debug "vlc:// hand-off succeeded"
            return 0
        fi

        warn "$opener failed to open stream URL"
    fi

    # Fallback: VLC HTTP remote control interface (VLC Settings → HTTP → ON)
    if _ios_vlc_http_open "$final_url"; then
        debug "VLC HTTP interface accepted stream URL"
        [[ -n "$start_time" ]] && debug "iOS: resume position not passed (VLC HTTP no extras API)"
        return 0
    fi

    warn "No iOS URL opener found (tried: ${candidates[*]})."
    warn "To open streams from iSH, install one of:"
    warn "  • Blink Shell (provides openurl)"
    warn "  • Set MOVIE_CLI_OPENER=<your-opener-command>"
    warn "  • Enable VLC Settings → HTTP remote control (port 8080)"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Play Video
# Args: $1=url, $2=start_time (optional)
# ═══════════════════════════════════════════════════════════════
play_video() {
    local url="$1"
    local start_time="${2:-}"
    local stream_referer="${3:-}"
    local player="${PLAYER:-mpv}"

    # ponytail: URL-encode addon URLs with unencoded spaces/brackets
    # CDN proxies (p.111477.xyz etc.) choke on raw special chars in query params
    if [[ "$url" == https://* || "$url" == http://* ]]; then
        url=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=":/?&=%+-._~"))' "$url" 2>/dev/null || printf '%s' "$url")
    fi

    # Allowlist first: the torrent branch below interpolates --"$player"
    # into webtorrent flags, so it must not bypass validate_player.
    validate_player "$player"

    # ponytail: torrent
    if [[ "$url" == magnet:* || "$url" == *.torrent ]]; then
        command -v webtorrent &>/dev/null || die_deps "webtorrent not found. Install: npm install -g webtorrent-cli"
        if [[ "${NO_DETACH:-0}" == "1" ]]; then
            webtorrent "$url" --"$player" 2>/dev/null
        else
            webtorrent "$url" --"$player" &>/dev/null &
            disown $! 2>/dev/null || true
        fi
        return 0
    fi

    # Per-stream referer first (hubcloud-chain workers.dev CDNs hotlink-check);
    # fall back to the Vidlink default for Vidlink / CineStream CDN URLs.
    # Strip CR/LF: referers arrive from remote resolver pages and would
    # otherwise smuggle extra headers into curl -H on old builds.
    local referrer=""
    stream_referer="${stream_referer//$'\r'/}"
    stream_referer="${stream_referer//$'\n'/}"
    if [[ -n "$stream_referer" && "$stream_referer" != "null" ]]; then
        [[ "$stream_referer" =~ ^https?://[^[:space:]]+$ ]] && referrer="$stream_referer"
    elif [[ "$url" == *"vidlink"* || "$url" == *"hakunaymatata"* || "$url" == *"vodvidl"* || "$url" == *"stormvv"* ]]; then
        referrer="https://vidlink.pro/"
    fi

    # ponytail: iOS — no child-process players exist in any terminal app;
    # hand the URL to the OS opener instead of exec'ing $player. This must
    # run BEFORE the per-player case so it never writes mpv lua/IPC files.
    if [[ "$_MC_PLATFORM" == "ios" ]]; then
        _ios_launch "$url" "$start_time" "$referrer"
        return $?
    fi

    local cmd=("$player")

    case "$player" in
        mpv)
            # ponytail: Termux — try Android intent first
            if [[ -d "/data/data/com.termux" ]]; then
                debug "Termux detected (Android $(getprop ro.build.version.release 2>/dev/null || echo unknown)), DISPLAY=${DISPLAY:-<empty>}"

                if _android_launch "$url" "${NO_DETACH:-0}" "$start_time" "$referrer"; then
                    return 0
                fi

                # ponytail: intent failed — can terminal mpv display?
                if [[ -n "${DISPLAY:-}" ]]; then
                    debug "DISPLAY set — falling back to terminal mpv"
                else
                    warn "mpv-android not available and no DISPLAY set."
                    warn "Terminal mpv cannot render video without a display server."
                    warn "Install mpv-android from Play Store, or set DISPLAY for Termux:X11."
                    return 1
                fi
            fi

            # ponytail: Linux/macOS or Termux:X11 — terminal mpv
            mkdir -p "${XDG_RUNTIME_DIR:-$HOME/.runtime}" 2>/dev/null || true
            local pos_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-$$"
            local script_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-script-$$.lua"
            cat > "$script_file" << LUAEOF
mp.register_event("shutdown", function()
    local pos = mp.get_property_number("time-pos", 0)
    local f = io.open("$pos_file", "w")
    if f then f:write(tostring(pos)); f:close() end
end)
LUAEOF
            local sock
            if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
                sock="$XDG_RUNTIME_DIR/movie-cli-mpv-$$"
            else
                SOCKET_DIR=$(mktemp -d "$HOME/.runtime/movie-cli.XXXXXX")
                sock="$SOCKET_DIR/mpv.sock"
            fi
            cmd+=(--script="$script_file" "--input-ipc-server=$sock" "--no-ytdl")
            [[ -n "$start_time" ]] && cmd+=(--start=$start_time)
            [[ "${NO_DETACH:-0}" == "1" ]] && cmd+=("--no-terminal")
            [[ -n "$referrer" ]] && cmd+=(--referrer=$referrer)
            cmd+=("$url")
            ;;
        vlc)
            [[ -n "$start_time" ]] && cmd+=(--start-time=$start_time)
            [[ -n "$referrer" ]] && cmd+=(--http-referrer=$referrer)
            cmd+=("$url")
            ;;
        iina)
            [[ -n "$start_time" ]] && cmd+=(--mpv-start=$start_time)
            [[ -n "$referrer" ]] && cmd+=(--mpv-referrer=$referrer)
            cmd+=("$url")
            ;;
    esac

    debug "Playing: ${cmd[*]}"

    if [[ "${NO_DETACH:-0}" == "1" ]]; then
        "${cmd[@]}" &
        MPV_PID=$!
        local _pv_rc=0
        wait "$MPV_PID" 2>/dev/null || _pv_rc=$?
        MPV_PID=""
        # Return mpv's exit code so callers can detect playback failure and
        # fall back to the next mirror (CloudStream nextMirror behavior).
        # 0 = user quit/finished, 130 = SIGINT (user interrupt) — neither is
        # a stream failure; anything else means the stream failed to play.
        return $_pv_rc
    else
        "${cmd[@]}" &>/dev/null &
        disown $! 2>/dev/null || true
        return 0
    fi
}

# ═══════════════════════════════════════════════════════════════
# Get MPV Progress / Duration (via IPC socket)
# ═══════════════════════════════════════════════════════════════
get_mpv_position() {
    local pos_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-$$"
    if [[ -f "$pos_file" ]]; then
        # Validate: raw lua-written contents feed arithmetic/--argjson.
        local _pos
        _pos=$(cat "$pos_file" 2>/dev/null || true)
        [[ "$_pos" =~ ^[0-9]+(\.[0-9]+)?$ ]] && { printf '%s' "${_pos%.*}"; return 0; }
        return 1
    fi
    local sock
    if [[ -n "${SOCKET_DIR:-}" ]]; then
        sock="$SOCKET_DIR/mpv.sock"
    else
        sock="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-mpv-$$"
    fi
    [[ -S "$sock" ]] || return 1
    local response
    response=$(printf '{"command":["get_property","time-pos"]}\n' | \
        timeout 2 socat - "$sock" 2>/dev/null) || return 1
    printf '%s' "$response" | grep -o '"data":[0-9.]*' | cut -d: -f2
}

get_mpv_duration() {
    local sock
    if [[ -n "${SOCKET_DIR:-}" ]]; then
        sock="$SOCKET_DIR/mpv.sock"
    else
        sock="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-mpv-$$"
    fi
    [[ -S "$sock" ]] || return 1
    local response
    response=$(printf '{"command":["get_property","duration"]}\n' | \
        timeout 2 socat - "$sock" 2>/dev/null) || return 1
    printf '%s' "$response" | grep -o '"data":[0-9.]*' | cut -d: -f2
}
