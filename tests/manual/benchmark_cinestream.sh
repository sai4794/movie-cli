#!/usr/bin/env bash
# benchmark_cinestream.sh — Benchmark CineStream stream discovery
# Measures plugin_get_url timing across multiple titles, multiple runs
# Usage: bash tests/benchmark_cinestream.sh [runs_per_title]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS="${1:-5}"

# Source dependencies
source "$SCRIPT_DIR/lib/init.sh"
source "$SCRIPT_DIR/lib/errors.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/cache.sh"
source "$SCRIPT_DIR/lib/ui.sh"

# Stub UI functions to suppress output
debug() { :; }
warn() { :; }
die_plugin() { echo "[FAIL] $*" >&2; return 1; }
status_msg() { :; }
spinner_start() { :; }
spinner_stop() { :; }
ui_info() { :; }

init_dirs
create_default_config 2>/dev/null || true
load_all_config 2>/dev/null || true

# Source plugin
source "$SCRIPT_DIR/plugins/cinestream.sh"

# Source sort_streams from movie-cli (it's defined there)
sort_streams() {
    local json="$1"
    printf '%s' "$json" | jq -c '
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
    ' 2>/dev/null || printf '%s' "$json"
}

_now_ns() {
    date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000))
}

# Test titles
declare -A TITLES=(
    ["Inception"]="tt1375666"
    ["MoneyHeist"]="tt6468322:3:1"
    ["Avatar"]="tt0499549"
    ["Wednesday"]="tt13443470:1:1"
    ["Friends"]="tt0108778:1:1"
    ["TheOffice"]="tt0386676:1:1"
)

RESULTS_FILE=$(mktemp)

echo "═══════════════════════════════════════════════════════════════"
echo "  CineStream Benchmark — $RUNS runs per title"
echo "  $(date -Iseconds 2>/dev/null || date)"
echo "═══════════════════════════════════════════════════════════════"
echo ""

for title in Inception MoneyHeist Avatar Wednesday Friends TheOffice; do
    id="${TITLES[$title]}"
    echo "━━━ $title ($id) ━━━"
    
    declare -a timings=()
    declare -a stream_counts=()
    
    for (( run=1; run<=RUNS; run++ )); do
        start=$(_now_ns)
        
        # Run plugin_get_url (the actual function under test)
        streams_json=$(plugin_get_url "$id" "720" 2>/dev/null) || streams_json="[]"
        streams_json=$(sort_streams "$streams_json")
        
        end=$(_now_ns)
        elapsed_ms=$(( (end - start) / 1000000 ))
        
        stream_count=$(printf '%s' "$streams_json" | jq 'length' 2>/dev/null || echo 0)
        
        timings+=($elapsed_ms)
        stream_counts+=($stream_count)
        
        echo "  Run $run: ${elapsed_ms}ms ($stream_count streams)"
    done
    
    # Calculate stats
    IFS=$'\n' sorted=($(printf '%s\n' "${timings[@]}" | sort -n))
    unset IFS
    
    min=${sorted[0]}
    max=${sorted[$((${#sorted[@]}-1))]}
    
    sum=0
    for t in "${timings[@]}"; do
        sum=$((sum + t))
    done
    avg=$((sum / ${#timings[@]}))
    
    # Median
    mid=$(( ${#sorted[@]} / 2 ))
    if (( ${#sorted[@]} % 2 == 0 )); then
        median=$(( (sorted[mid-1] + sorted[mid]) / 2 ))
    else
        median=${sorted[$mid]}
    fi
    
    # P95 (for 5 runs, this is the max)
    p95_idx=$(( ${#sorted[@]} * 95 / 100 ))
    (( p95_idx >= ${#sorted[@]} )) && p95_idx=$(( ${#sorted[@]} - 1 ))
    p95=${sorted[$p95_idx]}
    
    # Average stream count
    ssum=0
    for s in "${stream_counts[@]}"; do
        ssum=$((ssum + s))
    done
    avg_streams=$((ssum / ${#stream_counts[@]}))
    
    echo ""
    printf '  %-15s %7dms\n' "Min:" "$min"
    printf '  %-15s %7dms\n' "Max:" "$max"
    printf '  %-15s %7dms\n' "Average:" "$avg"
    printf '  %-15s %7dms\n' "Median:" "$median"
    printf '  %-15s %7dms\n' "P95:" "$p95"
    printf '  %-15s %7d\n' "Avg streams:" "$avg_streams"
    echo ""
    
    # Save to results file
    printf '%s\t%d\t%d\t%d\t%d\t%d\t%d\n' "$title" "$min" "$max" "$avg" "$median" "$p95" "$avg_streams" >> "$RESULTS_FILE"
    
    unset timings stream_counts
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "                    SUMMARY TABLE"
echo "═══════════════════════════════════════════════════════════════"
echo ""
printf '%-15s %8s %8s %8s %8s %8s %8s\n' "Title" "Min" "Max" "Avg" "Median" "P95" "Streams"
printf '%-15s %8s %8s %8s %8s %8s %8s\n' "───────────────" "────────" "────────" "────────" "────────" "────────" "────────"

while IFS=$'\t' read -r title min max avg median p95 streams; do
    printf '%-15s %7dms %7dms %7dms %7dms %7dms %8d\n' "$title" "$min" "$max" "$avg" "$median" "$p95" "$streams"
done < "$RESULTS_FILE"

echo ""
rm -f "$RESULTS_FILE"
echo "Done."
