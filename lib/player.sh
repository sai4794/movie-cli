#!/usr/bin/env bash
# player.sh — Video player wrapper (mpv, vlc, iina)
# Source AFTER errors.sh

# ═══════════════════════════════════════════════════════════════
# Player Allowlist
# ═══════════════════════════════════════════════════════════════
_VALID_PLAYERS="mpv vlc iina"

# Validate player name (security: prevent command injection)
validate_player() {
    local player="$1"
    if [[ " $_VALID_PLAYERS " != *" $player "* ]]; then
        die_player "Invalid player: $player (allowed: $_VALID_PLAYERS)"
    fi
    if ! command -v "$player" &>/dev/null; then
        die_deps "Player not found: $player"
    fi
}

# ═══════════════════════════════════════════════════════════════
# Android Detection & Playback
# ═══════════════════════════════════════════════════════════════

# ponytail: detect if running inside Termux
_is_termux() {
    [[ -d "/data/data/com.termux" ]]
}

# ponytail: detect Android version string (e.g. "13")
_android_version() {
    getprop ro.build.version.release 2>/dev/null || echo "unknown"
}

# ponytail: check if mpv-android is installed (any user)
_mpv_android_installed() {
    pm list packages --user 0 2>/dev/null | grep -q "^package:is\.xyz\.mpv$" && return 0
    pm list packages 2>/dev/null | grep -q "^package:is\.xyz\.mpv$" && return 0
    return 1
}

# ponytail: resolve the best mpv-android activity to launch
# Returns: "package/activity" string or empty
_resolve_mpv_activity() {
    # Try to find an activity that handles VIEW + video URLs
    # ponytail: dumpsys is reliable across Play Store / F-Droid / sideload
    local user_flag="--user 0"
    local dump

    dump=$(dumpsys package is.xyz.mpv 2>/dev/null) || { echo ""; return 1; }

    # Extract all exported activity class names
    local activities
    activities=$(printf '%s' "$dump" | \
        sed -n 's/.*Activity Resolver.*//; s/^ *is\.xyz\.mpv\.[A-Za-z0-9_]*$/&/p' | \
        sed 's/^ *//') 

    # If sed approach fails, try grep for known patterns
    if [[ -z "$activities" ]]; then
        activities=$(printf '%s' "$dump" | grep -oE 'is\.xyz\.mpv\.[A-Za-z0-9_.]+' | sort -u)
    fi

    debug "mpv-android activities found: ${activities:-none}"

    # ponytail: prefer MPVActivity (the dedicated player), then MainActivity, then any
    local preferred=("MPVActivity" "MainActivity" "PlayerActivity")
    for act in "${preferred[@]}"; do
        local full="is.xyz.mpv/$act"
        if printf '%s\n' "$activities" | grep -qF "$full"; then
            debug "Resolved activity: $full"
            echo "$full"
            return 0
        fi
    done

    # Fallback: first activity we found
    if [[ -n "$activities" ]]; then
        local first
        first=$(printf '%s\n' "$activities" | head -n1)
        debug "Fallback activity: $first"
        echo "$first"
        return 0
    fi

    echo ""
    return 1
}

# ponytail: launch mpv-android via implicit VIEW intent
# Returns 0 on success, non-zero on failure
_launch_mpv_android() {
    local url="$1"
    local activity="${2:-}"

    # Strip leaked env vars that confuse Termux's am wrapper
    local env_clean="env -u DEBUG -u VERBOSE"

    # ponytail: implicit intent (no -n) — let Android resolve the best handler
    # This works across Play Store, F-Droid, and future mpv-android versions
    # because Android matches against intent filters, not hardcoded class names.
    local _am_rc=0 _am_err=""

    if [[ -n "$activity" ]]; then
        # Explicit intent with resolved activity — most reliable
        debug "Trying explicit intent: $activity"
        _am_err=$(eval "$env_clean" am start -W --user 0 \
            -a android.intent.action.VIEW \
            -d "\"$url\"" -f 0x10000000 \
            -n "\"$activity\"" 2>&1) || _am_rc=$?
    fi

    if [[ "$_am_rc" -ne 0 && -n "$activity" ]]; then
        debug "Explicit intent failed (exit $_am_rc), trying implicit"
        _am_rc=0
        _am_err=""
    fi

    if [[ "$_am_rc" -eq 0 && -z "$activity" ]]; then
        # ponytail: no activity resolved — try implicit anyway
        debug "Trying implicit VIEW intent (no -n)"
        _am_err=$(eval "$env_clean" am start -W --user 0 \
            -a android.intent.action.VIEW \
            -d "\"$url\"" -f 0x10000000 2>&1) || _am_rc=$?
    fi

    debug "am start exit: $_am_rc"
    [[ -n "$_am_err" ]] && debug "am start output: $_am_err"

    if [[ "$_am_rc" -eq 0 ]]; then
        debug "mpv-android launched successfully"
        return 0
    fi

    warn "mpv-android launch failed (exit $_am_rc)"
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

    # ponytail: torrent → webtorrent stream → mpv
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

    # Set referrer for Vidlink / CineStream CDN URLs to bypass 403 blocks
    local referrer=""
    if [[ "$url" == *"vidlink"* || "$url" == *"hakunaymatata"* || "$url" == *"vodvidl"* || "$url" == *"stormvv"* ]]; then
        referrer="https://vidlink.pro/"
    fi

    # Build command
    local cmd=("$player")

    case "$player" in
        mpv)
            # ponytail: Termux — try mpv-android first, then fall back
            if _is_termux; then
                debug "Termux detected (Android $(_android_version))"

                if _mpv_android_installed; then
                    debug "mpv-android package found"
                    local activity
                    activity=$(_resolve_mpv_activity)

                    if _launch_mpv_android "$url" "$activity"; then
                        return 0
                    fi
                    # ponytail: explicit+implicit both failed — fall through
                else
                    debug "mpv-android not installed"
                fi

                # ponytail: mpv-android not available — can terminal mpv display?
                if [[ -n "${DISPLAY:-}" ]]; then
                    debug "DISPLAY=$DISPLAY — terminal mpv can render"
                    # Fall through to terminal mpv command below
                else
                    # No display server — terminal mpv plays audio only
                    warn "mpv-android not available and no DISPLAY set."
                    warn "Terminal mpv cannot render video without a display server."
                    warn "Install mpv-android from Play Store, or set DISPLAY (Termux:X11)."
                    return 1
                fi
            fi

            # ponytail: Linux/macOS or Termux with DISPLAY — terminal mpv
            # Lua script saves final position on quit (IPC socket dies with mpv)
            local pos_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-$$"
            local script_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-script-$$.lua"
            cat > "$script_file" << LUAEOF
mp.register_event("shutdown", function()
    local pos = mp.get_property_number("time-pos", 0)
    local f = io.open("$pos_file", "w")
    if f then f:write(tostring(pos)); f:close() end
end)
LUAEOF
            # Use IPC socket in a secure runtime directory for progress tracking
            local sock
            if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
                sock="$XDG_RUNTIME_DIR/movie-cli-mpv-$$"
            else
                SOCKET_DIR=$(mktemp -d "$HOME/.runtime/movie-cli.XXXXXX")
                sock="$SOCKET_DIR/mpv.sock"
            fi
            cmd+=(--script="$script_file" "--input-ipc-server=$sock")
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

    # Launch player
    if [[ "${NO_DETACH:-0}" == "1" ]]; then
        "${cmd[@]}" &
        MPV_PID=$!
        wait "$MPV_PID" 2>/dev/null || true
        MPV_PID=""
    else
        # Run in background, redirect outputs, and disown from shell jobs
        "${cmd[@]}" &>/dev/null &
        disown $! 2>/dev/null || true
    fi
}

# ═══════════════════════════════════════════════════════════════
# Get MPV Progress (via IPC socket)
# ═══════════════════════════════════════════════════════════════
get_mpv_position() {
    # ponytail: try Lua pos_file first (mpv already exited), then IPC socket
    local pos_file="${XDG_RUNTIME_DIR:-$HOME/.runtime}/movie-cli-pos-$$"
    if [[ -f "$pos_file" ]]; then
        cat "$pos_file" 2>/dev/null
        return 0
    fi

    # Fallback: IPC socket (mpv still running)
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

# ═══════════════════════════════════════════════════════════════
# Get MPV Duration (via IPC socket)
# ═══════════════════════════════════════════════════════════════
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
