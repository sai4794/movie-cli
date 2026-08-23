#!/usr/bin/env bash
# profile_cinestream.sh — Deep profiling of CineStream stream discovery
# Usage: bash tests/profile_cinestream.sh [imdb_id] [type]
# Example: bash tests/profile_cinestream.sh tt1375666 movie   # Inception
#          bash tests/profile_cinestream.sh "tt6468322:3:1" series  # Money Heist S3E1

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ═══════════════════════════════════════════════════════════════
# Profiling infrastructure
# ═══════════════════════════════════════════════════════════════
declare -A _TIMINGS_SUM=()
declare -A _TIMINGS_COUNT=()
declare -A _TIMINGS_MIN=()
declare -A _TIMINGS_MAX=()
declare -a _TIMINGS_LOG=()  # ordered log for flame-graph-style output
_PROFILE_TMPDIR=$(mktemp -d)
_TIMING_FILE="$_PROFILE_TMPDIR/timings.log"
: > "$_TIMING_FILE"

_now_ns() {
    date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000))
}

# Record a single timing: name, duration_ns
_record_timing() {
    local name="$1" dur_ns="$2"
    local dur_ms=$(( dur_ns / 1000000 ))
    
    _TIMINGS_COUNT[$name]=$(( ${_TIMINGS_COUNT[$name]:-0} + 1 ))
    _TIMINGS_SUM[$name]=$(( ${_TIMINGS_SUM[$name]:-0} + dur_ns ))
    
    if [[ -z "${_TIMINGS_MIN[$name]:-}" ]] || (( dur_ns < ${_TIMINGS_MIN[$name]} )); then
        _TIMINGS_MIN[$name]=$dur_ns
    fi
    if [[ -z "${_TIMINGS_MAX[$name]:-}" ]] || (( dur_ns > ${_TIMINGS_MAX[$name]} )); then
        _TIMINGS_MAX[$name]=$dur_ns
    fi
    
    printf '%s\t%s\t%s\n' "$name" "$dur_ns" "$dur_ms" >> "$_TIMING_FILE"
}

# Timed execution wrapper: _timed <name> <command...>
_timed() {
    local name="$1"
    shift
    local start=$(_now_ns)
    "$@"
    local rc=$?
    local end=$(_now_ns)
    _record_timing "$name" $(( end - start ))
    return $rc
}

# Timed capture: result=$(_timed_capture <name> <command...>)
_timed_capture() {
    local name="$1"
    shift
    local start=$(_now_ns)
    local output
    output=$("$@" 2>/dev/null) || true
    local end=$(_now_ns)
    _record_timing "$name" $(( end - start ))
    printf '%s' "$output"
}

# Print timing report
_print_report() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "              CINESTREAM DEEP PROFILE REPORT"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    # Sort by total time descending
    printf '%-50s %8s %8s %8s %8s %8s\n' "Operation" "Count" "Total" "Avg" "Min" "Max"
    printf '%-50s %8s %8s %8s %8s %8s\n' \
        "--------------------------------------------------" "--------" "--------" "--------" "--------" "--------"
    
    # Collect and sort
    local -a sorted_keys=()
    for key in "${!_TIMINGS_SUM[@]}"; do
        sorted_keys+=("${_TIMINGS_SUM[$key]}|$key")
    done
    
    IFS=$'\n' sorted_keys=($(printf '%s\n' "${sorted_keys[@]}" | sort -t'|' -k1 -rn))
    unset IFS
    
    for entry in "${sorted_keys[@]}"; do
        local total_ns="${entry%%|*}"
        local name="${entry#*|}"
        local count="${_TIMINGS_COUNT[$name]}"
        local avg_ms=$(( total_ns / count / 1000000 ))
        local total_ms=$(( total_ns / 1000000 ))
        local min_ms=$(( ${_TIMINGS_MIN[$name]} / 1000000 ))
        local max_ms=$(( ${_TIMINGS_MAX[$name]} / 1000000 ))
        
        printf '%-50s %8d %7dms %7dms %7dms %7dms\n' \
            "$name" "$count" "$total_ms" "$avg_ms" "$min_ms" "$max_ms"
    done
    
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "              TOP 20 SLOWEST INDIVIDUAL CALLS"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    
    sort -t$'\t' -k2 -rn "$_TIMING_FILE" | head -20 | while IFS=$'\t' read -r name dur_ns dur_ms; do
        printf '%-50s %7dms\n' "$name" "$dur_ms"
    done
    
    echo ""
}

# ═══════════════════════════════════════════════════════════════
# Instrumented curl wrapper
# ═══════════════════════════════════════════════════════════════
_instrumented_curl() {
    local label="$1"
    shift
    
    local start=$(_now_ns)
    
    # Use curl with timing info
    local timing_file=$(mktemp "$_PROFILE_TMPDIR/curl_timing.XXXXXX")
    local output
    output=$(curl -w '\n{"dns_ms":%{time_namelookup},"connect_ms":%{time_connect},"tls_ms":%{time_appconnect},"transfer_ms":%{time_starttransfer},"total_ms":%{time_total},"redirect_ms":%{time_redirect},"http_code":%{http_code},"size_download":%{size_download}}' \
        "$@" 2>/dev/null) || true
    
    local end=$(_now_ns)
    _record_timing "curl:$label" $(( end - start ))
    
    # Parse curl timing from last line
    local timing_json="${output##*$'\n'}"
    local body="${output%$'\n'*}"
    
    # If timing_json looks like JSON, record sub-timings
    if [[ "$timing_json" == '{"dns_ms":'* ]]; then
        local dns_s connect_s tls_s transfer_s total_s
        dns_s=$(printf '%s' "$timing_json" | jq -r '.dns_ms // 0' 2>/dev/null || echo 0)
        connect_s=$(printf '%s' "$timing_json" | jq -r '.connect_ms // 0' 2>/dev/null || echo 0)
        tls_s=$(printf '%s' "$timing_json" | jq -r '.tls_ms // 0' 2>/dev/null || echo 0)
        transfer_s=$(printf '%s' "$timing_json" | jq -r '.transfer_ms // 0' 2>/dev/null || echo 0)
        total_s=$(printf '%s' "$timing_json" | jq -r '.total_ms // 0' 2>/dev/null || echo 0)
        
        # Convert to ms (they come as float seconds)
        local dns_ms=$(printf '%s' "$dns_s" | awk '{printf "%d", $1*1000}')
        local connect_ms=$(printf '%s' "$connect_s" | awk '{printf "%d", $1*1000}')
        local tls_ms=$(printf '%s' "$tls_s" | awk '{printf "%d", $1*1000}')
        local transfer_ms=$(printf '%s' "$transfer_s" | awk '{printf "%d", $1*1000}')
        local total_ms=$(printf '%s' "$total_s" | awk '{printf "%d", $1*1000}')
        
        _record_timing "curl:$label:dns" $(( dns_ms * 1000000 ))
        _record_timing "curl:$label:tcp_connect" $(( (connect_ms - dns_ms) * 1000000 ))
        _record_timing "curl:$label:tls" $(( (tls_ms - connect_ms) * 1000000 ))
        _record_timing "curl:$label:server_processing" $(( (transfer_ms - tls_ms) * 1000000 ))
        _record_timing "curl:$label:download" $(( (total_ms - transfer_ms) * 1000000 ))
        
        printf '%s' "$body"
    else
        printf '%s' "$output"
    fi
    
    rm -f "$timing_file" 2>/dev/null
}

# ═══════════════════════════════════════════════════════════════
# Source dependencies minimally
# ═══════════════════════════════════════════════════════════════
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/errors.sh"
source "$SCRIPT_DIR/lib/ui.sh"

# Stub functions needed by plugin
debug() { :; }
warn() { echo "[WARN] $*" >&2; }
die_plugin() { echo "[DIE] $*" >&2; exit 1; }

init_dirs

# ═══════════════════════════════════════════════════════════════
# Inputs
# ═══════════════════════════════════════════════════════════════
ID="${1:-tt1375666}"        # Default: Inception
QUALITY="${2:-720}"

echo "═══════════════════════════════════════════════════════════════"
echo "  Profiling CineStream: ID=$ID quality=$QUALITY"
echo "═══════════════════════════════════════════════════════════════"

# Source the plugin
source "$SCRIPT_DIR/plugins/cinestream.sh"

# ═══════════════════════════════════════════════════════════════
# Phase 1: Profile plugin_get_url decomposed
# ═══════════════════════════════════════════════════════════════
OVERALL_START=$(_now_ns)

type="movie"
if [[ "$ID" == *:* ]]; then
    type="series"
fi
imdb_id="${ID%%:*}"

# --- Cinemeta metadata fetch ---
echo "[1/7] Fetching Cinemeta metadata..."
META_START=$(_now_ns)
meta_res=$(_instrumented_curl "cinemeta_meta" -s -L --connect-timeout 10 --max-time 30 \
    "${_CINEMETA_BASE}/meta/${type}/${imdb_id}.json")
META_END=$(_now_ns)
_record_timing "phase:cinemeta_metadata" $(( META_END - META_START ))

tmdb_id=""
JQ_START=$(_now_ns)
if printf '%s' "$meta_res" | jq -e . >/dev/null 2>&1; then
    tmdb_id=$(printf '%s' "$meta_res" | jq -r '.meta.moviedb_id // empty')
fi
JQ_END=$(_now_ns)
_record_timing "jq:parse_cinemeta_meta" $(( JQ_END - JQ_START ))
echo "  TMDB ID: ${tmdb_id:-none}"

# --- Create temp dir ---
TMPDIR_START=$(_now_ns)
tmp_dir=$(mktemp -d)
TMPDIR_END=$(_now_ns)
_record_timing "fs:mktemp" $(( TMPDIR_END - TMPDIR_START ))

# --- Addon list setup ---
SETUP_START=$(_now_ns)
addon_list=()
addon_list+=("https://desiflix.stremioaddon.workers.dev")
addon_list+=("https://addon.notorrent2.workers.dev")
addon_list+=("https://pengu.uk")
addon_list+=("https://webstreamrmbg.onrender.com")
addon_list+=("https://hdhub.thevolecitor.qzz.io")

_load_cinestream_config
if [[ -n "${STREMIO_ADDONS:-}" ]]; then
    IFS=',' read -r -a custom_list <<< "$STREMIO_ADDONS"
    for custom_url in "${custom_list[@]}"; do
        addon_list+=("$custom_url")
    done
fi
SETUP_END=$(_now_ns)
_record_timing "setup:addon_list" $(( SETUP_END - SETUP_START ))
echo "  Addons: ${#addon_list[@]}"

# --- Profile each provider individually (sequential, for accurate timing) ---
echo ""
echo "[2/7] Profiling each provider individually..."

# Track per-provider timings for each
declare -A PROVIDER_TIME=()
declare -A PROVIDER_STREAMS=()
TOTAL_PROVIDER_STREAMS=0

addon_idx=0
for addon_url in "${addon_list[@]}"; do
    addon_url="${addon_url#"${addon_url%%[![:space:]]*}"}"
    addon_url="${addon_url%"${addon_url##*[![:space:]]}"}"
    [[ -z "$addon_url" ]] && continue
    addon_url="${addon_url%/manifest.json}"
    
    addon_label="${addon_url#https://}"
    addon_label="${addon_label#http://}"
    
    echo "  [$addon_idx] $addon_label..."
    
    PROV_START=$(_now_ns)
    
    addon_api="${addon_url}/stream/${type}/${ID}.json"
    
    # Fetch
    FETCH_START=$(_now_ns)
    addon_res=$(_instrumented_curl "addon:$addon_label" -s -L --connect-timeout 10 --max-time 30 \
        -H "User-Agent: movie-cli/$VERSION" \
        "$addon_api") || true
    FETCH_END=$(_now_ns)
    _record_timing "provider:$addon_label:fetch" $(( FETCH_END - FETCH_START ))
    
    # Parse/transform
    stream_count=0
    if printf '%s' "$addon_res" | jq -e .streams >/dev/null 2>&1; then
        JQ_START=$(_now_ns)
        printf '%s' "$addon_res" | jq -c '
            [ .streams[] | select(.url != null) |
              ((.title // "") + " " + (.description // "") + " " + (.name // "")) as $t | {
                quality: (if ($t | test("(?i)4k|2160p|2160")) then "4K"
                          elif ($t | test("(?i)1440p|1440|\\b2k\\b")) then "1440"
                          elif ($t | test("(?i)1080p|1080")) then "1080"
                          elif ($t | test("(?i)720p|720")) then "720"
                          elif ($t | test("(?i)480p|480")) then "480"
                          elif ($t | test("(?i)360p|360")) then "360"
                          elif ($t | test("(?i)240p|240")) then "240"
                          elif ($t | test("(?i)144p|144")) then "144"
                          else "auto" end),
                url: .url,
                size: (try (($t | match("[0-9]+(?:\\.[0-9]+)?\\s*(?:GB|MB|gb|mb)"; "i") | .string) // "unknown") catch "unknown"),
                provider: ((.name // "Addon") | gsub("\\n"; " ")),
                lang: (if ($t | test("(?i)\\btelugu\\b|\\btel\\b")) then "telugu"
                       elif ($t | test("(?i)\\bhindi\\b|bollywood")) then "hindi"
                       elif ($t | test("(?i)\\btamil\\b")) then "tamil"
                       elif ($t | test("(?i)\\bkannada\\b")) then "kannada"
                       elif ($t | test("(?i)\\bmalayalam\\b")) then "malayalam"
                       elif ($t | test("(?i)\\benglish\\b|eng\\b")) then "english"
                       elif ($t | test("(?i)\\boriginal\\b|\\borg\\b")) then "original"
                       elif ($t | test("(?i)\\bspanish\\b|\\bespañol\\b")) then "spanish"
                       elif ($t | test("(?i)\\bfrench\\b|\\bfrançais\\b")) then "french"
                       elif ($t | test("(?i)\\bgerman\\b|\\bdeutsch\\b")) then "german"
                       elif ($t | test("(?i)\\bportuguese\\b|\\bportuguês\\b")) then "portuguese"
                       elif ($t | test("(?i)\\brussian\\b|\\bрусский\\b")) then "russian"
                       elif ($t | test("(?i)\\barabic\\b|\\bعربي\\b")) then "arabic"
                       elif ($t | test("(?i)\\bjapanese\\b|\\b日本語\\b")) then "japanese"
                       elif ($t | test("(?i)\\bkorean\\b|\\b한국어\\b")) then "korean"
                       elif ($t | test("(?i)\\bchinese\\b|\\b中文\\b")) then "chinese"
                       elif ($t | test("(?i)\\bturkish\\b|\\btürkçe\\b")) then "turkish"
                       elif ($t | test("(?i)\\bitalian\\b|\\bitaliano\\b")) then "italian"
                       elif ($t | test("(?i)\\bdubbed\\b")) then "dubbed"
                       elif ($t | test("(?i)\\bsubtitled\\b|\\bsub\\b")) then "subtitled"
                       else "unknown" end)
            } ]
        ' 2>/dev/null > "$tmp_dir/addon_${addon_idx}.json"
        JQ_END=$(_now_ns)
        _record_timing "jq:addon_transform:$addon_label" $(( JQ_END - JQ_START ))
        
        stream_count=$(jq 'length' "$tmp_dir/addon_${addon_idx}.json" 2>/dev/null || echo 0)
    fi
    
    PROV_END=$(_now_ns)
    PROVIDER_TIME[$addon_label]=$(( (PROV_END - PROV_START) / 1000000 ))
    PROVIDER_STREAMS[$addon_label]=$stream_count
    TOTAL_PROVIDER_STREAMS=$(( TOTAL_PROVIDER_STREAMS + stream_count ))
    _record_timing "provider:$addon_label:total" $(( PROV_END - PROV_START ))
    
    echo "    → ${stream_count} streams in ${PROVIDER_TIME[$addon_label]}ms"
    addon_idx=$((addon_idx + 1))
done

# --- Vidlink provider ---
echo ""
echo "[3/7] Profiling VidLink provider..."
VIDLINK_START=$(_now_ns)
if [[ -n "$tmdb_id" && "$tmdb_id" != "null" ]]; then
    # Encrypt TMDB ID
    ENC_START=$(_now_ns)
    enc_res=$(_instrumented_curl "vidlink_enc" -s -L --connect-timeout 10 --max-time 30 \
        "${_ENC_DEC_BASE}/api/enc-vidlink?text=${tmdb_id}")
    ENC_END=$(_now_ns)
    _record_timing "vidlink:encrypt" $(( ENC_END - ENC_START ))
    
    enc_token=""
    if printf '%s' "$enc_res" | jq -e . >/dev/null 2>&1; then
        enc_token=$(printf '%s' "$enc_res" | jq -r '.result // empty')
    fi
    
    if [[ -n "$enc_token" && "$enc_token" != "null" ]]; then
        if [[ "$ID" == *:* ]]; then
            IFS=':' read -r -a parts <<< "$ID"
            api_url="${_VIDLINK_BASE}/api/b/tv/${enc_token}/${parts[1]}/${parts[2]}"
        else
            api_url="${_VIDLINK_BASE}/api/b/movie/${enc_token}"
        fi
        
        VFETCH_START=$(_now_ns)
        vl_response=$(_instrumented_curl "vidlink_api" -s -L --connect-timeout 10 --max-time 30 \
            -H "Referer: ${_VIDLINK_BASE}/" \
            -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36" \
            "$api_url")
        VFETCH_END=$(_now_ns)
        _record_timing "vidlink:api_fetch" $(( VFETCH_END - VFETCH_START ))
        
        # Transform
        VJQ_START=$(_now_ns)
        if printf '%s' "$vl_response" | jq -e . >/dev/null 2>&1; then
            printf '%s' "$vl_response" | jq -r '
                .stream // empty |
                if .qualities != null and (.qualities | length) > 0 then
                    .qualities |
                    to_entries |
                    map({
                        quality: .key,
                        url: .value.url,
                        size: (.value.size // "0" | tonumber / 1048576 | floor | tostring + " MB"),
                        provider: "VidLink"
                    }) |
                    sort_by(.quality | tonumber) |
                    reverse
                elif .playlist != null and .playlist != "" then
                    [{ quality: "auto", url: .playlist, size: "unknown", provider: "VidLink" }]
                else
                    []
                end
            ' 2>/dev/null > "$tmp_dir/vidlink.json"
        fi
        VJQ_END=$(_now_ns)
        _record_timing "jq:vidlink_transform" $(( VJQ_END - VJQ_START ))
        
        vl_count=$(jq 'length' "$tmp_dir/vidlink.json" 2>/dev/null || echo 0)
        echo "  VidLink: ${vl_count} streams"
        PROVIDER_STREAMS["VidLink"]=$vl_count
        TOTAL_PROVIDER_STREAMS=$(( TOTAL_PROVIDER_STREAMS + vl_count ))
    else
        echo "  VidLink: no token"
    fi
else
    echo "  VidLink: skipped (no TMDB ID)"
fi
VIDLINK_END=$(_now_ns)
_record_timing "provider:vidlink:total" $(( VIDLINK_END - VIDLINK_START ))
PROVIDER_TIME["VidLink"]=$(( (VIDLINK_END - VIDLINK_START) / 1000000 ))

# --- PlayImdb provider ---
echo ""
echo "[4/7] Profiling PlayImdb provider..."
PLAYIMDB_START=$(_now_ns)
video_url=$(_resolve_playimdb "$ID") || video_url=""
PLAYIMDB_END=$(_now_ns)
_record_timing "provider:playimdb:total" $(( PLAYIMDB_END - PLAYIMDB_START ))
PROVIDER_TIME["PlayImdb"]=$(( (PLAYIMDB_END - PLAYIMDB_START) / 1000000 ))

if [[ -n "$video_url" && "$video_url" != "null" ]]; then
    printf '[{"quality":"auto","url":"%s","size":"unknown","provider":"playimdb"}]\n' "$video_url" > "$tmp_dir/playimdb.json"
    PROVIDER_STREAMS["PlayImdb"]=1
    TOTAL_PROVIDER_STREAMS=$(( TOTAL_PROVIDER_STREAMS + 1 ))
    echo "  PlayImdb: 1 stream"
else
    PROVIDER_STREAMS["PlayImdb"]=0
    echo "  PlayImdb: 0 streams"
fi

# --- JSON merge phase ---
echo ""
echo "[5/7] Profiling JSON merge..."
MERGE_START=$(_now_ns)
merged_json="[]"
merge_count=0
for f in "$tmp_dir"/*.json; do
    [[ -f "$f" ]] || continue
    content=$(cat "$f")
    if [[ -n "$content" && "$content" != "[]" ]]; then
        JQ_MERGE_START=$(_now_ns)
        merged_json=$(printf '%s\n%s' "$merged_json" "$content" | jq -s 'add' 2>/dev/null || echo "$merged_json")
        JQ_MERGE_END=$(_now_ns)
        _record_timing "jq:merge_iteration" $(( JQ_MERGE_END - JQ_MERGE_START ))
        merge_count=$((merge_count + 1))
    fi
done
MERGE_END=$(_now_ns)
_record_timing "phase:json_merge" $(( MERGE_END - MERGE_START ))
echo "  Merged $merge_count files"

# --- Language sort ---
echo ""
echo "[6/7] Profiling language sort..."
SORT_START=$(_now_ns)
merged_json=$(printf '%s' "$merged_json" | jq '
    sort_by(
        if .lang == "unknown" then 1
        elif .lang == "english" then 2
        elif .lang == "original" then 3
        else 0
        end
    )
' 2>/dev/null || echo "$merged_json")
SORT_END=$(_now_ns)
_record_timing "jq:language_sort" $(( SORT_END - SORT_START ))

# --- Quality sort (from movie-cli) ---
QSORT_START=$(_now_ns)
sorted_json=$(printf '%s' "$merged_json" | jq -c '
    def quality_rank:
        if (.quality == "4K" or .quality == "2160p" or .quality == "2160") then 0
        elif (.quality == "2K" or .quality == "1440p" or .quality == "1440") then 1
        elif (.quality == "1080" or .quality == "1080p") then 2
        elif (.quality == "720" or .quality == "720p") then 3
        elif (.quality == "480" or .quality == "480p") then 4
        elif (.quality == "360" or .quality == "360p") then 5
        elif (.quality == "240" or .quality == "240p") then 6
        elif (.quality == "144" or .quality == "144p") then 7
        elif .quality == "auto" then 8
        else 9
        end;
    sort_by(quality_rank)
' 2>/dev/null || printf '%s' "$merged_json")
QSORT_END=$(_now_ns)
_record_timing "jq:quality_sort" $(( QSORT_END - QSORT_START ))

total_streams=$(printf '%s' "$sorted_json" | jq 'length' 2>/dev/null || echo 0)
echo "  Total streams: $total_streams"

# --- Verify streams ---
echo ""
echo "[7/7] Profiling verify_streams..."
VERIFY_START=$(_now_ns)

verified_count=0
failed_count=0
verify_would_have_worked=0

if (( total_streams > 0 )); then
    i=0
    while (( i < total_streams )); do
        url=$(printf '%s' "$sorted_json" | jq -r ".[$i].url // empty" 2>/dev/null)
        provider=$(printf '%s' "$sorted_json" | jq -r ".[$i].provider // \"unknown\"" 2>/dev/null)
        quality=$(printf '%s' "$sorted_json" | jq -r ".[$i].quality // \"auto\"" 2>/dev/null)
        
        if [[ -n "$url" ]]; then
            # Set referer for Vidlink URLs
            referer_arg=()
            if [[ "$url" == *"vidlink"* || "$url" == *"hakunaymatata"* || "$url" == *"vodvidl"* || "$url" == *"stormvv"* ]]; then
                referer_arg=(-H "Referer: https://vidlink.pro/")
            fi
            
            V_START=$(_now_ns)
            http_code=$(curl -so /dev/null -w "%{http_code}" \
                -L --connect-timeout 4 --max-time 8 \
                -H "Range: bytes=0-1023" \
                "${referer_arg[@]}" \
                "$url" 2>/dev/null) || http_code="000"
            V_END=$(_now_ns)
            _record_timing "verify:stream[$i]:$provider" $(( V_END - V_START ))
            
            if [[ "$http_code" =~ ^(200|206)$ ]]; then
                verified_count=$((verified_count + 1))
                echo "    [$i] $provider $quality → $http_code ✓ ($((( V_END - V_START ) / 1000000 ))ms)"
            else
                failed_count=$((failed_count + 1))
                echo "    [$i] $provider $quality → $http_code ✗ ($((( V_END - V_START ) / 1000000 ))ms)"
            fi
        fi
        (( ++i ))
    done
fi

VERIFY_END=$(_now_ns)
_record_timing "phase:verify_streams" $(( VERIFY_END - VERIFY_START ))

OVERALL_END=$(_now_ns)
_record_timing "TOTAL:plugin_get_url+verify" $(( OVERALL_END - OVERALL_START ))

# ═══════════════════════════════════════════════════════════════
# Now profile the PARALLEL execution (as the plugin actually runs)
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  PARALLEL EXECUTION (as plugin actually runs)"
echo "═══════════════════════════════════════════════════════════════"

PARALLEL_START=$(_now_ns)
tmp_dir2=$(mktemp -d)
pids=()

# Addon providers (parallel)
addon_idx=0
for addon_url in "${addon_list[@]}"; do
    addon_url="${addon_url#"${addon_url%%[![:space:]]*}"}"
    addon_url="${addon_url%"${addon_url##*[![:space:]]}"}"
    [[ -z "$addon_url" ]] && continue
    addon_url="${addon_url%/manifest.json}"
    
    (
        addon_api="${addon_url}/stream/${type}/${ID}.json"
        addon_res=$(curl -s -L --connect-timeout 10 --max-time 30 \
            -H "User-Agent: movie-cli/$VERSION" \
            "$addon_api" 2>/dev/null) || true
        
        if printf '%s' "$addon_res" | jq -e .streams >/dev/null 2>&1; then
            printf '%s' "$addon_res" | jq -c '
                [ .streams[] | select(.url != null) |
                  ((.title // "") + " " + (.description // "") + " " + (.name // "")) as $t | {
                    quality: (if ($t | test("(?i)4k|2160p|2160")) then "4K"
                              elif ($t | test("(?i)1080p|1080")) then "1080"
                              elif ($t | test("(?i)720p|720")) then "720"
                              elif ($t | test("(?i)480p|480")) then "480"
                              else "auto" end),
                    url: .url,
                    size: "unknown",
                    provider: ((.name // "Addon") | gsub("\\n"; " "))
                } ]
            ' 2>/dev/null > "$tmp_dir2/addon_${addon_idx}.json"
        fi
    ) &
    pids+=($!)
    addon_idx=$((addon_idx + 1))
done

# VidLink (parallel)
if [[ -n "$tmdb_id" && "$tmdb_id" != "null" ]]; then
    (
        enc_res=$(curl -s -L --connect-timeout 10 --max-time 30 \
            "${_ENC_DEC_BASE}/api/enc-vidlink?text=${tmdb_id}" 2>/dev/null)
        enc_token=$(printf '%s' "$enc_res" | jq -r '.result // empty' 2>/dev/null)
        
        if [[ -n "$enc_token" && "$enc_token" != "null" ]]; then
            if [[ "$ID" == *:* ]]; then
                IFS=':' read -r -a parts <<< "$ID"
                api_url="${_VIDLINK_BASE}/api/b/tv/${enc_token}/${parts[1]}/${parts[2]}"
            else
                api_url="${_VIDLINK_BASE}/api/b/movie/${enc_token}"
            fi
            
            response=$(curl -s -L --connect-timeout 10 --max-time 30 \
                -H "Referer: ${_VIDLINK_BASE}/" \
                -H "User-Agent: Mozilla/5.0" \
                "$api_url" 2>/dev/null)
            
            if printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
                printf '%s' "$response" | jq -r '
                    .stream // empty |
                    if .qualities != null and (.qualities | length) > 0 then
                        .qualities | to_entries | map({
                            quality: .key, url: .value.url,
                            size: "unknown", provider: "VidLink"
                        })
                    elif .playlist != null and .playlist != "" then
                        [{ quality: "auto", url: .playlist, size: "unknown", provider: "VidLink" }]
                    else [] end
                ' 2>/dev/null > "$tmp_dir2/vidlink.json"
            fi
        fi
    ) &
    pids+=($!)
fi

# PlayImdb (parallel)
(
    video_url=$(_resolve_playimdb "$ID") || video_url=""
    if [[ -n "$video_url" && "$video_url" != "null" ]]; then
        printf '[{"quality":"auto","url":"%s","size":"unknown","provider":"playimdb"}]\n' "$video_url" > "$tmp_dir2/playimdb.json"
    fi
) &
pids+=($!)

WAIT_START=$(_now_ns)
wait "${pids[@]}" 2>/dev/null || true
WAIT_END=$(_now_ns)
_record_timing "parallel:wait_all" $(( WAIT_END - WAIT_START ))

# Merge
PMERGE_START=$(_now_ns)
par_merged="[]"
for f in "$tmp_dir2"/*.json; do
    [[ -f "$f" ]] || continue
    content=$(cat "$f")
    if [[ -n "$content" && "$content" != "[]" ]]; then
        par_merged=$(printf '%s\n%s' "$par_merged" "$content" | jq -s 'add' 2>/dev/null || echo "$par_merged")
    fi
done
PMERGE_END=$(_now_ns)
_record_timing "parallel:merge" $(( PMERGE_END - PMERGE_START ))

PARALLEL_END=$(_now_ns)
_record_timing "TOTAL:parallel_providers" $(( PARALLEL_END - PARALLEL_START ))

par_stream_count=$(printf '%s' "$par_merged" | jq 'length' 2>/dev/null || echo 0)
echo "  Parallel providers completed in $(( (PARALLEL_END - PARALLEL_START) / 1000000 ))ms"
echo "  Parallel streams: $par_stream_count"

rm -rf "$tmp_dir" "$tmp_dir2" 2>/dev/null

# ═══════════════════════════════════════════════════════════════
# Process counting: how many subprocesses does a real run spawn?
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "              SUBPROCESS ANALYSIS"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Count jq invocations in the plugin
jq_count=$(grep -c 'jq ' "$SCRIPT_DIR/plugins/cinestream.sh" 2>/dev/null || echo 0)
curl_count=$(grep -c 'curl ' "$SCRIPT_DIR/plugins/cinestream.sh" 2>/dev/null || echo 0)
python_count=$(grep -c 'python3 ' "$SCRIPT_DIR/plugins/cinestream.sh" 2>/dev/null || echo 0)
sed_count=$(grep -c 'sed ' "$SCRIPT_DIR/plugins/cinestream.sh" 2>/dev/null || echo 0)

echo "Static analysis of cinestream.sh:"
echo "  curl invocations:    $curl_count"
echo "  jq invocations:      $jq_count"
echo "  python3 invocations: $python_count"
echo "  sed invocations:     $sed_count"

# Count in movie-cli main (verify_streams, sort_streams)
echo ""
echo "Static analysis of movie-cli (verify/sort):"
jq_main=$(grep -c 'jq ' "$SCRIPT_DIR/movie-cli" 2>/dev/null || echo 0)
curl_main=$(grep -c 'curl ' "$SCRIPT_DIR/movie-cli" 2>/dev/null || echo 0)
echo "  curl invocations:    $curl_main"
echo "  jq invocations:      $jq_main"
echo "  Per verify_streams: curl per stream ($total_streams streams = $total_streams curls)"
echo "  Per verify_streams: jq per stream ($total_streams streams × 3 calls = $(( total_streams * 3 )) jq)"

# ═══════════════════════════════════════════════════════════════
# Verification analysis
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "              VERIFICATION ANALYSIS"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Total streams:            $total_streams"
echo "  Verified (200/206):       $verified_count"
echo "  Failed verification:      $failed_count"
echo "  Verification time:        $(( (VERIFY_END - VERIFY_START) / 1000000 ))ms"
if (( total_streams > 0 )); then
    echo "  Avg verification/stream:  $(( (VERIFY_END - VERIFY_START) / total_streams / 1000000 ))ms"
    echo "  Verification % of total:  $(( (VERIFY_END - VERIFY_START) * 100 / (OVERALL_END - OVERALL_START) ))%"
fi
echo "  Pass rate:                $(( verified_count * 100 / (total_streams > 0 ? total_streams : 1) ))%"

# ═══════════════════════════════════════════════════════════════
# Provider timing summary
# ═══════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "              PROVIDER TIMING SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo ""
printf '%-45s %8s %8s\n' "Provider" "Time" "Streams"
printf '%-45s %8s %8s\n' "---------------------------------------------" "--------" "--------"
for prov in "${!PROVIDER_TIME[@]}"; do
    printf '%-45s %7dms %8s\n' "$prov" "${PROVIDER_TIME[$prov]}" "${PROVIDER_STREAMS[$prov]:-0}"
done

# ═══════════════════════════════════════════════════════════════
# Full timing report
# ═══════════════════════════════════════════════════════════════
_print_report

rm -rf "$_PROFILE_TMPDIR" 2>/dev/null
echo ""
echo "Done."
