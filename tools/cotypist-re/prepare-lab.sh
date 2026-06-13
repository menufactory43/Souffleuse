#!/bin/bash
set -euo pipefail

SOURCE_APP="${1:-/Applications/Cotypist.app}"
LAB_APP="${2:-/tmp/CotypistLab.app}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTITLEMENTS="$SCRIPT_DIR/lab.entitlements"
LAB_BUNDLE_ID="app.cocotypist.CotypistLab"
LAB_HOME="${COTYPIST_LAB_HOME:-/tmp/CotypistLabHome}"
SIGN_IDENTITY="${COTYPIST_LAB_SIGN_IDENTITY:--}"
LAB_SUPPORT="$LAB_HOME/Library/Application Support/$LAB_BUNDLE_ID"
SOURCE_MODEL="$(
    /usr/bin/find "$HOME/Library" \
        -name 'gemma-3-1b.i1-Q5_K_M.gguf' \
        -print \
        -quit \
        2>/dev/null \
        || true
)"

if [[ ! -d "$SOURCE_APP" ]]; then
    echo "Source app not found: $SOURCE_APP" >&2
    exit 1
fi

rm -rf "$LAB_APP"
ditto "$SOURCE_APP" "$LAB_APP"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $LAB_BUNDLE_ID" "$LAB_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName Cotypist Lab" "$LAB_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Cotypist Lab" "$LAB_APP/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Cotypist Lab" "$LAB_APP/Contents/Info.plist"

# Keep the lab profile isolated. Only link the static 1B model; no history or DB.
rm -rf "$LAB_SUPPORT"
mkdir -p "$LAB_SUPPORT/Models"
if [[ -f "$SOURCE_MODEL" ]]; then
    ln -s "$SOURCE_MODEL" "$LAB_SUPPORT/Models/$(basename "$SOURCE_MODEL")"
else
    echo "Model not found: $SOURCE_MODEL" >&2
    exit 1
fi

mkdir -p "$LAB_HOME/Library/Preferences"
LAB_DEFAULTS="$LAB_HOME/Library/Preferences/$LAB_BUNDLE_ID.plist"
defaults delete "$LAB_DEFAULTS" >/dev/null 2>&1 || true
defaults write "$LAB_DEFAULTS" OnboardingProgress -int 100
defaults write "$LAB_DEFAULTS" completedOnboardingControllers -array \
    ModelSetupOnboardingController \
    AccessibilityOnboardingController \
    ScreenRecordingOnboardingController \
    CustomPromptOnboardingController \
    AutocompleteOnboardingController
defaults write "$LAB_DEFAULTS" PromptCoordinator_eligibilityFlag -bool true
defaults write "$LAB_DEFAULTS" PromptCoordinator_featureFlagSet -array 91
defaults write "$LAB_DEFAULTS" ModelRepository_selectedModel "gemma-3-1b-pt.i1-Q5_K_M"
defaults write "$LAB_DEFAULTS" CompletionManager_maxCompletionLength -int 4
defaults write "$LAB_DEFAULTS" CompletionManager_userPrompt ""
defaults write "$LAB_DEFAULTS" TextFieldContextCapture_screenshotContextEnabled -bool false
defaults write "$LAB_DEFAULTS" TrainingDataCollector_enabled -bool false

# Sign nested Mach-O files first, then their containing bundles, inside-out.
while IFS= read -r code; do
    if file "$code" | grep -q 'Mach-O'; then
        codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$code"
    fi
done < <(
    /usr/bin/find "$LAB_APP/Contents" -type f \
        ! -path "$LAB_APP/Contents/MacOS/Cotypist" \
        -print
)

while IFS= read -r bundle; do
    codesign --force --sign "$SIGN_IDENTITY" --timestamp=none "$bundle"
done < <(
    /usr/bin/find "$LAB_APP/Contents" -depth -type d \
        \( -name '*.framework' -o -name '*.xpc' -o -name '*.app' \) \
        -print
)

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --timestamp=none \
    --entitlements "$ENTITLEMENTS" \
    "$LAB_APP"

codesign --verify --deep --strict --verbose=2 "$LAB_APP"
codesign -d --entitlements :- "$LAB_APP" 2>/dev/null
echo "Prepared: $LAB_APP"
echo "Bundle ID: $LAB_BUNDLE_ID"
echo "Lab home: $LAB_HOME"
echo "Lab data: $LAB_SUPPORT"
