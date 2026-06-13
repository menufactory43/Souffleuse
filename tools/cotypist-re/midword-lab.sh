#!/bin/bash
set -euo pipefail

APP_BINARY="/Applications/Cotypist.app/Contents/MacOS/Cotypist"
LAB_HOME="${COTYPIST_LAB_HOME:-/tmp/CotypistLabHome}"
OUTPUT_DIR="${1:-/tmp/cotypist-midword-run}"
SAMPLE_SECONDS="${COTYPIST_SAMPLE_SECONDS:-8}"
BASELINE_TEXT="The capital of France is "

if [[ -d "$LAB_HOME" ]]; then
    LAB_HOME="$(cd "$LAB_HOME" && pwd -P)"
fi

pid="$(
    pgrep -f "^${APP_BINARY}$" \
        | head -1
)"

if [[ -z "$pid" ]]; then
    echo "Cotypist is not running." >&2
    exit 1
fi

if [[ "${COTYPIST_ALLOW_REAL_HOME:-0}" != "1" ]] \
    && ! lsof -p "$pid" | /usr/bin/grep "$LAB_HOME" >/dev/null; then
    echo "Refusing to test a non-isolated Cotypist process (pid $pid)." >&2
    echo "Launch the official binary with HOME=$LAB_HOME first." >&2
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

prepare_baseline() {
    osascript - "$BASELINE_TEXT" <<'APPLESCRIPT'
on run argv
    set sampleText to item 1 of argv
    tell application "TextEdit"
        activate
        if (count of documents) = 0 then make new document
    end tell
    delay 0.4
    tell application "System Events"
        tell process "TextEdit"
            set frontmost to true
            keystroke "a" using command down
            repeat with index from 1 to count characters of sampleText
                keystroke character index of sampleText
                delay 0.08
            end repeat
        end tell
    end tell
    delay 5
end run
APPLESCRIPT
}

run_case() {
    local label="$1"
    local character="$2"
    local sample_file="$OUTPUT_DIR/$label.sample.txt"

    prepare_baseline
    screencapture -x "$OUTPUT_DIR/$label-baseline.png"

    sample "$pid" "$SAMPLE_SECONDS" -file "$sample_file" \
        >"$OUTPUT_DIR/$label.sample.log" 2>&1 &
    local sampler_pid=$!

    osascript - "$character" <<'APPLESCRIPT'
on run argv
    delay 1
    tell application "TextEdit" to activate
    tell application "System Events"
        tell process "TextEdit"
            set frontmost to true
            keystroke item 1 of argv
        end tell
    end tell
    delay 0.12
end run
APPLESCRIPT

    screencapture -x "$OUTPUT_DIR/$label-120ms.png"
    sleep 0.6
    screencapture -x "$OUTPUT_DIR/$label-900ms.png"
    sleep 2
    screencapture -x "$OUTPUT_DIR/$label-3s.png"
    wait "$sampler_pid"

    printf '%s decode=%s tokenize=%s seq_keep=%s seq_rm=%s seq_cp=%s\n' \
        "$label" \
        "$(/usr/bin/grep -c 'llama_decode' "$sample_file" || true)" \
        "$(/usr/bin/grep -c 'llama_vocab::tokenize' "$sample_file" || true)" \
        "$(/usr/bin/grep -Ec 'llama_(memory|kv_cache).*seq_keep' "$sample_file" || true)" \
        "$(/usr/bin/grep -Ec 'llama_(memory|kv_cache).*seq_rm' "$sample_file" || true)" \
        "$(/usr/bin/grep -Ec 'llama_(memory|kv_cache).*seq_cp' "$sample_file" || true)"
}

echo "Cotypist pid: $pid"
echo "Output: $OUTPUT_DIR"
run_case "match-P" "P"
run_case "mismatch-X" "X"
echo "Inspect the baseline, 120ms, 900ms, and 3s PNG files in $OUTPUT_DIR."
