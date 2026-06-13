#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAB_APP="${COTYPIST_LAB_APP:-/tmp/CotypistLab.app}"
LAB_HOME="${COTYPIST_LAB_HOME:-/tmp/CotypistLabHome}"
PROBE_DYLIB="${COTYPIST_BRANCH_PROBE:-/tmp/libcotypist-branch-probe.dylib}"
PROBE_LOG="${COTYPIST_BRANCH_LOG:-/tmp/cotypist-branch.log}"
SIGN_IDENTITY="${COTYPIST_LAB_SIGN_IDENTITY:--}"

if [[ ! -d "$LAB_APP" ]]; then
    COTYPIST_LAB_SIGN_IDENTITY="$SIGN_IDENTITY" \
        "$SCRIPT_DIR/prepare-lab.sh" /Applications/Cotypist.app "$LAB_APP"
fi

clang \
    -dynamiclib \
    -arch arm64 \
    -Wall \
    -Wextra \
    -Werror \
    "$SCRIPT_DIR/branch-probe.c" \
    -o "$PROBE_DYLIB"

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    "$PROBE_DYLIB"

rm -f "$PROBE_LOG"
echo "Probe log: $PROBE_LOG"
echo "Use synthetic text only. Stop the lab with Ctrl-C."

HOME="$LAB_HOME" \
CFFIXED_USER_HOME="$LAB_HOME" \
CFPREFERENCES_AVOID_DAEMON=1 \
DYLD_INSERT_LIBRARIES="$PROBE_DYLIB" \
COTYPIST_BRANCH_LOG="$PROBE_LOG" \
"$LAB_APP/Contents/MacOS/Cotypist"
