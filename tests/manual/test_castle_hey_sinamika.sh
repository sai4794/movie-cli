#!/usr/bin/env bash
# Test: How many streams does castle plugin return for "Hey Sinamika"?
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/errors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/ui.sh"
source "$SCRIPT_DIR/lib/player.sh"
source "$SCRIPT_DIR/lib/history.sh"

init_dirs
create_default_config
load_all_config

# Source the castle plugin
source "$SCRIPT_DIR/plugins/castle.sh"

echo "========================================="
echo "STEP 1: Search for 'Hey Sinamika' via CastleTv"
echo "========================================="
search_results=$(plugin_search "Hey Sinamika" "720" 2>/dev/null) || { echo "SEARCH FAILED"; exit 1; }
echo "Raw search results:"
echo "$search_results" | jq '.' 2>/dev/null || echo "$search_results"

result_count=$(printf '%s' "$search_results" | jq 'length' 2>/dev/null || echo 0)
echo ""
echo "Total search results: $result_count"

if [[ "$result_count" == "0" ]]; then
    echo "No results found. Exiting."
    exit 0
fi

# Pick first movie result
echo ""
echo "========================================="
echo "STEP 2: Get streams for first result"
echo "========================================="
first_id=$(printf '%s' "$search_results" | jq -r '.[0].id // empty' 2>/dev/null)
first_title=$(printf '%s' "$search_results" | jq -r '.[0].title // empty' 2>/dev/null)
first_type=$(printf '%s' "$search_results" | jq -r '.[0].type // empty' 2>/dev/null)
echo "Selected: $first_title (id=$first_id, type=$first_type)"
echo ""

echo "Resolving streams..."
streams_json=$(plugin_get_url "$first_id" "720" 2>/dev/null) || { echo "GET_URL FAILED (exit $?)"; streams_json="[]"; }

stream_count=$(printf '%s' "$streams_json" | jq 'length' 2>/dev/null || echo 0)
echo ""
echo "========================================="
echo "RESULTS"  
echo "========================================="
echo "Total streams returned: $stream_count"
echo ""

if [[ "$stream_count" != "0" && "$streams_json" != "[]" ]]; then
    echo "Stream details:"
    printf '%s' "$streams_json" | jq -r '.[] | "  [\(.quality // "?")] \(.provider // "?") → \(.url // "?" | .[0:100])..."' 2>/dev/null || echo "$streams_json"
    
    echo ""
    echo "========================================="
    echo "STEP 3: Verify playability of each stream"
    echo "========================================="
    printf '%s' "$streams_json" | jq -r '.[].url' 2>/dev/null | while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        http_code=$(curl -so /dev/null -w "%{http_code}" -L --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || echo "000")
        hex=$(curl -s -L --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | head -c 16 | xxd -p 2>/dev/null || echo "")
        
        playable="NO"
        if [[ "$http_code" =~ ^(200|206)$ ]]; then
            if [[ "$hex" =~ ^(234558544d3355|23455854494e46) ]]; then
                playable="YES (m3u8)"
            elif [[ "$hex" =~ (66747970) ]]; then
                playable="YES (mp4)"
            elif [[ "$hex" =~ ^1a45dfa3 ]]; then
                playable="YES (mkv/webm)"
            elif [[ "$hex" =~ ^47 ]]; then
                playable="YES (mpeg-ts)"
            else
                playable="MAYBE (http=$http_code, hex=${hex:0:16})"
            fi
        else
            playable="NO (http=$http_code)"
        fi
        echo "  $playable | ${url:0:80}..."
    done
else
    echo "No streams found!"
fi

echo ""
echo "========================================="
echo "STEP 4: Test via CLI workflow (search-only)"
echo "========================================="
echo "Running: movie-cli -p castle -s 'Hey Sinamika'"
"$SCRIPT_DIR/movie-cli" -p castle -s "Hey Sinamika" 2>&1 || echo "(CLI exited with $?)"

echo ""
echo "DONE"
