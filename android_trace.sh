#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
# INSTRUMENTED _android_launch() — run this on your Android device
# Replaces the original _android_launch in player.sh
# Logs EVERYTHING to /sdcard/movie-cli-trace.log
# ═══════════════════════════════════════════════════════════════

TRACE_LOG="${HOME}/movie-cli-trace.log"

_log() {
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] %s\n' "$ts" "$1" >> "$TRACE_LOG"
    printf '[%s] %s\n' "$ts" "$1" >&2
}

_android_launch() {
    local url="$1"
    local wait_for_exit="${2:-0}"
    local start_time="${3:-}"
    local referrer="${4:-}"

    : > "$TRACE_LOG"  # Clear log
    _log "═══ _android_launch() CALLED ═══"
    _log "  url:          $url"
    _log "  url length:   ${#url} bytes"
    _log "  wait_for_exit: $wait_for_exit"
    _log "  start_time:   ${start_time:-<empty>}"
    _log "  referrer:     ${referrer:-<empty>}"

    # Step 1: URL encode as play_video() does (line 110)
    local step1
    step1=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=":/?&=%+-._~"))' "$url" 2>/dev/null || printf '%s' "$url")
    _log ""
    _log "═══ STEP 1: play_video() encoding ═══"
    _log "  Input:    $url"
    _log "  Output:   $step1"
    _log "  Changed:  $([ "$url" = "$step1" ] && echo "NO" || echo "YES")"
    if [ "$url" != "$step1" ]; then
        _log "  Hex orig: $(printf '%s' "$url" | xxd -p | head -c 120)"
        _log "  Hex enc:  $(printf '%s' "$step1" | xxd -p | head -c 120)"
    fi

    # Step 2: Redirect resolution
    local final_url="$step1"
    local -a redirect_headers=()
    [[ -n "$referrer" ]] && redirect_headers+=(-H "Referer: $referrer")

    _log ""
    _log "═══ STEP 2: curl redirect resolution ═══"
    _log "  Command: curl -4 -g -sL --range 0-0 --connect-timeout 5 --max-time 15"
    _log "           -o /dev/null -w '%{url_effective}' ${redirect_headers[*]:-} '$step1'"

    local resolved_url
    resolved_url=$(curl -4 -g -sL --range 0-0 --connect-timeout 5 --max-time 15 \
        -o /dev/null -w '%{url_effective}' "${redirect_headers[@]}" "$step1" 2>/dev/null)

    local curl_exit=$?
    _log "  curl exit:   $curl_exit"
    _log "  resolved:    ${resolved_url:-<empty>}"
    _log "  same input:  $([ "$step1" = "$resolved_url" ] && echo "YES" || echo "NO — REDIRECT DETECTED")"

    if [[ -n "$resolved_url" && "$resolved_url" != "$step1" ]]; then
        final_url="$resolved_url"
        _log "  final_url:   $final_url (from redirect)"
    fi

    # Step 3: _android_escape_uri
    local step3
    step3=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=":/?&=%+-._~"))' "$final_url" 2>/dev/null || printf '%s' "$final_url")
    _log ""
    _log "═══ STEP 3: _android_escape_uri() ═══"
    _log "  Input:    $final_url"
    _log "  Output:   $step3"
    _log "  Changed:  $([ "$final_url" = "$step3" ] && echo "NO (double-encode no-op)" || echo "YES — DOUBLE ENCODING!")"

    # Step 4: Android intent URI decode (simulate what Android does)
    local mpv_receives
    mpv_receives=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.unquote(sys.argv[1]))' "$step3" 2>/dev/null || printf '%s' "$step3")
    _log ""
    _log "═══ STEP 4: Android Intent URI decode (what mpv-android gets) ═══"
    _log "  am start sends: $step3"
    _log "  mpv-android gets: $mpv_receives"
    _log "  Same as original: $([ "$url" = "$mpv_receives" ] && echo "YES" || echo "NO — DECODED!")

    if [ "$url" != "$mpv_receives" ]; then
        _log ""
        _log "  *** URL DIFFERS BETWEEN MANUAL PASTE AND am start ***"
        # Find first difference
        local orig_hex enc_hex
        orig_hex=$(printf '%s' "$url" | xxd -p)
        enc_hex=$(printf '%s' "$mpv_receives" | xxd -p)
        _log "  Original hex: ${orig_hex:0:200}"
        _log "  Decoded hex:  ${enc_hex:0:200}"
    fi

    # Step 5: Build am start command
    local ANDROID_MIME="${ANDROID_MIME:-video/*}"
    local am_flags=(-a android.intent.action.VIEW -d "$step3" -t "$ANDROID_MIME")
    [[ "$wait_for_exit" == "1" ]] && am_flags+=(-W)
    [[ -n "$start_time" ]] && am_flags+=(--ei position $((start_time * 1000)))
    [[ -n "$referrer" ]] && am_flags+=(--es referrer "$referrer")

    _log ""
    _log "═══ STEP 5: am start command ═══"
    _log "  env -u DEBUG -u VERBOSE am start ${am_flags[*]}"
    _log "  MIME: $ANDROID_MIME"
    _log "  -W flag: $([ "$wait_for_exit" == "1" ] && echo "YES" || echo "NO")"

    # Execute
    local _am_rc=0 _am_err=""
    _am_err=$(env -u DEBUG -u VERBOSE am start "${am_flags[@]}" 2>&1) || _am_rc=$?

    _log ""
    _log "═══ STEP 6: am start result ═══"
    _log "  exit code: $_am_rc"
    _log "  output:    $_am_err"

    if [[ "$_am_rc" -eq 0 ]]; then
        _log "  STATUS: SUCCESS"
    else
        _log "  STATUS: FAILED"
    fi

    _log ""
    _log "═══ FINAL COMPARISON ═══"
    _log "  Original URL:     $url"
    _log "  mpv-android gets: $mpv_receives"
    _log "  Byte-identical:   $([ "$url" = "$mpv_receives" ] && echo "YES" || echo "NO")"
    _log ""
    _log "  Log saved to: $TRACE_LOG"

    [[ "$_am_rc" -eq 0 ]] && return 0
    return "$_am_rc"
}
