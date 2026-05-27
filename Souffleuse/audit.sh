#!/usr/bin/env bash
# Privacy audit: enforce that the shipping binary (Souffleuse + its libs)
# cannot leak user text via logs. CLI probes (SouffleuseAXProbe,
# SouffleuseContextProbe) and benches are dev-only and excluded.
set -e

SHIPPING_DIRS=(
  "Sources/Souffleuse"
  "Sources/SouffleuseAX"
  "Sources/SouffleuseContext"
  "Sources/SouffleuseCore"
  "Sources/SouffleuseInput"
  "Sources/SouffleuseLog"
  "Sources/SouffleuseOverlay"
  "Sources/SouffleusePersonalization"
  "Sources/SouffleusePrompt"
)

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

fail=0

echo "=== 1. No print() in shipping targets ==="
hits=$(grep -rn --include="*.swift" -E '^\s*print\(' "${SHIPPING_DIRS[@]}" 2>/dev/null || true)
if [ -n "$hits" ]; then red "FAIL: print() found"; echo "$hits"; fail=1
else green "OK"; fi

echo "=== 2. No NSLog in shipping targets ==="
hits=$(grep -rn --include="*.swift" 'NSLog(' "${SHIPPING_DIRS[@]}" 2>/dev/null || true)
if [ -n "$hits" ]; then red "FAIL: NSLog found"; echo "$hits"; fail=1
else green "OK"; fi

echo "=== 3. No os_log with user-text interpolation ==="
hits=$(grep -rn --include="*.swift" -E 'os_log.*%@.*(text|clipboard|prompt|suggestion|userText|enriched)' "${SHIPPING_DIRS[@]}" 2>/dev/null || true)
if [ -n "$hits" ]; then red "FAIL: os_log of user text"; echo "$hits"; fail=1
else green "OK"; fi

echo "=== 4. Log file fields are whitelisted ==="
LOG=~/Library/Logs/Souffleuse.log
if [ -f "$LOG" ]; then
  if ! command -v jq >/dev/null; then
    red "WARN: jq not installed, skipping field check"
  else
    actual=$(jq -r 'keys[]' "$LOG" | sort -u | tr '\n' ' ')
    expected="count event level module ts "
    expected_no_count="event level module ts "
    if [ "$actual" != "$expected" ] && [ "$actual" != "$expected_no_count" ]; then
      red "FAIL: unexpected fields in log"
      echo "  expected: $expected (or without 'count')"
      echo "  actual:   $actual"
      fail=1
    else
      green "OK ($(wc -l < "$LOG" | tr -d ' ') lines)"
    fi
  fi
else
  green "OK (no log file yet)"
fi

echo "=== 5. corpus (history.db / legacy history.aes) never read outside Personalization + HistoryViewer ==="
# Phase 2: the encrypted SQLite corpus (history.db) is the corpus source.
# history.aes only survives as the legacy migration source inside the store.
# Both must stay confined to TypingHistoryStore.swift + HistoryViewerWindow.swift.
hits=$(grep -rn --include="*.swift" -E 'history\.(db|aes)' "${SHIPPING_DIRS[@]}" 2>/dev/null \
  | grep -v 'TypingHistoryStore\.swift\|HistoryViewerWindow\.swift' || true)
if [ -n "$hits" ]; then red "FAIL: corpus file referenced outside allowed paths"; echo "$hits"; fail=1
else green "OK"; fi

echo "=== 6. No raw acceptance text logged (interpolated user fields) ==="
hits=$(grep -rn --include="*.swift" -E 'Log\.(info|warn|error)\([^"]*\\\(.*(accepted|contextBefore|entry\.|prefix)' "${SHIPPING_DIRS[@]}" 2>/dev/null || true)
if [ -n "$hits" ]; then red "FAIL: Log call interpolating user fields"; echo "$hits"; fail=1
else green "OK"; fi

if [ $fail -eq 0 ]; then
  green "=== AUDIT PASSED ==="
else
  red "=== AUDIT FAILED ==="
  exit 1
fi
