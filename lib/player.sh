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
            # ponytail: Lua script saves final position on quit (IPC socket dies with mpv)
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
            [[ -n "$referrer" ]] && cmd+=("--referrer=$referrer")
            # ponytail: Termux — mpv-android via intent, then fallback
            if [[ -d "/data/data/com.termux" ]]; then
                am start --user 0 -a android.intent.action.VIEW \
                    -d "$url" -n is.xyz.mpv/.MPVActivity \
                    -e "title" "movie-cli" >/dev/null 2>&1 && return 0
                warn "mpv-android not found. Install from Play Store for headed playback."
            fi
            cmd+=("$url")
            ;;
        vlc)
            [[ -n "$start_time" ]] && cmd+=("--start-time=$start_time")
            [[ -n "$referrer" ]] && cmd+=("--http-referrer=$referrer")
            cmd+=("$url")
            ;;
        iina)
            [[ -n "$start_time" ]] && cmd+=("--mpv-start=$start_time")
            [[ -n "$referrer" ]] && cmd+=("--mpv-referrer=$referrer")
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
