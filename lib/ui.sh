#!/usr/bin/env bash
# ui.sh — User interface components
# Source AFTER errors.sh
# All UI output goes to stderr. stdout reserved for machine-readable output.

# ═══════════════════════════════════════════════════════════════
# Color System
# ═══════════════════════════════════════════════════════════════
C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""

init_colors() {
    if [[ "${NO_COLOR:-0}" == "1" ]] || [[ ! -t 2 ]]; then
        C_BLUE="" C_GREEN="" C_YELLOW="" C_RED="" C_CYAN="" C_BOLD="" C_RESET=""
    else
        C_BLUE='\033[1;34m'
        C_GREEN='\033[1;32m'
        C_YELLOW='\033[1;33m'
        C_RED='\033[1;31m'
        C_CYAN='\033[1;36m'
        C_BOLD='\033[1m'
        C_RESET='\033[0m'
    fi
}
init_colors

# ═══════════════════════════════════════════════════════════════
# UI Components — all write to stderr
# ═══════════════════════════════════════════════════════════════

# Clear current line and print status message
status_msg() {
    printf "\33[2K\r${C_BLUE}%s${C_RESET}\n" "$1" >&2
}

# Print success message
ui_success() {
    printf "${C_GREEN}%s${C_RESET}\n" "$1" >&2
}

# Print error message
ui_error() {
    printf "${C_RED}%s${C_RESET}\n" "$1" >&2
}

# Print info line (verbose only)
ui_info() {
    [[ "${VERBOSE:-0}" == "1" ]] || return 0
    [[ "${QUIET:-0}" == "1" ]] && return 0
    printf "%s\n" "$1" >&2
}

# ═══════════════════════════════════════════════════════════════
# Spinner — visible loading feedback on stderr
# ═══════════════════════════════════════════════════════════════

spinner_start() {
    local msg="${1:-Working}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    # Only run spinner if stderr is a TTY (interactive) or if we're in a test environment
    if [[ -t 2 ]] || [[ -n "${BATS_TEST_FILENAME:-}" ]]; then
        (
            while true; do
                for (( i=0; i<${#spin}; i++ )); do
                    if [[ -t 2 ]] || [[ -n "${BATS_TEST_FILENAME:-}" ]]; then
                        printf "\33[2K\r%s %s" "${spin:$i:1}" "$msg" >&2
                    fi
                    sleep 0.1
                done
            done
        ) &
        _spinner_pid=$!
    else
        _spinner_pid=""
    fi
}

spinner_stop() {
    [[ -n "${_spinner_pid:-}" ]] && kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    [[ -t 2 || -n "${BATS_TEST_FILENAME:-}" ]] && printf "\33[2K\r" >&2 || true
}

# ═══════════════════════════════════════════════════════════════
# Item Selection (fzf / rofi / dmenu / numbered fallback)
# Writes selected item to $_SELECT_ITEM_RESULT (global variable).
# Returns 0 on success, 1 on failure/cancel.
# ═══════════════════════════════════════════════════════════════
select_item() {
    local prompt="$1"
    shift
    _SELECT_ITEM_RESULT=""

    # Auto-select if --select N is set. N=0 passes the old regex but the
    # -ge 1 gate then silently IGNORES it and drops into interactive menus —
    # reject it here so typos fail loudly instead of hanging a scripted run.
    if [[ -n "${SELECT_N:-}" ]]; then
        [[ "$SELECT_N" =~ ^[1-9][0-9]*$ ]] || die_user "Invalid --select value: $SELECT_N (must be >= 1)"
    fi
    if [[ -n "${SELECT_N:-}" ]] && [[ "$SELECT_N" -ge 1 ]] 2>/dev/null; then
        local count=1
        for item in "$@"; do
            if (( count == SELECT_N )); then
                _SELECT_ITEM_RESULT="$item"
                return 0
            fi
            (( count++ ))
        done
        # $count is already N+1 here (incremented past the last item).
        die_user "Selection $SELECT_N out of range (max: $((count - 1)))"
    fi

    # Search-only: just print results
    if [[ "${SEARCH_ONLY:-0}" == "1" ]]; then
        local i=1
        for item in "$@"; do
            printf '%d. %s\n' "$i" "$item" >&2
            (( i++ ))
        done
        return 0
    fi

    # Select UI backend
    local backend="${CONF_UI_BACKEND:-fzf}"

    case "$backend" in
        fzf)
            if ! command -v fzf &>/dev/null; then
                ui_info "fzf not found — using numbered list"
                backend="fallback"
            elif ! echo "test" | fzf --filter="test" &>/dev/null; then
                ui_info "fzf not working — using numbered list"
                backend="fallback"
            fi

            if [[ "$backend" == "fallback" ]]; then
                _numbered_select "$prompt" "$@"
                return $?
            fi

            # fzf: pipe items via stdin
            local selected
            selected=$(printf '%s\n' "$@" | fzf --prompt "$prompt" --expect=esc,ctrl-q --reverse --cycle)

            local fzf_key fzf_value
            fzf_key=$(printf '%s\n' "$selected" | head -1)
            fzf_value=$(printf '%s\n' "$selected" | tail -1)
            [[ "$fzf_key" == "$fzf_value" ]] && fzf_key=""

            if [[ "$fzf_key" == "esc" ]] || [[ "$fzf_key" == "ctrl-q" ]]; then
                exit 130
            fi
            _SELECT_ITEM_RESULT="$fzf_value"
            ;;
        rofi)
            if ! command -v rofi &>/dev/null; then
                die_deps "rofi not found. Install with: sudo apt install rofi"
            fi
            _SELECT_ITEM_RESULT=$(printf '%s\n' "$@" | rofi -dmenu -p "$prompt")
            ;;
        dmenu)
            if ! command -v dmenu &>/dev/null; then
                die_deps "dmenu not found. Install with: sudo apt install dmenu"
            fi
            _SELECT_ITEM_RESULT=$(printf '%s\n' "$@" | dmenu -p "$prompt")
            ;;
        *)
            die_user "Unknown UI backend: $backend"
            ;;
    esac

    [[ -n "$_SELECT_ITEM_RESULT" ]] && return 0
    return 1
}

# Numbered list fallback — reads from /dev/tty if available, otherwise stdin
_numbered_select() {
    local prompt="$1"
    shift
    local i=1
    for item in "$@"; do
        printf ' %d. %s\n' "$i" "$item" >&2
        (( i++ ))
    done
    printf "%s " "$prompt" >&2
    # Try /dev/tty first with a timeout, fall back to stdin
    local choice
    # Use a short timeout read from /dev/tty in a subshell
    # If /dev/tty is not available or not readable, this will fail and we fall back
    if choice=$( (read -t 0.5 -r choice </dev/tty && printf '%s' "$choice") 2>/dev/null ); then
        # Successfully read from /dev/tty
        :
    else
        read -r choice
    fi
    if [[ ! "${choice:-}" =~ ^[0-9]+$ ]]; then
        die_user "Invalid selection: ${choice:-}"
    fi

    local count=1
    for item in "$@"; do
        if (( count == choice )); then
            _SELECT_ITEM_RESULT="$item"
            return 0
        fi
        (( count++ ))
    done
    die_user "Invalid selection: $choice"
}

# ═══════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════
# Stream Selection — display all streams, return selected object
# Args: $1=prompt, $2+=JSON stream objects (variadic)
# Writes selected stream JSON to $_SELECT_ITEM_RESULT
# ═══════════════════════════════════════════════════════════════
select_stream() {
    local prompt="$1"
    shift
    if (( $# == 1 )) && { ! [[ -t 0 ]] || [[ -n "${BATS_TEST_FILENAME:-}" ]]; }; then
        _SELECT_ITEM_RESULT="$1"
        return 0
    fi

    # One jq pass builds every label (~7 forks/stream before: ~420 procs
    # for a 60-stream episode). "<- Back" sentinels pass through as index -1.
    local -a labels=() streams=()
    local _sl_tmp
    _sl_tmp=$(mktemp 2>/dev/null || mktemp -t movie_cli_labels) || return 1
    [[ -n "$_sl_tmp" ]] || return 1
    local stream label
    for stream in "$@"; do
        # Sentinels are not JSON — jq -R reads every line as a raw STRING so
        # "<- Back" reaches the `==` test instead of dying as a parse error
        # (bare `jq` aborts on the sentinel line and drops ALL labels).
        printf '%s\n' "$stream"
    done | jq -Rr '
        (if . == "<- Back" then "-1"
         else
            ((fromjson? // {}) as $o
             # Spacing replicates the legacy builder exactly: each of the
             # five fields appends value+"   ", size appends bare, HDR
             # appends "   HDR", then one trailing space is stripped.
             | ([($o.provider // empty), ($o.quality // empty), ($o.codec // empty),
                 ($o.audio // empty), ($o.language // empty)]
                | map(select(. != "") | . + "   ") | add // "")
               + (if ($o.size // "unknown") != "unknown" then $o.size else "" end)
               + (if $o.hdr == true then "   HDR" else "" end)
               | sub(" $"; "")
               | if . == "" then "Stream" else . end)
         end)
    ' 2>/dev/null > "$_sl_tmp" || { rm -f "$_sl_tmp"; return 1; }
    for stream in "$@"; do
        IFS= read -r label <&3 || label="Stream"
        # Restore the sentinel's own label (jq emits -1 for it above).
        [[ "$label" == "-1" ]] && label="<- Back"
        labels+=("$label")
        streams+=("$stream")
    done 3< "$_sl_tmp"
    rm -f "$_sl_tmp" 2>/dev/null || true

    select_item "$prompt" "${labels[@]}" || return 1
    local selected_label="$_SELECT_ITEM_RESULT"

    local i=0
    for label in "${labels[@]}"; do
        if [[ "$label" == "$selected_label" ]]; then
            _SELECT_ITEM_RESULT="${streams[$i]}"
            return 0
        fi
        (( i++ ))
    done

    # No label matched: fail loudly instead of silently playing $1.
    warn "select_stream: no label matched '$selected_label' — refusing to guess"
    return 1
}

# ═══════════════════════════════════════════════════════════════
# Confirmation Prompt
# ═══════════════════════════════════════════════════════════════
confirm() {
    local prompt="${1:-Continue?}"
    printf '%s [y/N] ' "$prompt" >&2
    # No tty (piped/scripted run): decline instead of hanging forever.
    read -r answer </dev/tty 2>/dev/null || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ═══════════════════════════════════════════════════════════════
# Version Display
# ═══════════════════════════════════════════════════════════════
show_version() {
    printf 'movie-cli %s\n' "$VERSION"
}

# ═══════════════════════════════════════════════════════════════
# Help Display
# ═══════════════════════════════════════════════════════════════
show_help() {
    printf "${C_BOLD}movie-cli${C_RESET} %s — Terminal movie/series player\n\n" "$VERSION" >&2
    printf "${C_BOLD}Usage:${C_RESET} movie-cli [OPTIONS] [<query>]\n\n" >&2
    printf "${C_BOLD}Search:${C_RESET}\n" >&2
    printf "  -p, --plugin NAME      Use specific plugin (default: auto)\n" >&2
    printf "  -q, --quality LEVEL    Min quality: 480, 720, 1080 [default: 720]\n" >&2
    printf "  -s, --search-only      Output results without playing\n" >&2
    printf "  -S, --select N         Auto-select Nth result\n\n" >&2
    printf "${C_BOLD}Playback:${C_RESET}\n" >&2
    printf "      --no-detach        Don't detach player\n\n" >&2
    printf "${C_BOLD}History:${C_RESET}\n" >&2
    printf "  -c, --continue        Continue watching last entry\n" >&2
    printf "  -l, --log              View watch history\n" >&2
    printf "  -D, --delete-history   Delete watch history\n\n" >&2
    printf "${C_BOLD}System:${C_RESET}\n" >&2
    printf "  -u, --update           Self-update from GitHub\n" >&2
    printf "  update                 Same as --update (positional command)\n" >&2
    printf "      --update-check     Check for updates without applying\n" >&2
    printf "      --list-plugins     List available plugins\n" >&2
    printf "      --check-deps       Verify all dependencies\n" >&2
    printf "      --debug            Enable debug logging\n" >&2
    printf "      --quiet            Suppress non-essential output\n" >&2
    printf "      --no-cache         Bypass cache\n" >&2
    printf "      --clear-cache      Clear all cached data\n" >&2
    printf "      --profile          Show timing profile\n" >&2
    printf "      --no-color         Disable colored output\n" >&2
    printf "  -v, --version          Show version\n" >&2
    printf "  -h, --help             Show this help\n\n" >&2
    printf "${C_BOLD}Examples:${C_RESET}\n" >&2
    printf "  movie-cli \"inception\"\n" >&2
    printf "  movie-cli -q 1080 \"inception\"\n" >&2
    printf "  movie-cli --select 3 \"inception\"\n" >&2
    printf "  movie-cli --log\n" >&2
}
