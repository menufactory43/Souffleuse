#!/usr/bin/env bash
# Build Souffleuse.app from the xcodebuild output + Resources/Info.plist.
# Use this until we have a proper Xcode project or swift-bundler integration.
set -euo pipefail

cd "$(dirname "$0")"

BUILD_DIR="build/Build/Products/Debug"
APP_NAME="Souffleuse"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> xcodebuild..."
xcodebuild -scheme "$APP_NAME" -derivedDataPath ./build -destination "platform=macOS" build \
  -quiet \
  | tail -5

if [ ! -x "$BUILD_DIR/$APP_NAME" ]; then
  echo "Binary not found at $BUILD_DIR/$APP_NAME"
  exit 1
fi

echo "==> Building .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy the mlx-swift_Cmlx.bundle (metallib) so MLX can find its Metal kernels.
if [ -d "$BUILD_DIR/mlx-swift_Cmlx.bundle" ]; then
  cp -R "$BUILD_DIR/mlx-swift_Cmlx.bundle" "$APP_BUNDLE/Contents/Resources/"
fi

# Copy any other resource bundles produced by SPM (per-target bundles).
for b in "$BUILD_DIR"/*.bundle; do
  [ -d "$b" ] || continue
  cp -R "$b" "$APP_BUNDLE/Contents/Resources/"
done

# Make the executable, well, executable.
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Sign with a stable Apple Development cert rather than ad-hoc.
# Ad-hoc signing gives a fresh cdhash every rebuild, which makes TCC treat
# each build as a brand-new app and silently invalidate previously-granted
# Accessibility / Screen Recording permissions. A real cert produces a
# stable Designated Requirement and cdhash family, so TCC entries persist
# across rebuilds and the user only has to grant permissions once.
#
# SIGN_IDENTITY can be overridden via env var (e.g. switch back to "-" for
# ad-hoc on machines without the cert, or to point at a different identity).
SIGN_IDENTITY="${SIGN_IDENTITY:-A798891AB1B0A8C0B46AFADBD95094BABF680037}"

codesign --force --sign "$SIGN_IDENTITY" --identifier app.cocotypist.Souffleuse \
  --options runtime --timestamp=none \
  "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
codesign --force --sign "$SIGN_IDENTITY" --identifier app.cocotypist.Souffleuse \
  --options runtime --timestamp=none \
  "$APP_BUNDLE"

echo "==> Bundle: $APP_BUNDLE"
echo "==> Signed with: $SIGN_IDENTITY"
echo "==> Launch via 'open' so launchd assigns the correct TCC identity:"
echo "      open '$APP_BUNDLE'"
echo "==> Permissions persist across rebuilds with the stable cert. If a"
echo "    TCC prompt re-appears it means the cert was rotated — re-grant once."
