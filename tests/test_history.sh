#!/usr/bin/env bats
# test_history.sh — Tests for history functions

load 'setup'

@test "history_add creates entry" {
    history_add "Test Movie" "testplugin" "123" "movie"
    [[ -f "$HISTORY_FILE" ]]
    local count=$(wc -l < "$HISTORY_FILE")
    [[ "$count" -eq 1 ]]
}

@test "history_add appends multiple entries" {
    history_add "Movie 1" "plugin" "1" "movie"
    history_add "Movie 2" "plugin" "2" "movie"
    local count=$(wc -l < "$HISTORY_FILE")
    [[ "$count" -eq 2 ]]
}

@test "history_get_last returns most recent entry" {
    history_add "First" "plugin" "1" "movie"
    history_add "Second" "plugin" "2" "movie"
    local last=$(history_get_last)
    [[ "$last" == *"Second"* ]]
}

@test "history_get_last fails on empty history" {
    run history_get_last
    assert_failure
}

@test "history_list returns entries newest first" {
    history_add "First" "plugin" "1" "movie"
    history_add "Second" "plugin" "2" "movie"
    history_add "Third" "plugin" "3" "movie"
    local result=$(history_list 2)
    [[ "$result" == *"Third"* ]]
    [[ "$result" == *"Second"* ]]
    [[ "$result" != *"First"* ]]
}

@test "history_list handles empty history" {
    result=$(history_list 5)
    [[ -z "$result" ]]
}

@test "history_clear removes all entries" {
    history_add "Movie" "plugin" "1" "movie"
    history_clear
    local count=$(history_count)
    [[ "$count" -eq 0 ]]
}

@test "history_delete removes entry by index" {
    history_add "First" "plugin" "1" "movie"
    history_add "Second" "plugin" "2" "movie"
    history_add "Third" "plugin" "3" "movie"
    history_delete 2  # Delete middle entry
    local count=$(history_count)
    [[ "$count" -eq 2 ]]
    local result=$(cat "$HISTORY_FILE")
    [[ "$result" == *"First"* ]]
    [[ "$result" == *"Third"* ]]
    [[ "$result" != *"Second"* ]]
}

@test "history_prune keeps only N entries" {
    for i in $(seq 1 10); do
        history_add "Movie $i" "plugin" "$i" "movie"
    done
    history_prune 3
    local count=$(history_count)
    [[ "$count" -eq 3 ]]
}

@test "history_count returns 0 for empty history" {
    local count=$(history_count)
    [[ "$count" -eq 0 ]]
}

@test "history_add stores correct JSON format" {
    history_add "Test" "myplugin" "42" "series"
    local entry=$(cat "$HISTORY_FILE")
    [[ "$entry" == *'"title":"Test"'* ]]
    [[ "$entry" == *'"plugin":"myplugin"'* ]]
    [[ "$entry" == *'"id":"42"'* ]]
    [[ "$entry" == *'"type":"series"'* ]]
    [[ "$entry" == *'"v":1'* ]]
}

@test "history_update_progress updates only the last entry matching id" {
    history_add "Movie 1" "plugin" "1" "movie"
    history_add "Movie 2" "plugin" "2" "movie"
    history_add "Movie 1" "plugin" "1" "movie"

    history_update_progress "1" 50 200

    local -a entries
    mapfile -t entries < "$HISTORY_FILE"

    # First entry (id: 1) should remain unchanged (progress 0)
    [[ "${entries[0]}" == *'"id":"1"'* ]]
    [[ "${entries[0]}" == *'"progress":0'* ]]

    # Second entry (id: 2) should remain unchanged (progress 0)
    [[ "${entries[1]}" == *'"id":"2"'* ]]
    [[ "${entries[1]}" == *'"progress":0'* ]]

    # Third entry (id: 1, last) should be updated (progress 50, duration 200)
    [[ "${entries[2]}" == *'"id":"1"'* ]]
    [[ "${entries[2]}" == *'"progress":50'* ]]
    [[ "${entries[2]}" == *'"duration":200'* ]]
}

@test "history_update_progress fails cleanly on corrupt history" {
    # Regression (d67859e): jq -s chokes on a non-JSON line and the function
    # returns 1 — the CLI call sites must tolerate that instead of letting
    # set -e abort playback AFTER it already succeeded.
    printf 'not-json\n' > "$HISTORY_FILE"
    run history_update_progress "1" 50 200
    assert_failure
    # History file must remain untouched (no partial write)
    [[ "$(cat "$HISTORY_FILE")" == "not-json" ]]
}

@test "call-site pattern tolerates corrupt history under set -e" {
    # The exact pattern movie-cli uses after playback:
    #   local end_pos; end_pos=$(get_mpv_position ... || echo 0)
    #   (( end_pos > 0 )) && history_update_progress "..." "..." "..." || true
    # NOTE: end_pos must be declared+assigned first — under set -u an unset
    # var in (( )) is an unbound-variable abort (that is why movie-cli
    # always assigns before the guard).
    printf 'not-json\n' > "$HISTORY_FILE"
    history_update_progress "1" 50 200 || true
    [[ "$(cat "$HISTORY_FILE")" == "not-json" ]]
    local end_pos=100
    set -e
    (( end_pos > 0 )) && history_update_progress "1" 50 200 || true
    [[ "$(cat "$HISTORY_FILE")" == "not-json" ]]
    # zero/absent position: guard short-circuits, still no abort
    end_pos=0
    (( end_pos > 0 )) && history_update_progress "1" 50 200 || true
    [[ "$(cat "$HISTORY_FILE")" == "not-json" ]]
}
