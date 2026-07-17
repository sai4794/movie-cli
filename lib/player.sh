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
    # not a CLI binary in $PATH. Skip binary check on Termux.
    if [[ -d "/data/data/com.termux" ]]; then
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

# ponytail: try launching URL via Android implicit VIEW intent.
# No hardcoded activities — Android resolves the best handler.
# Returns 0 on success.
_android_launch() {
    local url="$1"
    local wait_for_exit="${2:-0}"
    local start_time="${3:-}"
    local referrer="${4:-}"
    local _am_rc=0 _am_err=""

    # ponytail: resolve 302 redirects — mpv-android doesn't follow them,
    # but terminal mpv does. Proxy URLs (p.111477.xyz, etc.) 302 to CDN.
    # Use the raw URL (not yet URI-encoded) so curl sees the real endpoint.
    # Pass Referer if required — some CDNs validate it even on HEAD requests.
    local final_url="$url"
    local -a redirect_headers=()
    [[ -n "$referrer" ]] && redirect_headers+=(-H "Referer: $referrer")
    local resolved_url
    resolved_url=$(curl -4 -g -sL --range 0-0 --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{url_effective}' "${redirect_headers[@]}" "$url" 2>/dev/null)
    if [[ -n "$resolved_url" && "$resolved_url" != "$url" ]]; then
        debug "Redirect resolved: $url -> $resolved_url"
        final_url="$resolved_url"
    fi

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
    [[ -n "$start_time" ]] && am_flags+=(--ei position $((start_time * 1000)))
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
# Play Video
# Args: $1=url, $2=start_time (optional)
# ═══════════════════════════════════════════════════════════════
play_video() {
    local url="$1"
    local start_time="${2:-}"
    local player="${PLAYER:-mpv}"

    # ponytail: URL-encode addon URLs with unencoded spaces/brackets
    # CDN proxies (p.111477.xyz etc.) choke on raw special chars in query params
    if [[ "$url" == https://* || "$url" == http://* ]]; then
        url=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=":/?&=%+-._~"))' "$url" 2>/dev/null || printf '%s' "$url")
    fi

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

    validate_player "$player"

    # Set referrer for Vidlink / CineStream CDN URLs
    local referrer=""
    if [[ "$url" == *"vidlink"* || "$url" == *"hakunaymatata"* || "$url" == *"vodvidl"* || "$url" == *"stormvv"* ]]; then
        referrer="https://vidlink.pro/"
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
        wait "$MPV_PID" 2>/dev/null || true
        MPV_PID=""
    else
        "${cmd[@]}" &>/dev/null &
        disown $! 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════
# Get MPV Progress / Duration (via IPC socket)
# ═══════════════════════════════════════════════════════════════
get_mpv_position() {
    local pos_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-$$"
    if [[ -f "$pos_file" ]]; then
        cat "$pos_file" 2>/dev/null
        return 0
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
